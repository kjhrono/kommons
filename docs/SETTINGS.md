# Shared settings

`SettingsScreen` gives every app the same sections in the same order:

| Section | What's in it | Shown when |
| --- | --- | --- |
| Profile | player name, avatar | always |
| Account | the shared account card, or the app's own card (`leadingSections`, e.g. `IdentityAccountCard`), and Delete account (this app, or the whole account on mediasart.com) | always; Delete account only while signed in |
| Appearance | day/night, colour theme, high contrast (or the app's `appearanceSection`) | always |
| Language | language picker | always |
| Data | backup card (`backup`), the app's data cards (`dataSections`) | the app passes one of them |
| Premium | `premiumSection` (usually `PremiumOfflineCard`) | the app passes it |
| About | version; tap for the About dialog | always |
| (app) | `extraSections`, the app's own cards | the app passes them |

To hide a section, pass it in `hiddenSections: {ShellSettingsSection.language}`.

```dart
SettingsScreen(
  leadingSections: [IdentityAccountCard(host: myHost)],
  showAccountCard: false,
  backup: MyBackup(),
  premiumSection: PremiumOfflineCard(entitlements: premium),
  onRemoveAppData: () => myRepository.deleteEverythingForThisUser(),
)
```

## Change password

- **The shared account card** already had it.
- **`IdentityAccountCard`** now has a "Change password" button. It shows only
  for accounts with a password: a Google-only account has none to change.
  The dialog asks for the new password twice. The identity stack then issues
  fresh session tokens, and the card hands them to the host.

## Colour themes

- **The picker:** the app's own colour plus 8 presets: Ocean, Teal, Forest,
  Gold, Sunset, Berry, Violet, Slate.
- **Presets only:** a free colour wheel often gives colours that are hard to
  read, so there isn't one.
- **How it's applied:** `ShellApp` builds the Material 3 theme from the chosen
  colour, so dark mode and high contrast keep working. With a custom
  `themeBuilder`, the app's shapes and fonts stay and only the colours follow
  the pick.
- **Sync:** the choice is shared across apps (`kommons.accent`), like the
  language.
- **Opting out:** `ShellApp(allowAccent: false)` keeps the app's look fixed
  and hides the picker.

## Backup

The app implements `ShellBackupSource`:

```dart
class MyBackup implements ShellBackupSource {
  @override String get appId => 'notes';
  @override int get schemaVersion => 2;          // bump when the data shape changes
  @override Future<Map<String, dynamic>> exportData() async => {...};
  @override Future<void> importData(Map<String, dynamic> data, int fromVersion) async {...};
}
```

The shell handles the file:
- **What's in it:** the app id, the data version, the date and a SHA-256
  checksum.
- **Optional password:** the file is then encrypted (PBKDF2-SHA256 with
  120,000 rounds, then AES-256-GCM). Without the password it can't be restored.
- **Saving:** a save dialog on phones and desktop, a download on the web
  (`file_picker`).
- **Importing:** the file picker, then the password if the file has one, then
  a confirmation before anything is replaced.
- **Refused files:** another app's backup, a backup from a newer version
  (update the app first), and damaged or edited files.
- **Licenses stay out:** premium licenses are never in a backup. The app
  exports only its own data, and a license only works on its own phone anyway.

## Delete account

Required by Google Play and the App Store for apps with accounts. It shows
while an account is signed in and asks what to delete.

**Remove my data from this app**
1. The player types `DELETE` (`ELIMINA` in Italian) to confirm.
2. The app's `onRemoveAppData` deletes everything it keeps for the player
   in its own database, while the sign-in token still works. If it throws,
   nothing is deleted.
3. The kit's `account-delete` function (scope `app`) removes the app's
   purchases, offline licenses, device moves and reports. Strikes and
   suspensions stay, so leaving and rejoining can't wipe them.
4. This phone's license files for the app are deleted, and the player is
   signed out here.

The MediaSart account, mediasart.com and the other apps are untouched. The
app's id on the server is `SettingsScreen.gameId`.

**Delete my MediaSart account**
This opens the mediasart.com account page (`account.accountPageUrl`, by
default `https://mediasart.com/<lang>/account`, following
`account.mediasartHub`). Deleting the whole account happens there. That page
is still to be written; it will call `account-delete` with scope `account`.

```dart
SettingsScreen(
  gameId: 'katalogus',
  appName: 'Katalogus',
  onRemoveAppData: () => myRepository.deleteEverythingForThisUser(),
)
```

## Tests

- Dart: `test/settings_additions_test.dart`, plus the change-password tests in
  `test/identity_account_card_test.dart`
- Server: the delete step in `email_auth_kit/teststack/license_e2e.ts`
