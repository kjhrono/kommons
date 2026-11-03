// email_auth_kit — the welcome mail's link sets and its renderer.
//
// Kept out of the functions so it can be tested without a stack, and
// because two of them share it: email-verification sends the welcome when
// an address is confirmed for the first time.
//
// The links are SERVER configuration, never client input. A request only
// names its product, and an unknown name falls back to the "default"
// entry — so a caller can never put arbitrary URLs into a mail that
// leaves our sender. A product with no configured set gets no welcome
// mail at all (the caller logs it), rather than a mail full of dead links.
//
//   KIT_WELCOME_LINKS={"default":{...},"katalogus":{...}}
//
// Test: deno test supabase/functions/_shared/welcome_test.ts

import { page } from "./brevo.ts";

export interface WelcomeLinks {
  product?: string; // display name, e.g. "Katalogus"
  web?: string; // the web app
  play?: string; // Google Play listing
  ios?: string; // App Store listing
  site?: string; // the company site
}

/// The welcome link set for [product], or null when there is nothing
/// configured to send (never a partial guess: an unset/invalid config or
/// an unresolvable product is logged and skipped by the caller).
///
/// [config] defaults to the KIT_WELCOME_LINKS env var and is only ever
/// overridden by the tests — reading it here rather than at module load
/// keeps the module importable without env permissions.
export function welcomeLinks(
  product: string,
  config: string | undefined = Deno.env.get("KIT_WELCOME_LINKS"),
): WelcomeLinks | null {
  const raw = config;
  if (!raw) {
    console.log("welcome: KIT_WELCOME_LINKS is not configured — welcome mail skipped");
    return null;
  }
  let all: Record<string, WelcomeLinks>;
  try {
    all = JSON.parse(raw) as Record<string, WelcomeLinks>;
  } catch {
    console.error("welcome: KIT_WELCOME_LINKS is not valid JSON — welcome mail skipped");
    return null;
  }
  // A config that parses but is not an object ("null", "[]", a bare string)
  // has no link sets to read: skip the mail rather than throw on the lookup.
  if (all === null || typeof all !== "object" || Array.isArray(all)) {
    console.error("welcome: KIT_WELCOME_LINKS is not an object — welcome mail skipped");
    return null;
  }
  // `Object.hasOwn`, not `all[product] ?? all.default`: product is CLIENT input,
  // and a plain lookup answers "constructor" or "toString" with a function off
  // Object.prototype — truthy, so the fallback never ran and the mail went out
  // with no links at all instead of being skipped.
  const picked = Object.hasOwn(all, product) ? all[product] : all.default;
  if (picked === null || typeof picked !== "object") {
    console.log(`welcome: no link set for product "${product}" — welcome mail skipped`);
    return null;
  }
  return picked;
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/// Renders the welcome: one row per configured link, in product order
/// (web app → Google Play → App Store → the company site), so a stack
/// that has no store listings yet simply leaves those two out.
export function welcomeMail(links: WelcomeLinks): {
  subject: string;
  text: string;
  html: string;
} {
  const name = links.product ?? "mediasart";
  const rows: { label: string; url: string }[] = [];
  if (links.web) rows.push({ label: "Open the web app", url: links.web });
  if (links.play) {
    rows.push({ label: "Get the Android app on Google Play", url: links.play });
  }
  if (links.ios) {
    rows.push({ label: "Get the iPhone / iPad app on the App Store", url: links.ios });
  }
  if (links.site) rows.push({ label: "mediasart.com", url: links.site });

  const text =
    `Welcome to ${name} — your e-mail address is confirmed and your account is ready.\n\n` +
    `Sign in any time with the e-mail address and password you chose.\n\n` +
    rows.map((r) => `${r.label}: ${r.url}`).join("\n") +
    "\n";

  const items = rows
    .map(
      (r) =>
        `<li style="margin-bottom:10px"><a href="${esc(r.url)}">${esc(r.label)}</a><br>` +
        `<span style="color:#667085;font-size:12px;word-break:break-all">${esc(r.url)}</span></li>`,
    )
    .join("\n     ");

  const html = page(
    `Welcome to ${esc(name)}`,
    `<p>Your e-mail address is confirmed — your account is ready.</p>
     <p>Sign in any time with the e-mail address and password you chose.</p>
     <ul style="padding-left:18px;line-height:1.6">${items}</ul>`,
  );

  return { subject: `Welcome to ${name}`, text, html };
}
