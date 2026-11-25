// email_auth_kit — license edge function: per-app premium, the one offline
// device, and the online audit.
//
// Signed-in apps (bearer = the user's access token):
//
//   POST { action: "activate", app_id, device_key, device_label?, platform? }
//     → makes THIS device the account's offline device for the app and
//       returns a signed license (14-day lease). Taking it from another
//       device is a "move": 3 per 30 days. Errors: not_entitled,
//       suspended, move_limit { next_move_at }.
//   POST { action: "renew", app_id, device_key }
//     → a fresh lease for the holder. Errors: moved { holder_label },
//       revoked, not_entitled, suspended.
//   POST { action: "status", app_id }
//     → { entitled, holder_label, holder_is_you?, moves_left, ban }.
//   POST { action: "report", app_id, used?: { plan, features },
//          tamper?: ["edited" | "other_device" | "other_account" | "clock" | "corrupt"] }
//     → the online audit. Compares what the app used with what was
//       bought, and logs what the app found wrong with its stored license
//       (only "edited" strikes): { outcome: ok | grace | warned |
//       suspended, revoke_local }.
//
// Purchase backend / support (bearer = the exact service-role key):
//
//   POST { action: "grant", user_id | email, app_id, plan, features?,
//          source?, purchase_ref? }   — after verifying the store receipt
//   POST { action: "revoke", user_id | email, app_id }   — refunds
//   POST { action: "unsuspend", user_id | email, app_id } — after review
//   POST { action: "reports", app_id?, mismatch_only? }   — the audit log
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (runtime), and
// LICENSE_SIGNING_KEY (base64 PKCS#8 Ed25519 — tool/license_keygen.ts).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  decideMove,
  type Entitled,
  importSigningKey,
  judgeReport,
  LEASE_DAYS,
  LICENSE_VERSION,
  movesLeft,
  MOVE_WINDOW_DAYS,
  signLicense,
  tamperKinds,
  unlocksAnything,
} from "../_shared/license.ts";

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

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

