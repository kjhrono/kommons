// The recovery-link parser: a `{{ .ConfirmationURL }}` password-reset
// email opens the app as a link (browser on web, app link on mobile)
// carrying the recovery token. Parsing it here — next to the join-link
// parser — lets the shell offer "sign back in from the email" as a
// first-class path, alongside the 6-digit code.
//
// GoTrue's confirmation mail links come in two generations:
//  * `…#token=<otp>&type=recovery`  — the token in the fragment
//  * `…?token_hash=<hashed>&type=recovery` — the newer hashed token in
//    the query (verify consumes it server-side, so the email value is
//    itself the secret; no client-side hashing).
// Both must say `type=recovery` — that guard is what keeps these links
// from cross-talking with the join links (`join=`), the OAuth implicit
// fragments (`access_token=`) and a PKCE `code=` parameter, none of
// which verify through the recovery endpoint.

/// A recovery token read out of a password-reset email link.
///
/// Exactly one of [token] / [tokenHash] is set: [token] verifies through
/// the email+token flow (the same endpoint the 6-digit code uses),
/// [tokenHash] through the token_hash flow — the caller must know which
/// one it holds, the values are not interchangeable.
class RecoveryLink {
  const RecoveryLink.token(String this.token) : tokenHash = null;

  const RecoveryLink.tokenHash(String this.tokenHash) : token = null;

  /// The plain OTP token (`#token=…`), verified with the account's email.
  final String? token;

  /// The hashed token (`?token_hash=…`), verified without the email.
  final String? tokenHash;

  /// Which flow this link verifies through.
  bool get isTokenHash => tokenHash != null;
}

/// The link keys a recovery token can arrive under. Exported so hosts
/// with their own deep-link plumbing reuse the exact names.
const recoveryLinkTypeKey = 'type';
const recoveryLinkTokenKey = 'token';
const recoveryLinkTokenHashKey = 'token_hash';

/// The `type` value marking a password-recovery link.
const recoveryLinkTypeValue = 'recovery';

/// Reads a [RecoveryLink] out of a deep-link URI, or null when the link
/// carries no recovery token. Both spellings work — `#token=…&type=recovery`
/// (fragment) and `?token_hash=…&type=recovery` (query). The `type=recovery`
/// guard is mandatory: a token-shaped parameter on a link of any other kind
/// is not ours to consume. `#` is optional in the fragment text: web's
/// `location.hash` carries it, mobile app-link delivery often strips it.
RecoveryLink? recoveryLinkFromUri(Uri uri) {
  final fragment = uri.fragment.trim();
  final query = uri.queryParameters;

  // Fragment form first (matches the join-link parser's precedence).
  if (fragment.isNotEmpty) {
    final params = Uri.splitQueryString(fragment);
    final link = _fromParams(
      type: params[recoveryLinkTypeKey]?.trim(),
      token: params[recoveryLinkTokenKey]?.trim(),
      tokenHash: params[recoveryLinkTokenHashKey]?.trim(),
    );
    if (link != null) return link;
  }
  return _fromParams(
    type: query[recoveryLinkTypeKey]?.trim(),
    token: query[recoveryLinkTokenKey]?.trim(),
    tokenHash: query[recoveryLinkTokenHashKey]?.trim(),
  );
}

RecoveryLink? _fromParams({String? type, String? token, String? tokenHash}) {
  if (type != recoveryLinkTypeValue) return null;
  final plain = (token == null || token.isEmpty) ? null : token;
  final hashed = (tokenHash == null || tokenHash.isEmpty) ? null : tokenHash;
  if (plain != null && hashed != null) {
    // Both spellings at once is a malformed link, not a richer one.
    return null;
  }
  if (plain != null) return RecoveryLink.token(plain);
  if (hashed != null) return RecoveryLink.tokenHash(hashed);
  return null;
}

/// Reads the recovery link a clipboard text carries, or null when there
/// is none. Forgiving about stray whitespace — the text came from a
/// human gesture (paste), not a machine handoff.
RecoveryLink? recoveryLinkFromClipboardText(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (!uri.hasScheme && !trimmed.contains('#') && !trimmed.contains('?')) {
    return null;
  }
  return recoveryLinkFromUri(uri);
}
