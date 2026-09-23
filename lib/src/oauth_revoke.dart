// Provider-grant revocation: when the player signs out of a session that
// came from an OAuth provider, the provider's own grant (the consent the
// player gave on Google's or GitHub's consent screen) outlives the GoTrue
// session unless it is revoked explicitly. Without revocation the next
// provider sign-in silently re-approves with the old grant — the consent
// screen never appears again, and the grant lives on in the player's
// provider account.
//
// What a client can honestly do differs per provider:
//   * Google — an open endpoint (`/o/oauth2/revoke`) revokes a grant from
//     its token alone, no secret involved. A browser navigation to the
//     revoke URL is the documented client-side revocation; the shell
//     launches it through the same url_launcher plumbing the authorize
//     link uses (external browser, external session).
//   * GitHub — the grant (authorized OAuth App) can only be removed with
//     the OAuth app's client secret, which lives server-side by design.
//     A client-side "revocation" is impossible; the honest surface is
//     documentation (OAUTH_SERVER_SETUP.md) plus the fact that revoking
//     session tokens server-side (GoTrue's logout, already wired) stops
//     the shell session. [canRevokeProviderGrant] reports false, and the
//     settings UI simply does not promise what it cannot deliver.
//
// The map is the extension point: a provider with a public revoke
// endpoint joins by adding an entry (and a test).

import 'package:url_launcher/url_launcher.dart';

/// Client-side revoke endpoints per provider id (lowercase, as GoTrue's
/// `provider` fragment parameter spells them).
const Map<String, String> _providerRevokeEndpoints = {
  'google': 'https://accounts.google.com/o/oauth2/revoke?token=',
};

/// True when this shell can revoke the provider grant itself (the
/// provider exposes a client-side revocation endpoint). GitHub is false
/// by construction — see the library comment.
bool canRevokeProviderGrant(String? providerName) =>
    providerName != null &&
    _providerRevokeEndpoints.containsKey(providerName.toLowerCase());

/// The revoke URL for [providerName]'s grant token, or null when the
/// provider has no client-side revocation (see [canRevokeProviderGrant]).
Uri? providerGrantRevokeUrl(String providerName, String providerToken) {
  final endpoint = _providerRevokeEndpoints[providerName.toLowerCase()];
  if (endpoint == null) return null;
  return Uri.parse('$endpoint${Uri.encodeQueryComponent(providerToken)}');
}

/// Revokes the provider grant by navigating the external browser to the
/// provider's revoke endpoint — the same launch plumbing that opens the
/// authorize page (external session, the provider's domain, the player
/// sees the provider's own "signed out" confirmation there).
///
/// Returns true when the navigation was handed off (the revocation itself
/// is the provider's answer — Google answers 200 for a live token, 400
/// for an already-dead one, and both mean the grant is gone), false when
/// nothing on the device answered the link (launchers can fail); callers
/// treat false as a quiet skip, never a sign-out failure. Never throws.
Future<bool> revokeProviderGrant({
  required String providerName,
  required String providerToken,
}) async {
  final url = providerGrantRevokeUrl(providerName, providerToken);
  if (url == null) return false;
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // A missing launcher (tests, constrained platforms) is a skip.
    return false;
  }
}
