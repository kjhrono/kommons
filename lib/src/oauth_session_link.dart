// The OAuth session-fragment app link: an authorize redirect that re-opens
// the app (`…#access_token=…&refresh_token=…`) is normally consumed by the
// deep-link collector mid-flow — but the app can also be cold-started or
// warm-reopened by such a link when no collector is waiting (the browser
// session outlived the flow, the redirect was delivered twice, the player
// re-tapped a notification). The shell treats that link as a restore: the
// session it carries is installed like any other sign-in, so the preference
// sync — and its visible notice — runs on it too.
library;

import 'auth_service.dart';

/// True when the fragment carries an OAuth session payload. Non-session
/// fragments (recovery `token`, `token_hash`, join codes, `error=…`,
/// PKCE `code=…`, anything else) read false — the shell's watchers stay
/// disjoint by construction.
bool oauthSessionFragment(String fragment) {
  final session = AuthService.sessionFromImplicitFragment(fragment);
  return session != null;
}

/// True when the [uri] carries an OAuth session fragment.
bool oauthSessionLinkFromUri(Uri uri) => oauthSessionFragment(uri.fragment);
