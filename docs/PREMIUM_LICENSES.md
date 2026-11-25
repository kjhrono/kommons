# Premium licenses

Premium is sold per app. Buying it in one app unlocks nothing in another.

- **Online**, premium works on every device the player signs in on.
- **Offline**, it works on one device only: the one holding a signed license.
- **Back online**, the app reports what it used offline, and the server
  checks that against the purchase.

## How each rule is enforced

| Rule | How |
| --- | --- |
| Can't edit the unlock | The license is signed with Ed25519 by the server. Apps hold only the public key, so any edit breaks the signature. |
| Can't copy it to another phone | The license names the phone's hardware key (`device_key` plugin: Android Keystore / StrongBox, iOS Secure Enclave). That key can't be read out, even with root, so on another phone the key doesn't match. |
| One offline phone per account and app | The server keeps one holder row per (account, app). Taking it on another phone is a "move": 3 per 30 days. |
| Offline use ends if the license moves or is refunded | Leases last 14 days and renew online, so a phone that stays offline loses premium within 14 days. |
| Can't stretch a lease with the clock | The app remembers the latest time it has seen. A clock more than 10 minutes behind that blocks offline use until the next connection. |
| Online, the server decides | The token hook adds `kit_entitlements` and `kit_app_bans` to every token. A fresh token (not expired) wins over the license. |
| Unpaid use gets caught | Back online, the app reports what it used offline (`report`). Unpaid use: 1st time a warning and the license is dropped; 2nd time this app's premium is suspended until you review it. A refund less than 3 days old is no strike. |
| Tampering found offline is reported | When the stored license is useless, the app drops it and reports why at the next connection. Only an **edited** license (well-formed, signature fails) is a strike, even for a paying account. Honest causes are logged only, see below. |
| Cloud data is protected too | Project stacks can guard premium rows in RLS with `kit_jwt_has_premium('app', 'feature')`, which reads the token only. |

**What the app reports, and what strikes**

| Finding | Likely cause | Strike? |
| --- | --- | --- |
| `edited` | someone changed the file | yes |
| `other_device` | Android auto-backup restored it on a new phone, or it was copied | no, logged |
| `other_account` | another account signed in on the phone | no, logged |
| `clock` | the clock was set back (the license is kept, it works again once the clock is right) | no, logged |
| `corrupt` | a broken write | no, logged |

**Rotating the signing key.** Pass the old public keys in
`ShellEntitlements(previousLicenseKeys: [...])`. A license signed with an old
key is then renewed at the next connection, not reported as edited.

The log: `{"action":"reports","app_id":"…"}` with the service key (each report
row has a `tamper` column).

**Limit.** A rooted user can still modify the app itself so it skips these
checks. Signing and device binding make the license file useless to them, not
a modified app. What stops a modified app is the online side: the server
refuses premium cloud actions, and the report check catches unpaid use. A
modified app can only work fully offline, until it connects.

Still to add:
- Play Integrity / App Attest checks on `activate` and `renew`
- store receipt checks before `grant`

## App side

```dart
final premium = ShellEntitlements(
  'katalogus',                          // the app id on the server
  licensePublicKey: 'XYCT…PvQ=',        // from tool/license_keygen.ts
  deviceLabel: 'Marco’s Pixel',         // optional, shown on other devices
);

ShellTopBar(plan: premium, ...);
if (premium.unlocks('export')) { ... }
await premium.checkNow();               // right after a purchase

SettingsScreen(extraSections: [PremiumOfflineCard(entitlements: premium)]);
```

- The first device with premium takes the offline license automatically. Moving
  it is always the player's choice, from `PremiumOfflineCard`.
- Web and desktop have no hardware key, so premium works there only while
  online.
- Android: `minSdk` 23. iOS: 13.

## Server side (`email_auth_kit`)

- **Migration** `20261125000000_email_auth_kit_licenses.sql`:
  - tables `kit_entitlements`, `kit_offline_licenses`, `kit_license_moves`,
    `kit_license_reports`, `kit_app_bans`
  - the token hook, now with the two premium claims
  - `kit_jwt_has_premium`
- **Function** `supabase/functions/license`.
  - Player actions (user token): `activate`, `renew`, `status`, `report`.
  - Admin actions (service-role key): `grant`, `revoke`, `unsuspend`,
    `reports`.
- **Signing key:** `deno run tool/license_keygen.ts`. Put
  `LICENSE_SIGNING_KEY` in the function's env as a secret; put the public key
  in the apps.
- **Your purchase backend** verifies the store receipt, then calls `grant`
  (and `revoke` on refunds).

```bash
curl -X POST "$AUTH/functions/v1/license" -H "authorization: Bearer $SERVICE_ROLE_KEY" \
  -d '{"action":"grant","email":"player@example.com","app_id":"katalogus","plan":"premium","source":"play","purchase_ref":"GPA.1234"}'
```

Tests:
- `deno test supabase/functions/_shared/license_test.ts` — the rules
- `teststack/license_e2e.ts` — against a running teststack (steps in the file)
