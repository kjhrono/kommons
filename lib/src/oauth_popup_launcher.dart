/// The provider sign-in collector, selected at compile time:
///
///  * **web** (`oauth_default_web.dart`) — the popup collector polls a
///    popup window back onto the app's origin — no configuration;
///  * **Android / iOS** (`oauth_default_native.dart`) — the deep-link
///    collector opens the authorize page in the system browser and
///    completes when the game server's redirect re-opens the app (custom
///    scheme, Android App Links or iOS Universal Links), delivering the
///    implicit fragment (`…#access_token=…&refresh_token=…`) to
///    [AccountController].
///
/// Hosts may replace the collector entirely
/// (`account.collectOAuthFragment = …`) — a dedicated callback page or a
/// fully custom deep-link flow are natural substitutions.
library;

import 'oauth_default_native.dart'
    if (dart.library.js_interop) 'oauth_default_web.dart' as platform;

export 'oauth_default_native.dart'
    if (dart.library.js_interop) 'oauth_default_web.dart'
    show collectOAuthFragmentPlatform;
export 'oauth_redirect_core.dart'
    show OauthRedirectCallbacks, oauthDeepLinkTimeout;
export 'oauth_redirect_mobile.dart'
    show collectOAuthFragmentDeepLink, collectOAuthFragmentNative;

/// The default collector for the compiled platform.
Future<String?> collectOAuthFragment(String authorizeUrl) =>
    platform.collectOAuthFragmentPlatform(authorizeUrl);
