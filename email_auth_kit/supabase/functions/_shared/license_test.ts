import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  b64url,
  decideMove,
  type Entitled,
  importSigningKey,
  importVerifyKey,
  judgeReport,
  type LicensePayload,
  movesLeft,
  signLicense,
  tamperKinds,
  unlocks,
  verifyLicense,
} from "./license.ts";

const now = new Date("2026-11-25T12:00:00Z");
const daysAgo = (d: number) => new Date(now.getTime() - d * 86400_000);

async function keys() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pkcs8 = b64url(new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)));
  const raw = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)));
  return { sign: await importSigningKey(pkcs8), verify: await importVerifyKey(raw) };
}

const payload: LicensePayload = {
  v: 1,
  lid: "l1",
  sub: "u1",
  app: "katalogus",
  plan: "premium",
  features: [],
  dev: "DEVKEY",
  iat: 1764000000,
  exp: 1765209600,
};

Deno.test("a signed license verifies; any edit breaks it", async () => {
  const k = await keys();
  const token = await signLicense(payload, k.sign);
  assertEquals(await verifyLicense(token, k.verify), payload);

  const [body, sig] = token.split(".");
  const forged = JSON.parse(new TextDecoder().decode(
    Uint8Array.from(atob(body.replaceAll("-", "+").replaceAll("_", "/") + "==".slice(0, (4 - body.length % 4) % 4)), (c) => c.charCodeAt(0)),
  ));
  forged.dev = "ANOTHER_PHONE";
  const forgedBody = b64url(new TextEncoder().encode(JSON.stringify(forged)));
  assertEquals(await verifyLicense(`${forgedBody}.${sig}`, k.verify), null);

  const other = await keys();
  assertEquals(await verifyLicense(token, other.verify), null);
});

Deno.test("device hand-over: same, first, move, then limited", () => {
  assertEquals(decideMove("A", "A", [], now), { kind: "same" });
  assertEquals(decideMove(null, "A", [], now), { kind: "first" });
  assertEquals(decideMove("A", "B", [daysAgo(40)], now), { kind: "move", movesLeft: 2 });
  const three = [daysAgo(1), daysAgo(10), daysAgo(20)];
  const limited = decideMove("A", "B", three, now);
  assertEquals(limited.kind, "limited");
  if (limited.kind === "limited") {
    // The oldest of the three leaves the window 30 days after it happened.
    assertEquals(limited.nextMoveAt, new Date(daysAgo(20).getTime() + 30 * 86400_000).toISOString());
  }
  assertEquals(movesLeft(three, now), 0);
  assertEquals(movesLeft([daysAgo(31)], now), 3);
});

Deno.test("feature unlocks", () => {
  const premium: Entitled = { plan: "premium", features: [] };
  const one: Entitled = { plan: "free", features: ["export"] };
  assert(unlocks(premium, "anything"));
  assert(unlocks(one, "export"));
  assert(!unlocks(one, "sync"));
  assert(!unlocks(null, "export"));
});

Deno.test("audit: matches, grace, warn, then suspend", () => {
  const premium: Entitled = { plan: "premium", features: [] };
  const free: Entitled = { plan: "free", features: [] };

  assertEquals(judgeReport(premium, premium, null, 0, now).outcome, "ok");
  assertEquals(judgeReport(free, null, null, 0, now).outcome, "ok");

  const refund = judgeReport(premium, null, daysAgo(1), 0, now);
  assertEquals(refund.outcome, "grace");
  assertEquals(refund.strikes, 0);
  assert(refund.revokeLocal);

  const first = judgeReport(premium, null, null, 0, now);
  assertEquals([first.outcome, first.strikes], ["warned", 1]);
  const second = judgeReport(premium, null, null, 1, now);
  assertEquals([second.outcome, second.strikes], ["suspended", 2]);

  // An old revocation is no excuse.
  assertEquals(judgeReport(premium, null, daysAgo(10), 0, now).outcome, "warned");
  // Using a feature that was not bought.
  assertEquals(
    judgeReport({ plan: "free", features: ["sync"] }, { plan: "free", features: ["export"] }, null, 0, now)
      .outcome,
    "warned",
  );
});

Deno.test("tamper: only an edited license strikes", () => {
  const premium: Entitled = { plan: "premium", features: [] };
  const nothing: Entitled = { plan: "free", features: [] };
  assertEquals(
    tamperKinds(["edited", { kind: "clock" }, "nonsense", "edited", 3]),
    ["edited", "clock"],
  );
  // Honest causes: logged, no strike, nothing to drop.
  for (const kind of ["other_device", "other_account", "clock", "corrupt"] as const) {
    const v = judgeReport(nothing, premium, null, 0, now, [kind]);
    assertEquals([v.outcome, v.strikes, v.revokeLocal], ["ok", 0, false]);
  }
  // Edited: a strike even for a paying account, and a fresh refund is no excuse.
  const paying = judgeReport(nothing, premium, null, 0, now, ["edited"]);
  assertEquals([paying.outcome, paying.strikes, paying.revokeLocal], ["warned", 1, true]);
  assertEquals(judgeReport(nothing, null, daysAgo(1), 1, now, ["edited"]).outcome, "suspended");
});
