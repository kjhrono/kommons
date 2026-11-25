// End-to-end check of the license function against the running teststack
// (real GoTrue + Postgres + the token hook). Needs the licenses migration
// applied and the function running locally:
//
//   deno run tool/license_keygen.ts   # → LICENSE_SIGNING_KEY, public key
//   LICENSE_SIGNING_KEY=… FUNCTION_PORT=8790 deno run --allow-net --allow-env \
//     --env-file=teststack/supabase/functions/.env supabase/functions/license/index.ts
//   FUNCTION_PORT=8791 deno run --allow-net --allow-env \
//     --env-file=teststack/supabase/functions/.env supabase/functions/account-delete/index.ts
//   LICENSE_PUBLIC_KEY=… deno run --allow-net --allow-env \
//     --env-file=teststack/supabase/functions/.env teststack/license_e2e.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import { importVerifyKey, verifyLicense } from "../supabase/functions/_shared/license.ts";

const API = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FN = Deno.env.get("KIT_LICENSE_URL") ?? "http://127.0.0.1:8790";
const verifyKey = await importVerifyKey(Deno.env.get("LICENSE_PUBLIC_KEY")!);

const email = `license-${crypto.randomUUID().slice(0, 8)}@kit.test`;
const password = "Correct-Horse-1";
const deviceA = btoa("device-A-public-key-".repeat(3));
const deviceB = btoa("device-B-public-key-".repeat(3));

function claims(token: string) {
  const b = token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
  return JSON.parse(atob(b + "==".slice(0, (4 - b.length % 4) % 4)));
}

async function call(token: string, body: unknown) {
  const res = await fetch(FN, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

async function signIn() {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  assertEquals(res.status, 200);
  return (await res.json()).access_token as string;
}

async function hasPremium(token: string, feature: string | null) {
  const res = await fetch(`${API}/rest/v1/rpc/kit_jwt_has_premium`, {
    method: "POST",
    headers: { apikey: ANON, authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ p_app: "katalogus", p_feature: feature }),
  });
  return await res.json();
}

// A confirmed test user.
const created = await fetch(`${API}/auth/v1/admin/users`, {
  method: "POST",
  headers: { apikey: SERVICE, authorization: `Bearer ${SERVICE}`, "content-type": "application/json" },
  body: JSON.stringify({ email, password, email_confirm: true }),
});
assertEquals(created.status, 200, await created.clone().text());

let token = await signIn();
const step = (name: string) => console.log(`ok  ${name}`);

assertEquals(claims(token).kit_entitlements, undefined);
assertEquals((await call(token, { action: "activate", app_id: "katalogus", device_key: deviceA })).status, 403);
assertEquals(await hasPremium(token, null), false);
step("no purchase: no claim, activation refused, RLS helper false");

assertEquals((await call(token, { action: "grant", email, app_id: "katalogus", plan: "premium" })).status, 401);
const grant = await call(SERVICE, { action: "grant", email, app_id: "katalogus", plan: "premium", source: "manual" });
assertEquals(grant.body, { granted: true });
step("grant is service-role only");

token = await signIn();
assertEquals(claims(token).kit_entitlements.katalogus.plan, "premium");
assertEquals(await hasPremium(token, null), true);
assertEquals(await hasPremium(token, "export"), true);
step("purchase lands in the token; RLS helper true");

const a = await call(token, { action: "activate", app_id: "katalogus", device_key: deviceA, device_label: "Phone A" });
assertEquals(a.status, 200, JSON.stringify(a.body));
const payload = await verifyLicense(a.body.license, verifyKey);
assert(payload);
assertEquals([payload.app, payload.dev, payload.plan, payload.sub], ["katalogus", deviceA, "premium", claims(token).sub]);
assertEquals(payload.exp - payload.iat, 14 * 86400);
step("first device: signed 14-day license bound to its key");

assertEquals((await call(token, { action: "renew", app_id: "katalogus", device_key: deviceA })).status, 200);
assertEquals((await call(token, { action: "renew", app_id: "katalogus", device_key: deviceB })).body.error, "moved");
step("renew: holder yes, other device no");

for (let i = 0; i < 3; i++) {
  const to = i % 2 === 0 ? deviceB : deviceA;
  assertEquals((await call(token, { action: "activate", app_id: "katalogus", device_key: to })).status, 200);
}
// Now on B after three moves: moving back to A is a fourth.
const limited = await call(token, { action: "activate", app_id: "katalogus", device_key: deviceA });
assertEquals([limited.status, limited.body.error], [429, "move_limit"]);
const status = await call(token, { action: "status", app_id: "katalogus", device_key: deviceA });
assertEquals([status.body.holder_label, status.body.moves_left, status.body.holder_is_you], [null, 0, false]);
step("3 moves per 30 days, then move_limit");

const ok = await call(token, { action: "report", app_id: "katalogus", used: { plan: "premium" } });
assertEquals(ok.body, { outcome: "ok", revoke_local: false });
const warn = await call(token, { action: "report", app_id: "kalcio", used: { plan: "premium" } });
assertEquals(warn.body, { outcome: "warned", revoke_local: true });
token = await signIn();
assertEquals(claims(token).kit_app_bans, undefined);
const susp = await call(token, { action: "report", app_id: "kalcio", used: { plan: "premium" } });
assertEquals(susp.body, { outcome: "suspended", revoke_local: true });
token = await signIn();
assertEquals(claims(token).kit_app_bans.kalcio.level, "suspended");
assertEquals(claims(token).kit_entitlements.katalogus.plan, "premium");
step("audit: paid use ok; unpaid use warns, then suspends that app only");

await call(SERVICE, { action: "unsuspend", email, app_id: "kalcio" });
token = await signIn();
assertEquals(claims(token).kit_app_bans, undefined);
step("unsuspend after review");

await call(SERVICE, { action: "revoke", email, app_id: "katalogus" });
token = await signIn();
assertEquals(claims(token).kit_entitlements, undefined);
assertEquals((await call(token, { action: "renew", app_id: "katalogus", device_key: deviceA })).body.error, "revoked");
const grace = await call(token, { action: "report", app_id: "katalogus", used: { plan: "premium" } });
assertEquals(grace.body, { outcome: "grace", revoke_local: true });
step("refund: claim gone, renewal refused, fresh refund is no strike");

// Tamper findings: honest causes are logged only; an edited license strikes.
const logged = await call(token, {
  action: "report",
  app_id: "kalcio",
  tamper: ["other_device", "clock", "corrupt", "other_account"],
});
assertEquals(logged.body, { outcome: "ok", revoke_local: false });
const edited = await call(token, { action: "report", app_id: "kalcio", tamper: ["edited"] });
assertEquals(edited.body, { outcome: "warned", revoke_local: true });
const log = await call(SERVICE, { action: "reports", app_id: "kalcio" });
assertEquals(log.body.reports[0].tamper, ["edited"]);
step("tamper: only an edited license strikes; findings are logged");

// Delete account (the account-delete function, KIT_DELETE_URL).
const DELETE = Deno.env.get("KIT_DELETE_URL") ?? "http://127.0.0.1:8791";
const del = (body: unknown) =>
  fetch(DELETE, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  }).then(async (r) => ({ status: r.status, body: await r.json() }));
