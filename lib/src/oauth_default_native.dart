/// The non-web leaf: the deep-link collector (system browser out, app-link
/// redirect back) is the platform default on Android, iOS and desktop.
library;

import 'oauth_redirect_native.dart' as native_flow;

export 'oauth_redirect_core.dart'
    show OauthRedirectCallbacks, oauthDeepLinkTimeout;
export 'oauth_redirect_native.dart' show collectOAuthFragmentNative;

/// The platform-default collector off the web: the deep-link flow over the
/// real `app_links` backend.
Future<String?> collectOAuthFragmentPlatform(String authorizeUrl) =>
    native_flow.collectOAuthFragmentNative(authorizeUrl);
