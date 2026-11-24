import { assertEquals } from "jsr:@std/assert@1";
import { allowedRedirect, globToRegExp } from "./redirects.ts";

const LIST = [
  "https://mediasart.com/**",
  "https://kalcio.mediasart.com/**",
  "kognitio://auth",
  "http://localhost:*/**",
];

Deno.test("globs follow GoTrue: * stops at . and /", () => {
  assertEquals(globToRegExp("https://*.mediasart.com").test("https://kalcio.mediasart.com"), true);
  assertEquals(globToRegExp("https://*.mediasart.com").test("https://evil.com/.mediasart.com"), false);
});

Deno.test("allowed targets pass, fragment dropped", () => {
  assertEquals(allowedRedirect("https://kalcio.mediasart.com", LIST), "https://kalcio.mediasart.com/");
  assertEquals(allowedRedirect("https://kalcio.mediasart.com/play?x=1#old", LIST), "https://kalcio.mediasart.com/play?x=1");
  assertEquals(allowedRedirect("kognitio://auth", LIST), "kognitio://auth");
  assertEquals(allowedRedirect("http://localhost:5173/", LIST), "http://localhost:5173/");
});

Deno.test("everything else is refused", () => {
  for (const bad of [
    "https://kalcio.mediasart.com.evil.com/",
    "https://evil.com/https://kalcio.mediasart.com/",
    "https://evilmediasart.com/",
    "javascript:alert(1)//https://mediasart.com/",
    "http://kalcio.mediasart.com/",
    "kognitio://auth/../steal",
    "",
    42,
  ]) {
    assertEquals(allowedRedirect(bad, LIST), null, String(bad));
  }
});
