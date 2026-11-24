// email_auth_kit — sso-handoff edge function ("Sign in with MediaSart").
//
// The hub (mediasart.com/<lang>/connect) is where a player is already
// signed in. When a project app sends the player there, the hub asks this
// function for a FRESH, independent session for the same account and
// hands it back to the app in the same implicit-fragment shape GoTrue's
// OAuth redirect uses (`#access_token=…&refresh_token=…`), so every
// client that already speaks Google sign-in speaks this too.
//
//   POST { redirect_to }   Authorization: Bearer <hub access token>
//     → 200 { access_token, refresh_token, expires_in, expires_at, token_type }
//
// Why a new session instead of sharing the hub's: GoTrue rotates refresh
// tokens, so two apps holding the same one would sign each other out.
// Here each app gets its own session family; signing out of one leaves
// the others (and the hub) alone.
//
// How: admin generate_link(type=magiclink) → hashed_token → /verify. The
// token is single-use and consumed immediately; generate_link never mails
// (the send-email hook is not called). /verify runs the custom access
// token hook, so the kit's ban claim lands in the new token as usual.
//
// Gating:
//   * the caller's bearer must be a live session (GET /auth/v1/user);
//   * a live kit ban (kit_banned_until claim) is refused;
//   * redirect_to must match KIT_SSO_REDIRECTS — the same globs as
//     GoTrue's ADDITIONAL_REDIRECT_URLS (one allow-list for both doors);
//   * only the hub's origin(s) may call it from a browser
//     (KIT_SSO_HUB_ORIGINS, comma-separated; default https://mediasart.com).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (runtime),
//      KIT_SSO_REDIRECTS, KIT_SSO_HUB_ORIGINS (compose override).

import { allowedRedirect as allowed } from "../_shared/redirects.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HUBS = (Deno.env.get("KIT_SSO_HUB_ORIGINS") ?? "https://mediasart.com")
  .split(",").map((s) => s.trim()).filter(Boolean);
const REDIRECT_GLOBS = (Deno.env.get("KIT_SSO_REDIRECTS") ?? "")
  .split(",").map((s) => s.trim()).filter(Boolean);

function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  return {
    "access-control-allow-origin": HUBS.includes(origin) ? origin : HUBS[0] ?? "null",
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "POST, OPTIONS",
    "vary": "origin",
  };
}

function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(req), "content-type": "application/json", "cache-control": "no-store" },
  });
}

function claims(token: string): Record<string, unknown> {
  try {
    const part = token.split(".")[1] ?? "";
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(b64 + "===".slice((b64.length + 3) % 4)));
  } catch {
    return {};
  }
}

async function auth(path: string, init: RequestInit & { key?: string; bearer?: string }) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      apikey: init.key ?? ANON,
      ...(init.bearer ? { authorization: `Bearer ${init.bearer}` } : {}),
    },
  });
  let body: Record<string, unknown> = {};
  try {
    body = await res.json();
  } catch {
    // empty / non-JSON body
  }
  return { status: res.status, body };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  // A browser call must come from the hub; native callers send no Origin.
  const origin = req.headers.get("origin");
  if (origin && !HUBS.includes(origin)) return json(req, 403, { error: "origin_not_allowed" });

  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer || bearer === ANON || bearer === SERVICE) {
    return json(req, 401, { error: "session_required" });
  }

  let payload: Record<string, unknown> = {};
  try {
    payload = await req.json();
  } catch {
    return json(req, 400, { error: "invalid_body" });
  }
  const redirect = allowed(payload.redirect_to, REDIRECT_GLOBS);
  if (!redirect) return json(req, 400, { error: "redirect_not_allowed" });

  // Live session? (GoTrue answers 401/403 for expired, revoked or forged.)
  const me = await auth("/user", { method: "GET", bearer });
  const email = typeof me.body.email === "string" ? me.body.email : "";
  if (me.status !== 200 || !email) return json(req, 401, { error: "session_invalid" });

  // The kit's data-plane ban rides in the token; GoTrue's native ban is
  // enforced by /verify below.
  const bannedUntil = claims(bearer)["kit_banned_until"];
  if (typeof bannedUntil === "string" && Date.parse(bannedUntil) > Date.now()) {
    return json(req, 403, { error: "banned" });
  }

  const link = await auth("/admin/generate_link", {
    method: "POST",
    key: SERVICE,
    bearer: SERVICE,
    body: JSON.stringify({ type: "magiclink", email }),
  });
  const hashed = (link.body.hashed_token ??
    (link.body.properties as Record<string, unknown> | undefined)?.hashed_token) as
    | string
    | undefined;
  if (link.status !== 200 || !hashed) {
    console.error("sso-handoff: generate_link failed", link.status, link.body.error_code ?? link.body.msg);
    return json(req, 502, { error: "handoff_failed" });
  }

  const session = await auth("/verify", {
    method: "POST",
    body: JSON.stringify({ type: "magiclink", token_hash: hashed }),
  });
  if (session.status !== 200 || typeof session.body.access_token !== "string") {
    const code = session.body.error_code;
    if (code === "user_banned") return json(req, 403, { error: "banned" });
    console.error("sso-handoff: verify failed", session.status, code ?? session.body.msg);
    return json(req, 502, { error: "handoff_failed" });
  }

  console.log(`sso-handoff: ${me.body.id} -> ${new URL(redirect).origin}`);
  return json(req, 200, {
    access_token: session.body.access_token,
    refresh_token: session.body.refresh_token,
    expires_in: session.body.expires_in,
    expires_at: session.body.expires_at,
    token_type: session.body.token_type ?? "bearer",
  });
});
