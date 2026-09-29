// email_auth_kit — password-reset edge function.
//
//   POST { action: "request", email, redirect_to }
//     → e-mails a reset LINK: <redirect_to>?email=...&token=...
//       Token: 32-byte CSPRNG, hashed in the DB, 30 min, single-use.
//       Identical response whether or not the account exists.
//
//   POST { action: "confirm", email, token }
//     → called by YOUR reset page when the user clicks the link:
//       generates a 12-char temp password, sets it via the admin API,
//       revokes the user's other sessions, e-mails the temp password,
//       returns { temp_password_sent: true, must_change_password: true }.
//       The temp password is sent ONLY to the inbox — proof of inbox
//       ownership is the whole reset.
//
//   POST { action: "notify", user_id }  (Authorization: caller's JWT)
//     → optional "your password was changed" mail. Unlike the actions
//       above this one REQUIRES a valid user JWT (Supabase verifies it
//       when deployed WITHOUT --no-verify-jwt... but this function is
//       deployed with --no-verify-jwt, so we verify the JWT ourselves
//       via auth.getUser with the anon key + bearer).
//
// Deploy with --no-verify-jwt: request/confirm are pre-session flows;
// notify self-verifies (see below).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { page, sendMail } from "../_shared/brevo.ts";

const TOKEN_TTL_MIN = 30;
const TEMP_LEN = 12;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function tempPassword(len = TEMP_LEN): string {
  // Unambiguous charset: no 0/O, 1/l/I.
  const cs = "23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz";
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  return [...bytes].map((b) => cs[b % cs.length]).join("");
}

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Optional host-side override: when this file is run directly with
// `deno run` (no supabase functions serve / no Kong), listen on an
// explicit port. SUPABASE_URL then points at the stack's published API
// port. Unset in production — the runtime injects its own listener.
const port = Number(Deno.env.get("FUNCTION_PORT") ?? "0");
Deno.serve(
  port ? { port } : {},
  async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let body: {
    action?: string;
    email?: string;
    token?: string;
    redirect_to?: string;
    user_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
  const ua = req.headers.get("user-agent");
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  // ------------------------------------------------------------- request
  if (body.action === "request") {
    const email = (body.email ?? "").trim().toLowerCase();
    const redirectTo = (body.redirect_to ?? "").trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json(400, { error: "invalid_email" });
    }
    if (!/^https:\/\/[^\s]+$/.test(redirectTo)) {
      return json(400, { error: "invalid_redirect" }); // https only
    }

    const { data: ok, error: rateErr } = await admin.rpc("auth_event_rate_ok", {
      p_email: email,
      p_kind: "reset_token",
      p_window: "15 minutes",
      p_limit: 3,
    });
    if (rateErr) return json(500, { error: "rate_check_failed" });
    if (!ok) return json(429, { error: "rate_limited" });

    const { data, error } = await admin.rpc("request_auth_event", {
      p_email: email,
      p_kind: "reset_token",
      p_ttl: `${TOKEN_TTL_MIN} minutes`,
      p_code_space: "token",
      p_ip: ip,
      p_user_agent: ua,
    });
    if (error || !data?.length) return json(500, { error: "issue_failed" });
    const { plaintext, event_id } = data[0];

    const link = `${redirectTo}?email=${encodeURIComponent(email)}&token=${plaintext}`;
    const mail = await sendMail({
      to: email,
      subject: "Reset your password",
      text:
        `Open this link to receive a temporary password (valid ${TOKEN_TTL_MIN} minutes):\n${link}`,
      html: page(
        "Reset your password",
        `<p>Open the link below and we'll e-mail you a temporary password. The link expires in ${TOKEN_TTL_MIN} minutes.</p>
         <p><a href="${link}" style="display:inline-block;background:#2563eb;color:#fff;padding:10px 18px;border-radius:6px;text-decoration:none">Get my temporary password</a></p>
         <p style="word-break:break-all;color:#667085;font-size:12px">${link}</p>`,
      ),
    });
    console.log(`reset_token issued for ${email} (event ${event_id}, delivered=${mail.delivered})`);
    return json(200, { sent: true, delivered: mail.delivered });
  }

  // ------------------------------------------------------------- confirm
  if (body.action === "confirm") {
    const email = (body.email ?? "").trim().toLowerCase();
    const token = (body.token ?? "").trim();
    if (!email || !token) return json(400, { error: "missing_fields" });

    const tokenHash = await sha256Hex(token);
    const { data: events, error: findErr } = await admin
      .from("auth_events")
      .select("id, code_hash, attempts, max_attempts, expires_at, consumed_at")
      .eq("email", email)
      .eq("kind", "reset_token")
      .is("consumed_at", null)
      .order("created_at", { ascending: false })
      .limit(1);
    if (findErr) return json(500, { error: "lookup_failed" });
    if (!events?.length) return json(400, { error: "no_pending_reset" });

    const ev = events[0];
    if (new Date(ev.expires_at) < new Date()) {
      return json(400, { error: "token_expired" });
    }
    if (!same(ev.code_hash, tokenHash)) {
      const left = Math.max(0, (ev.max_attempts ?? 5) - (ev.attempts ?? 0) - 1);
      await admin.rpc("consume_auth_event", {
        p_event_id: ev.id,
        p_presented: "_____wrong", // can never match a 64-hex token
        p_kind: "reset_token",
      });
      return left <= 0
        ? json(400, { error: "token_locked" })
        : json(400, { error: "token_invalid", attempts_left: left });
    }

    const { error: consumeErr } = await admin.rpc("consume_auth_event", {
      p_event_id: ev.id,
      p_presented: token,
      p_kind: "reset_token",
    });
    if (consumeErr) return json(500, { error: "consume_failed" });

    // The user must exist for a reset to complete (lookup inside the
    // database — auth.users is not exposed over PostgREST).
    const { data: userId, error: lookupErr } = await admin.rpc("auth_kit_find_user_id", {
      p_email: email,
    });
    if (lookupErr) return json(500, { error: "lookup_failed" });
    if (!userId) return json(404, { error: "user_not_found" });

    const temp = tempPassword();
    const { error: updErr } = await admin.auth.admin.updateUserById(userId as string, {
      password: temp,
      ban_duration: "0s", // unban in case a prior lockout is in force
    });
    if (updErr) return json(500, { error: "password_update_failed" });

    // Revoke all refresh tokens: any other device is logged out.
    await admin.auth.admin.signOut(userId as string);

    const mail = await sendMail({
      to: email,
      subject: "Your temporary password",
      text:
        `Your temporary password is: ${temp}\nSign in with it, then change it immediately (you will be asked).`,
      html: page(
        "Your temporary password",
        `<p>Sign in with this temporary password, then change it immediately — you will be asked to on first login.</p>
         <p style="font-family:monospace;font-size:20px;font-weight:700;background:#f2f4f7;padding:10px 14px;border-radius:6px">${temp}</p>`,
      ),
    });

    console.log(`temp password issued for ${email} (delivered=${mail.delivered})`);
    return json(200, {
      temp_password_sent: mail.delivered,
      must_change_password: true,
    });
  }

  // -------------------------------------------------------------- notify
  if (body.action === "notify") {
    // Self-verify the caller's JWT: this deployment runs with
    // --no-verify-jwt, so the gate happens here.
    const authHeader = req.headers.get("authorization") ?? "";
    if (!authHeader.toLowerCase().startsWith("bearer ")) {
      return json(401, { error: "missing_bearer" });
    }
    const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
    const { data: who, error: whoErr } = await anon.auth.getUser(
      authHeader.slice(7).trim(),
    );
    if (whoErr || !who?.user) return json(401, { error: "invalid_token" });
    if (who.user.id !== body.user_id) return json(403, { error: "user_mismatch" });

    const mail = await sendMail({
      to: who.user.email!,
      subject: "Your password was changed",
      text:
        "The password for your account was just changed. If this wasn't you, reset it immediately.",
      html: page(
        "Your password was changed",
        `<p>The password for your account was just changed.</p>
         <p>If this wasn't you, <strong>reset your password immediately</strong>.</p>`,
      ),
    });
    return json(200, { notified: mail.delivered });
  }

  return json(400, { error: "unknown_action" });
});
