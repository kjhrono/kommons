/// The non-web leaf: the deep-link collector (system browser out, app-link
/// redirect back) is the platform default on Android, iOS and desktop.
library;

import 'oauth_redirect_native.dart' as native_flow;

export 'oauth_redirect_core.dart'
    show OauthRedirectCallbacks, oauthDeepLinkTimeout, oauthCodeFromUri;
export 'oauth_redirect_native.dart'
    show collectOAuthFragmentNative, collectOAuthCodeNative;

/// The platform-default collector off the web: the deep-link flow over the
/// real `app_links` backend.
Future<String?> collectOAuthFragmentPlatform(String authorizeUrl) =>
    native_flow.collectOAuthFragmentNative(authorizeUrl);

/// The platform-default PKCE collector off the web: the code-aware
/// deep-link flow over the real `app_links` backend.
Future<String?> collectOAuthCodePlatform(String authorizeUrl) =>
    native_flow.collectOAuthCodeNative(authorizeUrl);
