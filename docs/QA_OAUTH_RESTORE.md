# Manual QA — OAuth session restore (Android & iOS)

The restore path handles one case: an authorize redirect
(`…#access_token=…&refresh_token=…`) that re-opens the app **when no
sign-in collector is waiting**. The shell installs the session like any
sign-in — preference sync and its notice included. Everything below runs
against a build with `ShellApp` defaults (`restoreSessionsFromLinks: true`).

## 0. Setup (once)

- [ ] App installed, **no session on the device** (fresh install or after
      sign-out), game server configured (host/join an online room once) —
      the restore declines quietly without one.
- [ ] Cloud account has preferences worth pulling: sign in on another
      project (or the web build), set a distinctive theme + language +
      player name.
- [ ] **Capture a live session link**: run a real provider sign-in on the
      device, and when the provider redirects back, copy the final URL
      from the browser address bar (`https://<origin>/#access_token=…`).
      That URL is the payload for every test below. Do this twice (see
      A3/A5) — tokens are single-use after redemption.

## 1. Which links to send

| # | Link | Expectation |
|---|------|-------------|
| A1 | Live session fragment (`#access_token=…&refresh_token=…`) | Restores the session |
| A2 | Same URL, delivered a second time | **No-op** (dedupe) |
| A3 | A *second* session link with a fresh token (repeat setup capture) | Restores again |
| A4 | Already-redeemed token (re-send A1's URL after it was consumed) | **Quiet no-op** — dead token, nothing on screen |
| B1 | Recovery fragment (`#token=…` from the reset email) | Recovery watcher handles it; **restore stays out** |
| B2 | Join link (`…#join=K7QX2`) | Lobby handoff; **no sign-in** |
| B3 | Error fragment (`#error=access_denied…`) | Quiet no-op |
| B4 | PKCE fragment (`#code=…`) | Quiet no-op |

## 2. Android

**Cold start** (`adb shell am force-stop <pkg>` first, then):

```bash
adb shell am start -a android.intent.action.VIEW -d "<URL>" <pkg>
```

- [ ] A1 cold: app opens → signed in (splash welcome shows the pulled
      player name) → sync notice fires (§3) if cloud differed from device.
- [ ] A4 cold (dead token): app opens **signed out, silent** — no error
      dialog, no crash.
- [ ] B1–B4 cold: the right watcher reacts (recovery → reset flow, join →
      lobby); the restore path stays silent.

**Warm return** (app running in background, signed out):

- [ ] Open A1 via link (from Messages/Chrome) → same restore as cold,
      notice included.
- [ ] A2 warm: re-open the *same* URL → no second sign-in flicker, no
      second notice.
- [ ] **Mid-flow guard**: tap the provider button (collector armed), let
      the browser complete the redirect normally → sign-in happens once;
      no duplicate install, no duplicate notice.

## 3. iOS

**Cold start** (remove the app from the switcher first):

- Simulator: `xcrun simctl openurl booted "<URL>"` after relaunching.
- Device: paste A1 into Safari or Messages and tap it.

**Warm return** (app in background, signed out): same delivery, same
expectations as Android's warm list.

- [ ] Universal Links deliver without leaving Safari (swipe banner back);
      custom-scheme builds open directly.
- [ ] A1 cold/warm, A2 dedupe, A4 quiet, B1–B4 disjoint — as Android.

## 4. What to watch on the sync notice

The notice (`Preferences loaded from your account` / IT equivalent)
**fires only on actual changes** pulled by the restore.

- [ ] First restore on a fresh device (cloud ≠ device) → notice appears,
      once, over any screen (root messenger, not a local scaffold).
- [ ] Sign out, restore **again with identical cloud values** → **no**
      notice (change-counting; identical pull is silent).
- [ ] Change something in the cloud (other project or web build), restore
      again → notice fires again (one display per event — re-listens and
      re-pumps never duplicate it).
- [ ] Restore pulls the **locale** itself → the notice text appears in
      the *new* language.
- [ ] `ShellApp(showPreferencesSyncedNotice: false)` → sync still runs
      (values change), notice never shows.

## 5. Quiet-by-design outcomes (no toast, no dialog, no crash)

Dead/expired token · no server configured · unconfirmed email · unknown
fragment · duplicate delivery · restore racing an armed collector.

---

Companion docs: client flow in COMMONS.md (OAuth + Invites sections),
server setup in docs/OAUTH_SERVER_SETUP.md.