assertEquals((await del({})).body.error, "confirm_required");

// This app only: its purchase, license and reports go; the account stays.
await call(SERVICE, { action: "grant", email, app_id: "katalogus", plan: "premium" });
await call(SERVICE, { action: "grant", email, app_id: "kalcio", plan: "premium" });
token = await signIn();
assertEquals((await call(token, { action: "activate", app_id: "katalogus", device_key: deviceA })).status, 200);
assertEquals((await del({ scope: "app", app_id: "BAD ID", confirm: true })).body.error, "invalid_app_id");
assertEquals((await del({ scope: "app", app_id: "katalogus", confirm: true })).body, { removed: "katalogus" });
token = await signIn(); // the account still works
assertEquals(claims(token).kit_entitlements.katalogus, undefined);
assertEquals(claims(token).kit_entitlements.kalcio.plan, "premium");
assertEquals((await call(token, { action: "renew", app_id: "katalogus", device_key: deviceA })).body.error, "not_entitled");
assertEquals(claims(token).kit_app_bans, undefined);
const kept = await call(SERVICE, { action: "reports", app_id: "kalcio" });
assert(kept.body.reports.some((r: { tamper: string[] }) => r.tamper.includes("edited")), "kalcio strikes stay");
step("delete from one app: its rows go, the account and other apps stay");

assertEquals((await del({ scope: "account", confirm: true })).body, { deleted: true });
const gone = await fetch(`${API}/auth/v1/token?grant_type=password`, {
  method: "POST",
  headers: { apikey: ANON, "content-type": "application/json" },
  body: JSON.stringify({ email, password }),
});
assertEquals(gone.status, 400);
await gone.body?.cancel();
const left = await call(SERVICE, { action: "reports", app_id: "kalcio" });
assertEquals(left.body.reports.filter((r: { user_id: string }) => r.user_id === claims(token).sub), []);
step("delete account: needs confirm; account and its kit rows are gone");

console.log("all license checks passed");
