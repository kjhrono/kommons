// email_auth_kit — email-verification edge function.
//
//   POST { action: "signup", email, password }
//     → kit-native signup: creates the auth user UNCONFIRMED via the
//       admin API (no GoTrue confirmation mail — the kit sends its own
//       code), then issues the 6-digit code. Identical response for an
//       existing address (no enumeration); rate limited like request.
//
//   POST { action: "request", email }
//     → 6-digit code mailed via Brevo; identical response shape whether
//       or not the address has an account (no enumeration). Rate limit:
//       3 requests / 15 min / email (DB guard).
//
//   POST { action: "verify", email, code }
//     → validates the code (hashed, single-use, 15 min, 5 attempts) and
//       flips auth.users.email_confirmed_at via the admin API.
//
// Deploy with --no-verify-jwt: the registration flow calls this before
// a session exists. It is safe because the function only ever issues a
// challenge to the address in the body and confirms only after the
// correct code is presented — possession of the inbox is the proof.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { page, sendMail } from "../_shared/brevo.ts";

const CODE_TTL_MIN = 15;
const MAX_ATTEMPTS = 5;

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
    code?: string;
    password?: string;
  };
    try {
      body = await req.json();
    } catch {
      return json(400, { error: "invalid_json" });
    }

    const email = (body.email ?? "").trim().toLowerCase();
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
    const ua = req.headers.get("user-agent");

    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json(400, { error: "invalid_email" });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { autoRefreshToken: false, persistSession: false } },
    );

    if (body.action === "signup") {
      const password = body.password ?? "";
      if (password.length < 6) return json(400, { error: "weak_password" });
      // Same rate limit as a code request — signup IS a code request.
      const { data: ok, error: rateErr } = await admin.rpc("auth_event_rate_ok", {
        p_email: email,
        p_kind: "email_code",
        p_window: "15 minutes",
        p_limit: 3,
      });
      if (rateErr) return json(500, { error: "rate_check_failed" });
      if (!ok) return json(429, { error: "rate_limited" });

      // Create unconfirmed when new; stay silent when the address exists.
      const { data: existing } = await admin.rpc("auth_kit_find_user_id", { p_email: email });
      if (!existing) {
        const { error: createErr } = await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: false,
        });
        if (createErr) {
          console.error(`signup create failed for ${email}: ${createErr.message}`);
          return json(500, { error: "signup_failed" });
        }
      }
      // Fall through to the shared code-issuing path below.
      body.action = "request";
    }

    if (body.action === "request") {
      // Rate limit: 3 requests / 15 min / email.
      const { data: ok, error: rateErr } = await admin.rpc(
        "auth_event_rate_ok",
        { p_email: email, p_kind: "email_code", p_window: "15 minutes", p_limit: 3 },
      );
      if (rateErr) return json(500, { error: "rate_check_failed" });
      if (!ok) return json(429, { error: "rate_limited" });

      const { data, error } = await admin.rpc("request_auth_event", {
        p_email: email,
        p_kind: "email_code",
        p_ttl: `${CODE_TTL_MIN} minutes`,
        p_code_space: "digits",
        p_ip: ip,
        p_user_agent: ua,
      });
      if (error || !data?.length) return json(500, { error: "issue_failed" });

      const { plaintext, event_id } = data[0];
      const mail = await sendMail({
        to: email,
        subject: "Your confirmation code",
        text: `Your confirmation code is ${plaintext}. It expires in ${CODE_TTL_MIN} minutes.`,
        html: page(
          "Confirm your e-mail",
          `<p>Use this code to confirm your address. It expires in ${CODE_TTL_MIN} minutes.</p>
         <p style="font-size:32px;letter-spacing:8px;font-weight:700">${plaintext}</p>`,
        ),
      });
      console.log(
        `email_code issued for ${email} (event ${event_id}, delivered=${mail.delivered})`,
      );
      return json(200, { sent: true, delivered: mail.delivered });
    }

    if (body.action === "verify") {
      const code = (body.code ?? "").trim();
      if (!/^\d{6}$/.test(code)) return json(400, { error: "invalid_code_format" });

      // The presented code is hashed the same way the DB hashed it, then
      // matched against the newest unconsumed event for this email+kind.
      const presentedHash = await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(code),
      );
      const presentedHex = [...new Uint8Array(presentedHash)]
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

      const { data: events, error: findErr } = await admin
        .from("auth_events")
        .select("id, code_hash, attempts, max_attempts, expires_at, consumed_at")
        .eq("email", email)
        .eq("kind", "email_code")
        .is("consumed_at", null)
        .order("created_at", { ascending: false })
        .limit(1);
      if (findErr) return json(500, { error: "lookup_failed" });
      if (!events?.length) return json(400, { error: "no_pending_code" });

      const ev = events[0];
      if (new Date(ev.expires_at) < new Date()) {
        return json(400, { error: "code_expired" });
      }
      if (!same(ev.code_hash, presentedHex)) {
        const left = Math.max(0, (ev.max_attempts ?? MAX_ATTEMPTS) - (ev.attempts ?? 0) - 1);
        await admin.rpc("consume_auth_event", {
          // "_____wrong" can never match a 6-digit code — this only
          // counts the failed attempt and applies the lockout rule.
          p_presented: "_____wrong",
          p_kind: "email_code",
        });
        return left <= 0
          ? json(400, { error: "code_locked" })
          : json(400, { error: "code_invalid", attempts_left: left });
      }

      // Mark consumed.
      const { error: consumeErr } = await admin.rpc("consume_auth_event", {
        p_event_id: ev.id,
        p_presented: code,
        p_kind: "email_code",
      });
      if (consumeErr) return json(500, { error: "consume_failed" });

      // Confirm the address via the admin API. The user is looked up
      // inside the database (auth.users is not exposed over PostgREST;
      // see the SQL migration's auth_kit_find_user_id).
      const { data: userId, error: lookupErr } = await admin.rpc("auth_kit_find_user_id", {
        p_email: email,
      });
      if (lookupErr) return json(500, { error: "lookup_failed" });
      if (!userId) {
        // No enumeration on request; on verify an unknown address is a
        // client bug or a stale tab — report it plainly.
        return json(404, { error: "user_not_found" });
      }
      const { error: updErr } = await admin.auth.admin.updateUserById(userId as string, {
        email_confirm: true,
      });
      if (updErr) return json(500, { error: "confirm_failed" });

      console.log(`email verified for ${email}`);
      return json(200, { verified: true });
    }

    return json(400, { error: "unknown_action" });
  },
);
