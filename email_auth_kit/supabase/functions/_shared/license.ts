// The license function's pure rules: signing, the device hand-over limit
// and the online audit verdict. No database, no network — the function
// (license/index.ts) feeds them rows; license_test.ts pins them.
//
// A license is `base64url(payload JSON) "." base64url(Ed25519 signature)`.
// The private key never leaves the server (LICENSE_SIGNING_KEY); apps embed
// the public key and verify offline. The payload names the device's
// hardware key (`dev`), so a copied license is useless on another device.

export const LICENSE_VERSION = 1;
export const LEASE_DAYS = 14;
export const MOVES_PER_WINDOW = 3;
export const MOVE_WINDOW_DAYS = 30;
/** A revocation this recent (a refund racing the report) never strikes. */
export const GRACE_DAYS = 3;

export type Entitled = { plan: "free" | "premium"; features: string[] };

export type LicensePayload = {
  v: number;
  lid: string; // license id (stable across renewals of one device)
  sub: string; // account id
  app: string;
  plan: "free" | "premium";
  features: string[];
  dev: string; // base64 SPKI of the device's hardware public key
  iat: number; // epoch seconds
  exp: number;
};

const enc = new TextEncoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function fromB64(s: string): Uint8Array<ArrayBuffer> {
  const norm = s.replaceAll("-", "+").replaceAll("_", "/");
  const pad = norm + "===".slice((norm.length + 3) % 4);
  const bin = atob(pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** The signing key from LICENSE_SIGNING_KEY (base64 PKCS#8 Ed25519). */
export function importSigningKey(pkcs8B64: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", fromB64(pkcs8B64), { name: "Ed25519" }, false, [
    "sign",
  ]);
}

export function importVerifyKey(rawB64: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", fromB64(rawB64), { name: "Ed25519" }, false, [
    "verify",
  ]);
}

export async function signLicense(payload: LicensePayload, key: CryptoKey): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", key, enc.encode(body)));
  return `${body}.${b64url(sig)}`;
}

/** The payload when the signature holds, else null (expiry is the app's call). */
export async function verifyLicense(
  token: string,
  key: CryptoKey,
): Promise<LicensePayload | null> {
  const [body, sig] = token.split(".");
  if (!body || !sig) return null;
  const ok = await crypto.subtle.verify("Ed25519", key, fromB64(sig), enc.encode(body));
  if (!ok) return null;
  return JSON.parse(new TextDecoder().decode(fromB64(body))) as LicensePayload;
}

export function unlocksAnything(e: Entitled | null): boolean {
  return !!e && (e.plan === "premium" || e.features.length > 0);
}

export function unlocks(e: Entitled | null, feature: string): boolean {
  if (!e) return false;
  return e.features.includes(feature) || (e.plan === "premium" && e.features.length === 0);
}

export type MoveDecision =
  | { kind: "same" } // this device already holds it: renew
  | { kind: "first" } // nobody holds it yet: not a move
  | { kind: "move"; movesLeft: number } // hand over from another device
  | { kind: "limited"; nextMoveAt: string };

/**
 * Whether [deviceKey] may take the offline license. [holderKey] is the
 * current holder (null when none); [recentMoves] the hand-over times in the
 * window, newest first.
 */
export function decideMove(
  holderKey: string | null,
  deviceKey: string,
  recentMoves: Date[],
  now: Date,
): MoveDecision {
  if (holderKey === deviceKey) return { kind: "same" };
  if (holderKey === null) return { kind: "first" };
  const windowStart = now.getTime() - MOVE_WINDOW_DAYS * 86400_000;
  const inWindow = recentMoves.filter((d) => d.getTime() > windowStart)
    .sort((a, b) => a.getTime() - b.getTime());
  if (inWindow.length >= MOVES_PER_WINDOW) {
    const oldest = inWindow[inWindow.length - MOVES_PER_WINDOW];
    return {
      kind: "limited",
      nextMoveAt: new Date(oldest.getTime() + MOVE_WINDOW_DAYS * 86400_000).toISOString(),
    };
  }
  return { kind: "move", movesLeft: MOVES_PER_WINDOW - inWindow.length - 1 };
}

export function movesLeft(recentMoves: Date[], now: Date): number {
  const windowStart = now.getTime() - MOVE_WINDOW_DAYS * 86400_000;
  return Math.max(0, MOVES_PER_WINDOW - recentMoves.filter((d) => d.getTime() > windowStart).length);
}

/**
 * What an app found wrong with a stored license, reported at the next
 * connection. Only `edited` is evidence of cheating: a well-formed license
 * whose signature fails cannot come from a backup, a phone change or a
 * corrupted write. The others have honest causes and are logged only:
 *   other_device   restored from another phone (Android auto-backup)
 *   other_account  another account signed in on the phone
 *   clock          the device clock went backwards (manual time change)
 *   corrupt        unreadable (a broken write), not a license at all
 */
export const TAMPER_KINDS = ["edited", "other_device", "other_account", "clock", "corrupt"] as const;
export type TamperKind = typeof TAMPER_KINDS[number];

/** The known kinds in [raw] (unknown entries dropped, duplicates merged). */
export function tamperKinds(raw: unknown): TamperKind[] {
  if (!Array.isArray(raw)) return [];
  const kinds = new Set<TamperKind>();
  for (const item of raw) {
    const kind = typeof item === "string" ? item : (item as { kind?: unknown })?.kind;
    if ((TAMPER_KINDS as readonly unknown[]).includes(kind)) kinds.add(kind as TamperKind);
  }
  return [...kinds];
}

export type Verdict = {
  mismatch: boolean;
  /** ok: matches. grace: a fresh refund, no strike. warned / suspended: a strike. */
  outcome: "ok" | "grace" | "warned" | "suspended";
  strikes: number;
  /** Tell the app to drop its local unlock. */
  revokeLocal: boolean;
};

/**
 * The online audit: [used] is what the app has been treating as unlocked
 * for this app; [entitled] the live purchase (null: none or revoked);
 * [revokedAt] when a purchase was revoked, if it was; [priorStrikes] from
 * kit_app_bans; [tamper] what the app found wrong with its stored license.
 * Unpaid use or an edited license is a strike: the first warns, the second
 * suspends (premium of this app only, until an admin reviews it). An edited
 * license strikes even for a paying account, and a fresh refund does not
 * excuse it: editing is deliberate.
 */
export function judgeReport(
  used: Entitled,
  entitled: Entitled | null,
  revokedAt: Date | null,
  priorStrikes: number,
  now: Date,
  tamper: TamperKind[] = [],
): Verdict {
  const strike = (): Verdict => {
    const strikes = priorStrikes + 1;
    return {
      mismatch: true,
      outcome: strikes >= 2 ? "suspended" : "warned",
      strikes,
      revokeLocal: true,
    };
  };
  if (tamper.includes("edited")) return strike();
  const overreach = (used.plan === "premium" && entitled?.plan !== "premium") ||
    used.features.some((f) => !unlocks(entitled, f));
  if (!overreach) return { mismatch: false, outcome: "ok", strikes: priorStrikes, revokeLocal: false };
  if (revokedAt && now.getTime() - revokedAt.getTime() < GRACE_DAYS * 86400_000) {
    return { mismatch: true, outcome: "grace", strikes: priorStrikes, revokeLocal: true };
  }
  return strike();
}
