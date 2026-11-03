// Unit test for the welcome mail — no stack, no network, nothing sent.
//
// What it pins is exactly the part a live probe cannot show: which links
// a member receives, and the rule that an unconfigured product sends
// NOTHING rather than a mail full of dead links. The end-to-end half of
// the story (that a first confirmation actually sends it, once) is the
// live check the deploy doc describes.
//
//   deno test supabase/functions/_shared/welcome_test.ts
//
// Dependency-free on purpose: no std import, no env permission needed
// (the config is injected), so it runs anywhere deno does.

import { welcomeLinks, welcomeMail } from "./welcome.ts";

const KATALOGUS = {
  product: "Katalogus",
  web: "https://katalogus.mediasart.com",
  play: "https://play.google.com/store/apps/details?id=com.mediasart.katalogus",
  ios: "https://apps.apple.com/app/katalogus/id0000000000",
  site: "https://mediasart.com",
};

function eq(what: string, want: unknown, got: unknown) {
  if (want !== got) throw new Error(`${what}: want ${want}, got ${got}`);
}

function has(what: string, haystack: string, needle: string) {
  if (!haystack.includes(needle)) throw new Error(`${what}: missing "${needle}"`);
}

function hasNot(what: string, haystack: string, needle: string) {
  if (haystack.includes(needle)) throw new Error(`${what}: unexpected "${needle}"`);
}

Deno.test("a product names its own link set; an unknown one falls back", () => {
  const config = JSON.stringify({
    default: { product: "mediasart", web: "https://mediasart.com" },
    katalogus: KATALOGUS,
  });
  eq("katalogus resolves", "Katalogus", welcomeLinks("katalogus", config)?.product);
  // Not an error and not a caller-chosen URL: the stack's default set.
  eq("unknown falls back", "mediasart", welcomeLinks("whoever", config)?.product);
});

Deno.test("a caller cannot reach Object.prototype to fake a link set", () => {
  // product travels in the request body, so these are reachable inputs. A
  // plain `all[product]` answers each with a FUNCTION (truthy), which used to
  // beat the default and send a welcome with no links instead of skipping it.
  const config = JSON.stringify({
    default: { product: "mediasart", web: "https://mediasart.com" },
    katalogus: KATALOGUS,
  });
  for (const key of ["constructor", "toString", "valueOf", "hasOwnProperty", "__proto__"]) {
    eq(`${key} falls back`, "mediasart", welcomeLinks(key, config)?.product);
  }
});

Deno.test("a config or entry that is not an object is skipped, never thrown", () => {
  eq("null config", null, welcomeLinks("katalogus", "null"));
  eq("array config", null, welcomeLinks("katalogus", "[]"));
  eq("string entry", null, welcomeLinks("x", JSON.stringify({ x: "nope" })));
});

Deno.test("no config (or no default) means no welcome, never a broken one", () => {
  eq("empty config → null", null, welcomeLinks("katalogus", ""));
  eq("invalid JSON → null", null, welcomeLinks("katalogus", "{not json"));
  eq(
    "no entry for this product → null",
    null,
    welcomeLinks("kapax", JSON.stringify({ katalogus: KATALOGUS })),
  );
});

// The env path is the production one, but reading it needs a permission
// this suite otherwise never asks for — so it runs when granted and is
// SKIPPED (not silently passed) otherwise. The live deploy check in
// tool/email_kit_deploy.md covers the same wiring end to end.
const envGranted = (await Deno.permissions.query({ name: "env" })).state === "granted";

Deno.test({
  name: "production reads the set from KIT_WELCOME_LINKS (needs --allow-env)",
  ignore: !envGranted,
  fn() {
    Deno.env.set("KIT_WELCOME_LINKS", JSON.stringify({ katalogus: KATALOGUS }));
    try {
      eq("env is the source", "Katalogus", welcomeLinks("katalogus")?.product);
    } finally {
      Deno.env.delete("KIT_WELCOME_LINKS");
    }
    eq("and nothing is configured now", null, welcomeLinks("katalogus"));
  },
});

Deno.test("the mail carries every configured link, in both bodies", () => {
  const mail = welcomeMail(KATALOGUS);
  eq("subject names the product", "Welcome to Katalogus", mail.subject);
  const wanted = [
    ["web app", KATALOGUS.web],
    ["Play listing", KATALOGUS.play],
    ["App Store listing", KATALOGUS.ios],
    ["mediasart.com", KATALOGUS.site],
  ] as const;
  for (const [label, url] of wanted) {
    has(`html ${label}`, mail.html, `href="${url}"`);
    has(`text ${label}`, mail.text, url);
  }
  has("html says confirmed", mail.html, "confirmed");
  has("text reminds how to sign in", mail.text, "password you chose");
});

Deno.test("a stack without store listings sends a shorter mail, not dead links", () => {
  const mail = welcomeMail({
    product: "Kapax",
    web: "https://kapax.example",
    site: "https://mediasart.com",
  });
  has("web", mail.html, "https://kapax.example");
  has("site", mail.text, "https://mediasart.com");
  hasNot("no Play row", mail.html, "play.google.com");
  hasNot("no App Store row", mail.text, "apps.apple.com");
});

Deno.test("link values are escaped into the HTML", () => {
  const mail = welcomeMail({ product: "X", web: 'https://e.example/?a=1&b="2"' });
  has("ampersand escaped", mail.html, "a=1&amp;b=&quot;2&quot;");
  hasNot("no raw quote", mail.html, 'b="2"');
});
