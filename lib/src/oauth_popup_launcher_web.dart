import 'dart:async';

import 'package:web/web.dart' as web;

import 'oauth_redirect_core.dart';


/// Web implementation of the OAuth popup collector.
///
/// Opens [authorizeUrl] in a popup and polls until the game server's
/// redirect lands back on this app's origin: the fragment
/// (`#access_token=…&refresh_token=…`) becomes readable same-origin, the
/// collector closes the popup itself and returns the fragment. The player
/// closing the popup early returns null (a cancelled flow — the settings
/// screen treats it as a no-op, not an error).
///
/// A popup blocked by the browser throws [StateError] — `window.open` only
/// succeeds inside a user gesture, so a button tap qualifies; a blocked
/// popup means the player must allow popups for this site.
///
/// Cross-origin access to the popup's location throws while it shows the
/// provider's pages — swallowed and retried on the next tick.
Future<String?> collectOAuthFragmentWeb(String authorizeUrl) async {
  final popup = web.window
      .open(authorizeUrl, 'kommons-oauth', 'popup=yes,width=620,height=680');
  if (popup == null) {
    throw StateError(
        'The browser blocked the sign-in popup — allow popups for this site and try again.');
  }
  final completer = Completer<String?>();
  Timer.periodic(const Duration(milliseconds: 300), (timer) {
    if (completer.isCompleted) {
      timer.cancel();
      return;
    }
    if (popup.closed) {
      timer.cancel();
      completer.complete(null);
      return;
    }
    String? fragment;
    try {
      fragment = popup.location.hash;
    } catch (_) {
      return; // still on the provider's origin — keep waiting
    }
    if (fragment.contains('access_token=')) {
      timer.cancel();
      try {
        popup.close();
      } catch (_) {
        // The player may have closed it first; the fragment is in hand.
      }
      completer.complete(fragment);
    }
  });
  return completer.future;
}

/// Web implementation of the PKCE collector: opens [authorizeUrl] in a popup
/// and polls until the redirect lands back on this app's origin, then reads
/// the authorization `code` from the URL (`?code=…`, PKCE) and returns it.
/// The player closing the popup early returns null (a cancelled flow).
///
/// Same contract as [collectOAuthFragmentWeb]: a popup blocked by the browser
/// throws [StateError], and cross-origin reads while the provider's pages are
/// showing are swallowed and retried.
Future<String?> collectOAuthCodeWeb(String authorizeUrl) async {
  final popup = web.window
      .open(authorizeUrl, 'kommons-oauth', 'popup=yes,width=620,height=680');
  if (popup == null) {
    throw StateError(
        'The browser blocked the sign-in popup — allow popups for this site and try again.');
  }
  final completer = Completer<String?>();
  Timer.periodic(const Duration(milliseconds: 300), (timer) {
    if (completer.isCompleted) {
      timer.cancel();
      return;
    }
    if (popup.closed) {
      timer.cancel();
      completer.complete(null);
      return;
    }
    String? href;
    try {
      href = popup.location.href;
    } catch (_) {
      return; // still on the provider's origin — keep waiting
    }
    if (href.isEmpty) return;
    final code = oauthCodeFromUri(Uri.parse(href));
    if (code != null) {
      timer.cancel();
      try {
        popup.close();
      } catch (_) {
        // The player may have closed it first; the code is in hand.
      }
      completer.complete(code);
    }
  });
  return completer.future;
}
