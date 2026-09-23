// The confirmation-link parser: a `{{ .ConfirmationURL }}` signup email
// opens the app as a link (browser on web, app link on mobile) carrying
// the signup token. Parsing it here — beside the recovery-link parser —
// lets the shell confirm the address straight from the emailed link, the
// same first-class path the password-reset mail already has.
//
// GoTrue's confirmation mail links come in the same two generations as
// the recovery ones:
//  * `…#token=<otp>&type=signup`       — the token in the fragment
//  * `…?token_hash=<hashed>&type=signup` — the newer hashed token in the
//    query (verify consumes it server-side, so the email value is itself
//    the secret; no client-side hashing).
// Both must say `type=signup` — that guard is what keeps these links from
// cross-talking with the join links (`join=`), the recovery links
// (`type=recovery`), the OAuth implicit fragments (`access_token=`) and a
// PKCE `code=` parameter, none of which verify through the signup
// endpoint.

/// A confirmation token read out of a signup email link.
///
/// Exactly one of [token] / [tokenHash] is set: [token] verifies through
/// the email+token flow (the same endpoint the 6-digit code uses),
/// [tokenHash] through the token_hash flow — the caller must know which
/// one it holds, the values are not interchangeable.
class ConfirmationLink {
  const ConfirmationLink.token(String this.token) : tokenHash = null;

  const ConfirmationLink.tokenHash(String this.tokenHash) : token = null;

  /// The plain OTP token (`#token=…`), verified with the account's email.
  final String? token;

  /// The hashed token (`?token_hash=…`), verified without the email.
  final String? tokenHash;

  /// Which flow this link verifies through.
  bool get isTokenHash => tokenHash != null;
}

/// The link keys a confirmation token can arrive under. Exported so hosts
/// with their own deep-link plumbing reuse the exact names.
const confirmationLinkTypeKey = 'type';
const confirmationLinkTokenKey = 'token';
const confirmationLinkTokenHashKey = 'token_hash';

/// The `type` value marking a signup-confirmation link.
const confirmationLinkTypeValue = 'signup';

/// Reads a [ConfirmationLink] out of a deep-link URI, or null when the
/// link carries no confirmation token. Both spellings work —
/// `#token=…&type=signup` (fragment) and `?token_hash=…&type=signup`
/// (query). The `type=signup` guard is mandatory: a token-shaped
/// parameter on a link of any other kind is not ours to consume. `#` is
/// optional in the fragment text: web's `location.hash` carries it,
/// mobile app-link delivery often strips it.
ConfirmationLink? confirmationLinkFromUri(Uri uri) {
  final fragment = uri.fragment.trim();
  final query = uri.queryParameters;

  // Fragment form first (matches the recovery parser's precedence).
  if (fragment.isNotEmpty) {
    final params = Uri.splitQueryString(fragment);
    final link = _fromParams(
      type: params[confirmationLinkTypeKey]?.trim(),
      token: params[confirmationLinkTokenKey]?.trim(),
      tokenHash: params[confirmationLinkTokenHashKey]?.trim(),
    );
    if (link != null) return link;
  }
  return _fromParams(
    type: query[confirmationLinkTypeKey]?.trim(),
    token: query[confirmationLinkTokenKey]?.trim(),
    tokenHash: query[confirmationLinkTokenHashKey]?.trim(),
  );
}

ConfirmationLink? _fromParams(
    {String? type, String? token, String? tokenHash}) {
  if (type != confirmationLinkTypeValue) return null;
  final plain = (token == null || token.isEmpty) ? null : token;
  final hashed = (tokenHash == null || tokenHash.isEmpty) ? null : tokenHash;
  if (plain != null && hashed != null) {
    // Both spellings at once is a malformed link, not a richer one.
    return null;
  }
  if (plain != null) return ConfirmationLink.token(plain);
  if (hashed != null) return ConfirmationLink.tokenHash(hashed);
  return null;
}

/// Reads the confirmation link a clipboard text carries, or null when
/// there is none. Forgiving about stray whitespace — the text came from
/// a human gesture (paste), not a machine handoff.
ConfirmationLink? confirmationLinkFromClipboardText(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (!uri.hasScheme && !trimmed.contains('#') && !trimmed.contains('?')) {
    return null;
  }
  return confirmationLinkFromUri(uri);
}
