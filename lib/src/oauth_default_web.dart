/// The web leaf: the popup collector is the platform default in a browser.
library;

import 'oauth_popup_launcher_web.dart' as popup;

export 'oauth_popup_launcher_web.dart'
    show collectOAuthFragmentWeb, collectOAuthCodeWeb;
export 'oauth_redirect_core.dart'
    show OauthRedirectCallbacks, oauthDeepLinkTimeout, oauthCodeFromUri;

/// The platform-default collector on the web: the popup flow.
Future<String?> collectOAuthFragmentPlatform(String authorizeUrl) =>
    popup.collectOAuthFragmentWeb(authorizeUrl);

/// The platform-default PKCE collector on the web: the popup flow, returning
/// the authorization `code` instead of the implicit fragment.
Future<String?> collectOAuthCodePlatform(String authorizeUrl) =>
    popup.collectOAuthCodeWeb(authorizeUrl);
