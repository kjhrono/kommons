# Identity account card

`IdentityAccountCard` (`lib/src/identity_account_card.dart`) is the settings
card for apps on the shared MediaSart identity stack (`auth.mediasart.com`,
GoTrue on fundb). It shows who is signed in and with which methods. One
account can carry both email and Google. It offers:

- **Sign in** with email and password, plus the kit's `RegistrationFlow` to
  create an account.
- **Sign in with Google** when signed out.
- **Add Google** when signed in with email. Google is linked onto the SAME
  account through `auth_kit_link_google_identity`, never a second account.
  The session is then refreshed so the card shows both methods.
- **Sign out**.

It follows `appLocale` (English, Italian). Katalogus was the first app to use
it (`lib/features/shell/account_card.dart`).

## Adopting it

1. Depend on `kommons` and `mediasart_auth_client` (`kommons/email_auth_kit`).
2. Implement `IdentityAccountHost`. The app owns where the session lives;
   the card owns the flows.

   ```dart
   class MyIdentityHost extends IdentityAccountHost {
     @override
     MediasartAuth get auth => myAuth; // MediasartAuth for auth.mediasart.com
     @override
     String get oauthRedirectTo =>
         kIsWeb ? 'https://myapp.mediasart.com/' : 'myapp://auth';
     @override
     String get resetRedirectTo => 'https://myapp.mediasart.com/#/reset-password';
     @override
     AuthSession? get currentSession => mySessionStore.current;
     @override
     Stream<Object?> get sessionChanges => mySessionStore.changes;
     @override
     Future<void> adoptSession(AuthSession s) => mySessionStore.save(s);
     @override
     Future<void> signOut() => mySessionStore.clear();
     // Optional: googleEnabled, prepare(), afterSignIn(context), collectCode().
   }
   ```

3. Put it in settings. With the shared `SettingsScreen`, hide its own
   account card and lead with this one:

   ```dart
   SettingsScreen(
     showAccountCard: false,
     leadingSections: [IdentityAccountCard(host: MyIdentityHost())],
   )
   ```

   `notSignedInText` and `createAccountLabel` let the app adjust those two
   lines.

The pieces work on their own too:

- `signInOrLinkGoogle(host)` runs the Google step for an app's own button.
- `collectGoogleSession(host)` runs only the PKCE round trip.
- `IdentityAccountInfo.fromSession(session)` reads the linked methods from
  the session.

## Server side

- **Google** is one Web OAuth client for the whole identity stack. Its only
  redirect URI is `https://auth.mediasart.com/auth/v1/callback`. Apps need
  no Google client of their own.
- **Redirects** must be allowed by GoTrue, or the sign-in silently lands on
  the site URL instead of returning to the app:
  - Web: every `https://*.mediasart.com/**` origin is already allowed.
  - Android/iOS: add the app's scheme verbatim (e.g. `myapp://auth`). Edit
    `ADDITIONAL_REDIRECT_URLS` in `/srv/databases/fundb/.env` on
    `mediasart_u26`, then run `docker compose up -d --force-recreate auth`
    in `/srv/databases/fundb`. The app must also claim the scheme: an
    intent filter on `MainActivity` (Android), `CFBundleURLTypes` (iOS).
- `tool/identity-redirect-allowlist.txt` and `tool/identity_allowlist_sync.sh`
  describe the identity stack from before fundb: `site_url` is Katalogus
  and only its entries are listed. Do not run `--apply`/`--heal` against
  fundb until the declaration is updated, or it would overwrite fundb's
  `SITE_URL` and list.