let signingKey: Promise<CryptoKey> | null = null;
function key(): Promise<CryptoKey> {
  signingKey ??= importSigningKey(Deno.env.get("LICENSE_SIGNING_KEY") ?? "");
  return signingKey;
}

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function bearer(req: Request): string {
  return (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

function callerIsServiceRole(req: Request): boolean {
  const k = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return k.length > 0 && same(bearer(req), k);
}

const APP_ID = /^[a-z0-9_-]{1,40}$/;
const DEVICE_KEY = /^[A-Za-z0-9+/=_-]{40,800}$/;

type Row = {
  plan: "free" | "premium";
  features: string[];
  revoked_at: string | null;
};

async function entitlement(userId: string, appId: string) {
  const { data } = await admin.from("kit_entitlements")
    .select("plan, features, revoked_at")
    .eq("user_id", userId).eq("app_id", appId).maybeSingle<Row>();
  const live: Entitled | null = data && !data.revoked_at
    ? { plan: data.plan, features: data.features ?? [] }
    : null;
  return { live, revokedAt: data?.revoked_at ? new Date(data.revoked_at) : null };
}

async function appBan(userId: string, appId: string) {
  const { data } = await admin.from("kit_app_bans")
    .select("level, strikes, until")
    .eq("user_id", userId).eq("app_id", appId)
    .maybeSingle<{ level: string; strikes: number; until: string | null }>();
  const suspended = data?.level === "suspended" &&
    (data.until === null || new Date(data.until) > new Date());
  return { strikes: data?.strikes ?? 0, level: data?.level ?? null, suspended };
}

async function recentMoves(userId: string, appId: string, now: Date): Promise<Date[]> {
  const since = new Date(now.getTime() - MOVE_WINDOW_DAYS * 86400_000).toISOString();
  const { data } = await admin.from("kit_license_moves")
    .select("moved_at")
    .eq("user_id", userId).eq("app_id", appId).gt("moved_at", since)
    .order("moved_at", { ascending: false });
  return (data ?? []).map((r: { moved_at: string }) => new Date(r.moved_at));
}

async function holder(userId: string, appId: string) {
  const { data } = await admin.from("kit_offline_licenses")
    .select("license_id, device_key, device_label")
    .eq("user_id", userId).eq("app_id", appId)
    .maybeSingle<{ license_id: string; device_key: string; device_label: string | null }>();
  return data;
}

async function issue(
  userId: string,
  appId: string,
  ent: Entitled,
  licenseId: string,
  deviceKey: string,
  now: Date,
): Promise<{ license: string; expires_at: string }> {
  const iat = Math.floor(now.getTime() / 1000);
  const exp = iat + LEASE_DAYS * 86400;
  const license = await signLicense({
    v: LICENSE_VERSION,
    lid: licenseId,
    sub: userId,
    app: appId,
    plan: ent.plan,
    features: ent.features,
    dev: deviceKey,
    iat,
    exp,
  }, await key());
  return { license, expires_at: new Date(exp * 1000).toISOString() };
}

async function userIdFor(body: { user_id?: string; email?: string }): Promise<string | null> {
  if (body.user_id) return body.user_id;
  const email = (body.email ?? "").trim().toLowerCase();
  if (!email) return null;
  const { data, error } = await admin.rpc("auth_kit_find_user_id", { p_email: email });
  return error || !data ? null : data as string;
}

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

async function handleUser(req: Request, body: Body): Promise<Response> {
  const { data: auth, error } = await admin.auth.getUser(bearer(req));
  if (error || !auth?.user) return json(401, { error: "unauthorized" });
  const userId = auth.user.id;
  const appId = String(body.app_id ?? "");
  if (!APP_ID.test(appId)) return json(400, { error: "invalid_app_id" });
  const now = new Date();

  const { live, revokedAt } = await entitlement(userId, appId);
  const ban = await appBan(userId, appId);

  switch (body.action) {
    case "status": {
      const h = await holder(userId, appId);
      const deviceKey = typeof body.device_key === "string" ? body.device_key : null;
      return json(200, {
        entitled: live,
        holder_label: h?.device_label ?? null,
        holder_is_you: deviceKey ? h?.device_key === deviceKey : null,
        moves_left: movesLeft(await recentMoves(userId, appId, now), now),
        ban: ban.suspended ? "suspended" : ban.level,
      });
    }

    case "activate":
    case "renew": {
      const deviceKey = String(body.device_key ?? "");
      if (!DEVICE_KEY.test(deviceKey)) return json(400, { error: "invalid_device_key" });
      if (ban.suspended) return json(403, { error: "suspended" });
      if (!unlocksAnything(live)) {
        if (revokedAt) {
          await admin.from("kit_offline_licenses").delete()
            .eq("user_id", userId).eq("app_id", appId);
          return json(410, { error: "revoked" });
        }
        return json(403, { error: "not_entitled" });
      }
      const h = await holder(userId, appId);
      if (body.action === "renew") {
        if (!h || h.device_key !== deviceKey) {
          return json(409, { error: "moved", holder_label: h?.device_label ?? null });
        }
        const out = await issue(userId, appId, live!, h.license_id, deviceKey, now);
        await admin.from("kit_offline_licenses")
          .update({ issued_at: now.toISOString(), expires_at: out.expires_at })
          .eq("user_id", userId).eq("app_id", appId);
        return json(200, out);
      }

      const moves = await recentMoves(userId, appId, now);
      const decision = decideMove(h?.device_key ?? null, deviceKey, moves, now);
      if (decision.kind === "limited") {
        return json(429, { error: "move_limit", next_move_at: decision.nextMoveAt });
      }
      const licenseId = decision.kind === "same" ? h!.license_id : crypto.randomUUID();
      const out = await issue(userId, appId, live!, licenseId, deviceKey, now);
      if (decision.kind === "move") {
        await admin.from("kit_license_moves").insert({
          user_id: userId,
          app_id: appId,
          from_key: h!.device_key,
          to_key: deviceKey,
        });
      }
      await admin.from("kit_offline_licenses").upsert({
        user_id: userId,
        app_id: appId,
        license_id: licenseId,
        device_key: deviceKey,
        device_label: typeof body.device_label === "string" ? body.device_label.slice(0, 80) : null,
        platform: typeof body.platform === "string" ? body.platform.slice(0, 20) : null,
        issued_at: now.toISOString(),
        expires_at: out.expires_at,
      });
      return json(200, {
        ...out,
        moves_left: decision.kind === "move" ? decision.movesLeft : movesLeft(moves, now),
      });
    }

    case "report": {
      const used = body.used ?? {};
      const usedEnt: Entitled = {
        plan: used.plan === "premium" ? "premium" : "free",
        features: Array.isArray(used.features) ? used.features.map(String).slice(0, 50) : [],
      };
      const tamper = tamperKinds(body.tamper);
      const verdict = judgeReport(usedEnt, live, revokedAt, ban.strikes, now, tamper);
      await admin.from("kit_license_reports").insert({
        user_id: userId,
        app_id: appId,
        used: usedEnt,
        entitled: live,
        tamper,
        mismatch: verdict.mismatch,
        outcome: verdict.outcome,
      });
      if (verdict.outcome === "warned" || verdict.outcome === "suspended") {
        await admin.from("kit_app_bans").upsert({
          user_id: userId,
          app_id: appId,
          level: verdict.outcome,
          strikes: verdict.strikes,
          until: null,
          reason: tamper.includes("edited")
            ? "edited offline license"
            : "premium used without a purchase",
          updated_at: now.toISOString(),
        });
        // The offline device loses its lease with the strike.
        await admin.from("kit_offline_licenses").delete()
          .eq("user_id", userId).eq("app_id", appId);
      }
      return json(200, { outcome: verdict.outcome, revoke_local: verdict.revokeLocal });
    }
  }
  return json(400, { error: "unknown_action" });
}

async function handleAdmin(body: Body): Promise<Response> {
  if (body.action === "reports") {
    let q = admin.from("kit_license_reports").select("*")
      .order("reported_at", { ascending: false }).limit(200);
    if (body.app_id) q = q.eq("app_id", body.app_id);
    if (body.mismatch_only) q = q.eq("mismatch", true);
    const { data } = await q;
    return json(200, { reports: data ?? [] });
  }
  const appId = String(body.app_id ?? "");
  if (!APP_ID.test(appId)) return json(400, { error: "invalid_app_id" });
  const userId = await userIdFor(body);
  if (!userId) return json(200, { known: false });
  const now = new Date().toISOString();

  switch (body.action) {
    case "grant": {
      const plan = body.plan === "premium" ? "premium" : "free";
      const features = Array.isArray(body.features) ? body.features.map(String) : [];
      const { error } = await admin.from("kit_entitlements").upsert({
        user_id: userId,
        app_id: appId,
        plan,
        features,
        revoked_at: null,
        source: body.source ?? null,
        purchase_ref: body.purchase_ref ?? null,
        updated_at: now,
      });
      return error ? json(500, { error: "grant_failed" }) : json(200, { granted: true });
    }
    case "revoke": {
      const { error } = await admin.from("kit_entitlements")
        .update({ revoked_at: now, updated_at: now })
        .eq("user_id", userId).eq("app_id", appId);
      await admin.from("kit_offline_licenses").delete()
        .eq("user_id", userId).eq("app_id", appId);
      return error ? json(500, { error: "revoke_failed" }) : json(200, { revoked: true });
    }
    case "unsuspend": {
      await admin.from("kit_app_bans").delete().eq("user_id", userId).eq("app_id", appId);
      return json(200, { unsuspended: true });
    }
  }
  return json(400, { error: "unknown_action" });
}

const port = Number(Deno.env.get("FUNCTION_PORT") ?? "0");
Deno.serve(port ? { port } : {}, async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "post_only" });
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (["grant", "revoke", "unsuspend", "reports"].includes(body.action)) {
    if (!callerIsServiceRole(req)) return json(401, { error: "service_role_required" });
    return handleAdmin(body);
  }
  return handleUser(req, body);
});
