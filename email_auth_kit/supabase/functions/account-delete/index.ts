// email_auth_kit — account-delete edge function: the account deletion that
// Google Play and the App Store require for apps with accounts.
// Bearer = the user's own access token.
//
//   POST { scope: "app", app_id, confirm: true }
//     → removes the account from ONE app: that app's purchases, offline
//       licenses, device moves and audit reports. The app deletes its own
//       project data BEFORE calling this (kommons'
//       SettingsScreen.onRemoveAppData), while the token still opens it. The
//       MediaSart account, mediasart.com and the other apps are untouched.
//       Strikes and suspensions (kit_app_bans) stay, so leaving and
//       rejoining cannot wipe them.
//
//   POST { scope: "account", confirm: true }   (the default scope)
//     → deletes the MediaSart account on the identity stack, everywhere.
//       The kit's tables go with it (on delete cascade). Meant for the
//       mediasart.com account page; apps send players there.
//
// Errors: unauthorized, confirm_required, invalid_app_id.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

const port = Number(Deno.env.get("FUNCTION_PORT") ?? "0");
Deno.serve(port ? { port } : {}, async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "post_only" });

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const { data: auth, error } = await admin.auth.getUser(token);
  if (error || !auth?.user) return json(401, { error: "unauthorized" });

  let body: { confirm?: unknown; scope?: unknown; app_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (body.confirm !== true) return json(400, { error: "confirm_required" });
  const userId = auth.user.id;

  if (body.scope === "app") {
    const appId = String(body.app_id ?? "");
    if (!/^[a-z0-9_-]{1,40}$/.test(appId)) return json(400, { error: "invalid_app_id" });
    for (const table of [
      "kit_entitlements",
      "kit_offline_licenses",
      "kit_license_moves",
      "kit_license_reports",
    ]) {
      const { error: e } = await admin.from(table).delete()
        .eq("user_id", userId).eq("app_id", appId);
      if (e) return json(500, { error: "remove_failed", table });
    }
    return json(200, { removed: appId });
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
  if (deleteError) return json(500, { error: "delete_failed" });
  return json(200, { deleted: true });
});
