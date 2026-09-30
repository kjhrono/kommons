// email_auth_kit — ban-management edge function (the kill-switch's
// support-dashboard surface).
//
// The kit's RPC (auth_kit_set_ban) drives the DATA plane only: the
// kit_banned_until claim closes what the account can DO on every
// project. Sign-in itself stays open until GoTrue's native ban is set.
// This function is the one-call ops surface that drives BOTH planes and
// adds the dashboard conveniences:
//
//   POST { action: "ban", email, until, reason?, notify? }
//     → data-plane claim + native ban + optional "account suspended"
//       mail. until: ISO timestamp, or "forever".
//   POST { action: "unban", email, notify? }
//     → lifts both planes.
//   POST { action: "status", email }
//     → { email, banned, kit_banned_until, native_ban, reason, set_at }.
//   POST { action: "list" }
//     → all live kit bans (reason, set_at, banned_until).
//
// Gating: service-role ONLY, and not by claim inspection — the bearer
// must EQUAL the stack's service-role key (constant-time compare). The
// kit's functions run behind VERIFY_JWT=false (pre-session flows), so a
// forged `role=service_role` claim would sail through a decode check;
// the exact-secret match is unforgable — the secret is the credential.
// No anonymous enumeration: unknown emails return { known: false }.
//
// Env (compose override, same pattern as the kit's mail functions):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (injected by the runtime)
//   BREVO_API_KEY, BREVO_SENDER, BREVO_SENDER_NAME  (optional mail)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { page, sendMail } from "../_shared/brevo.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

// GoTrue's forever-ban sentinel (the admin API's conventional value).
const FOREVER = "2099-12-31T23:59:59Z";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function callerIsServiceRole(req: Request): boolean {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return key.length > 0 && same(token, key);
}

async function findUserId(email: string): Promise<string | null> {
  const { data, error } = await admin.rpc("auth_kit_find_user_id", { p_email: email });
  if (error || !data) return null;
  return data as string;
}

async function setKitBan(email: string, until: string | null, reason: string | null): Promise<boolean> {
  const { data, error } = await admin.rpc("auth_kit_set_ban", {
    p_email: email,
    p_banned_until: until,
    p_reason: reason,
  });
  return !error && data === true;
}

async function setNativeBan(userId: string, banned: boolean): Promise<boolean> {
  const { error } = await admin.auth.admin.updateUserById(userId, {
    ban_duration: banned ? "876000h" : "none", // 100 years ≈ forever; "none" lifts
  });
  return !error;
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

  // Gate: the bearer must be the exact service-role key (see above).
  if (!callerIsServiceRole(req)) {
    return json(401, { error: "service_role_required" });
  }

  let body: { action?: string; email?: string; until?: string; reason?: string; notify?: boolean };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const email = (body.email ?? "").trim().toLowerCase();
  const needsEmail = body.action !== "list";
  if (needsEmail && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return json(400, { error: "invalid_email" });
  }

  // ---------------------------------------------------------------- ban
  if (body.action === "ban") {
    const until = body.until === "forever" || !body.until ? FOREVER : body.until;
    const when = new Date(until);
    if (isNaN(when.getTime())) return json(400, { error: "invalid_until" });

    const uid = await findUserId(email);
    if (!uid) return json(200, { known: false, banned: false });

    const kitOk = await setKitBan(email, when.toISOString(), body.reason ?? null);
    if (!kitOk) return json(500, { error: "kit_ban_failed" });
    const nativeOk = await setNativeBan(uid, true);
    if (!nativeOk) return json(500, { error: "native_ban_failed", data_plane: true });

    let notified = false;
    if (body.notify) {
      const mail = await sendMail({
        to: email,
        subject: "Your account has been suspended",
        html: page(
          "Account suspended",
          `<p>Your account has been suspended${body.reason ? ` — reason: ${body.reason}` : ""}.</p>
           <p>If you believe this is a mistake, reply to this message.</p>`,
        ),
        text: `Your account has been suspended${body.reason ? ` — reason: ${body.reason}` : ""}.`,
      }).catch(() => ({ delivered: false }));
      notified = mail.delivered;
    }
    return json(200, { known: true, banned: true, until: when.toISOString(), native_ban: true, notified });
  }

  // -------------------------------------------------------------- unban
  if (body.action === "unban") {
    const uid = await findUserId(email);
    if (!uid) return json(200, { known: false, banned: false });

    const kitOk = await setKitBan(email, null, null);
    const nativeOk = await setNativeBan(uid, false);
    // Optional "your account is active again" mail.
    let notified = false;
    if (body.notify) {
      const mail = await sendMail({
        to: email,
        subject: "Your account has been reinstated",
        html: page("Account reinstated", "<p>Your account has been reinstated. Welcome back.</p>"),
        text: "Your account has been reinstated.",
      }).catch(() => ({ delivered: false }));
      notified = mail.delivered;
    }
    return json(200, { known: true, banned: false, kit_lifted: kitOk, native_lifted: nativeOk, notified });
  }

  // ------------------------------------------------------------- status
  if (body.action === "status") {
    const uid = await findUserId(email);
    if (!uid) return json(200, { known: false });
    const { data, error } = await admin
      .from("auth_kit_bans")
      .select("banned_until, reason, set_at")
      .eq("user_id", uid)
      .maybeSingle();
    if (error) return json(500, { error: "status_lookup_failed" });
    const { data: user } = await admin.auth.admin.getUserById(uid);
    const nativeBanned = !!user?.user?.banned_until;
    const kitUntil = data?.banned_until ?? null;
    const live = (kitUntil && new Date(kitUntil) > new Date()) || nativeBanned;
    return json(200, {
      known: true,
      banned: !!live,
      kit_banned_until: kitUntil,
      native_ban: nativeBanned,
      reason: data?.reason ?? null,
      set_at: data?.set_at ?? null,
    });
  }

  // --------------------------------------------------------------- list
  if (body.action === "list") {
    const { data, error } = await admin
      .from("auth_kit_bans")
      .select("user_id, banned_until, reason, set_at")
      .gt("banned_until", new Date().toISOString())
      .order("set_at", { ascending: false });
    if (error) return json(500, { error: "list_failed" });
    return json(200, { bans: data ?? [] });
  }

  return json(400, { error: "unknown_action" });
  },
);

