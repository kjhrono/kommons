import 'package:app_links/app_links.dart';

import 'oauth_redirect_core.dart';

/// Native implementation of the deep-link collector: the shared flow over
/// the real app_links plumbing. Android App Links, iOS Universal Links and
/// custom-scheme links all deliver through the same stream.
Future<String?> collectOAuthFragmentNative(String authorizeUrl) {
  final links = AppLinks();
  return collectOAuthFragmentDeepLink(
    authorizeUrl,
    callbacks: OauthRedirectCallbacks(
      initial: links.getInitialLink,
      stream: links.uriLinkStream,
    ),
  );
}

/// Native implementation of the PKCE code collector: the code-aware flow
/// over the same app_links plumbing, returning the authorization `code`.
Future<String?> collectOAuthCodeNative(String authorizeUrl) {
  final links = AppLinks();
  return collectOAuthCodeDeepLink(
    authorizeUrl,
    callbacks: OauthRedirectCallbacks(
      initial: links.getInitialLink,
      stream: links.uriLinkStream,
    ),
  );
}
