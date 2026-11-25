// Generates the license signing key pair.
//
//   deno run tool/license_keygen.ts
//
// LICENSE_SIGNING_KEY goes into the license function's env (a secret: it is
// the power to mint premium). The public key goes into each app
// (ShellEntitlements.licensePublicKey) — safe to embed.

const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
  "sign",
  "verify",
]) as CryptoKeyPair;

const b64 = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf)));

console.log(`LICENSE_SIGNING_KEY=${b64(await crypto.subtle.exportKey("pkcs8", pair.privateKey))}`);
console.log(`public key (for apps): ${b64(await crypto.subtle.exportKey("raw", pair.publicKey))}`);
