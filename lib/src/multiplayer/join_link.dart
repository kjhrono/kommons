import 'package:flutter/services.dart' show Clipboard, ClipboardData;

/// A parsed invite destination: everything a lobby (or the app's link
/// handler) needs to put the invited player at the host's table.
///
/// Two shapes arrive over a link:
///  * `…#join=K7QX2` — the fragment form [link] produces: survives any
///    static host (a game's web build, a file, a QR code).
///  * `…?join=K7QX2` — the query form a server-side shortener hands out.
///
/// Unknown hosts or codes parse to null — callers treat that as "no
/// invite here", never as an error: plenty of links open an app without
/// anything to do with joining a table.
class JoinInvite {
  const JoinInvite({required this.code, this.host});

  /// The shared room's short code (e.g. `K7QX2`).
  final String code;

  /// The game server the host plays on, when the link names one. A null
  /// [host] means "the code speaks for itself" — games whose transport
  /// needs a server ask the player (or their own defaults) for it.
  final Uri? host;

  /// The invite a host shares: `https://<host><path>#join=<code>` when a
  /// [base] is given (the app's own URL on web, the game's landing page
  /// otherwise), `#join=<code>` alone without one.
  String link({Uri? base}) {
    if (base == null) return '#join=$code';
    return base.replace(fragment: 'join=$code').toString();
  }
}

/// The fragment/query keys an invite can arrive under. Exported so hosts
/// with their own deep-link plumbing reuse the exact names.
const joinLinkCodeKey = 'join';
const joinLinkHostKey = 'server';

/// Reads a [JoinInvite] out of a deep-link URI, or null when the link
/// carries none. Both spellings work — `#join=K7QX2&server=…` (fragment)
/// and `?join=K7QX2` (query). `#` is optional in the fragment text: web's
/// `location.hash` carries it, mobile app-link delivery often strips it.
JoinInvite? joinInviteFromUri(Uri uri) {
  String code = '';
  Uri? host;

  final fragment = uri.fragment.trim();
  if (fragment.isNotEmpty) {
    final params = Uri.splitQueryString(fragment);
    code = params[joinLinkCodeKey]?.trim() ?? '';
    final hostText = params[joinLinkHostKey]?.trim();
    if (hostText != null && hostText.isNotEmpty) host = Uri.tryParse(hostText);
  }
  if (code.isEmpty) {
    code = uri.queryParameters[joinLinkCodeKey]?.trim() ?? '';
    final hostText = uri.queryParameters[joinLinkHostKey]?.trim();
    if (host == null && hostText != null && hostText.isNotEmpty) {
      host = Uri.tryParse(hostText);
    }
  }
  if (code.isEmpty) return null;
  return JoinInvite(code: code, host: host);
}

/// Reads the invite a clipboard text carries, or null when there is none.
/// Forgiving about stray whitespace — the text came from a human gesture
/// (paste), not a machine handoff.
JoinInvite? joinInviteFromClipboardText(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (!uri.hasScheme && !trimmed.contains('#')) return null;
  return joinInviteFromUri(uri);
}

/// Reads the system clipboard (the "paste a link you were sent" seam).
/// On platforms without a clipboard — or in tests without a mock — this
/// completes null, which the lobby renders as "nothing to paste".
Future<String?> readJoinLinkClipboard() async {
  try {
    final data = await Clipboard.getData('text/plain');
    return data?.text;
  } catch (_) {
    return null;
  }
}

/// Copies [text] to the system clipboard, completing when done. Quietly
/// no-ops where no clipboard exists — the caller's own feedback (a
/// snackbar) still tells the player what happened.
Future<void> copyJoinLink(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    // No clipboard here; nothing the caller could do differently.
  }
}
