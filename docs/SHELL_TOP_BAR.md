# Shell top bar

`ShellTopBar` (`lib/src/shell_top_bar.dart`) is the account-and-status bar
every app shares. It sits in `Scaffold.appBar`. Each app puts its own screen
bar (screen name, back button) below it, in the body.

```
┌──────────────────────────────────────────────────────────┐
│ (MS) Marco Sartori  [G][✉]                 PREMIUM   ⓘ   │
│ ⟳ Cloud · synced                          🔔²  ☾   ⚙    │
└──────────────────────────────────────────────────────────┘
```

- **Row 1:** avatar, name (email when there is no name), one small icon per
  sign-in method (email, Google; the no-account icon when signed out). On the
  right: the FREE / PREMIUM badge and ⓘ (About: app name, version, plan).
- **Row 2:** storage status (tap: "Sync now" and the local/cloud choice). On
  the right: notifications, day/night toggle, settings.
- From `wideBreakpoint` (720 by default) up, both rows share one line.
- Tapping the identity opens settings. Sign-in and sign-out live there, not
  in the bar.

Optional slots left null are not drawn.

## Using it

```dart
Scaffold(
  appBar: ShellTopBar(
    plan: myPlan,                       // ValueListenable<ShellPlan>
    sync: mySync,                       // ShellSyncController
    unreadNotifications: myUnread,      // ValueListenable<int>
    onNotificationsPressed: (context) => openInbox(context),
    settingsBuilder: () => MySettings(),
  ),
  body: Column(children: [MyScreenBar(title: 'Orders'), ...]),
)
```

### Identity

- Default: the shell's own `account` controller (`ShellAccountIdentity`).
- Apps on the MediaSart identity stack: `identity: ShellIdentityHostIdentity(myHost)`
  (see `IDENTITY_ACCOUNT_CARD.md`), and pass the same host to
  `ShellApp(identityHost: myHost)`. The shell then syncs theme, language,
  name and avatar with that account, exactly as with its own sign-in.
  Without `ShellApp`, call `account.attachIdentityHost(myHost)` at startup.
- Anything else: any `ValueListenable<ShellIdentity>`.

### Plan (per-app premium)

Pass a `ShellEntitlements` (`plan: premium`). Premium is bought per app,
works on every device while online, and offline on one device only, through
a server-signed license tied to that phone. Details, server setup and limits:
[PREMIUM_LICENSES.md](PREMIUM_LICENSES.md).

### Storage and sync

Subclass `ShellSyncController`, implement `syncNow()`, and update `value`
(`ShellSyncState`) as things happen:

| State | Bar shows |
| --- | --- |
| `mode: local` | 📱 Local |
| cloud, `online: false` | Offline · local · N to sync |
| cloud, `phase: syncing` | Syncing… |
| cloud, `phase: error` | Sync failed |
| cloud, idle, pending > 0 | Cloud · N to sync |
| cloud, idle, nothing pending | Cloud · synced |

Set `online` from real request outcomes, not just the network interface:
wifi being up does not mean the server is reachable. Override `setMode` to also
move data (call `super.setMode`).

## Name and avatar

Settings → Player name now also has:

- **Avatar picker:** initials, the Google photo (when the account has one) and
  12 built-in icon presets. Saved with `account.setAvatar(...)`.
- **"Use 'Full Name'"** chip when the account carries a Google name.

Both sync across projects through the account's `user_metadata`, under the
same `kommons` slice as theme, language and name (`kommons.avatar`: `initials`,
`provider` or `preset:<id>`). This works for the shell's own sign-in and for
an attached identity host. Every app and site on the same auth server
(including mediasart.com) reads the same value. Only the signed-in user can
read it. Showing other people's profiles needs a public profiles table later.

Unset avatar: the Google photo if there is one, initials otherwise.

## Migrating from `AppTopBar`

`AppTopBar` and `AppTopBarActions` were removed. Replace them with
`ShellTopBar` in `Scaffold.appBar` (same `settingsBuilder` and `gameId`), and
move any screen title into the app's own screen bar below it. The version is
now in the About dialog (ⓘ). `AppSplash` already uses `ShellTopBar`.
