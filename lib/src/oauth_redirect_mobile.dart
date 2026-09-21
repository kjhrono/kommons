/// The OAuth collector for the non-web branches. The shared deep-link flow
/// ([collectOAuthFragmentDeepLink], fully test-injected) is re-exported for
/// hosts and tests; the default native collector wires it to the real
/// `app_links` backend.
library;

export 'oauth_redirect_core.dart';
export 'oauth_redirect_native.dart';
