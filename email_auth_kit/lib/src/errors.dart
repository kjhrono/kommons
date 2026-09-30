/// Typed errors for the mediasart auth flows.
///
/// [reason] is a stable string your UI can switch on:
///
///   * `network`            — request failed before an answer
///   * `rate_limited`       — too many requests for this email
///   * `invalid`            — wrong code/token (see [attemptsLeft])
///   * `locked`             — too many wrong attempts; request a new one
///   * `expired`            — the code/token timed out
///   * `no_pending`         — nothing outstanding for this email
///   * `unauthorized`       — bad/missing JWT where one was required
///   * `invalid_credentials`— sign-in with temp password rejected
///   * `weak_password`      — new password rejected by the password rules
///   * `banned`             — surfaced as [AuthBannedException]
///   * `server`             — anything else (see [detail])
library;

class AuthCodeException implements Exception {
  /// Stable, switchable reason string (see the library docs).
  final String reason;

  /// Attempts remaining before the challenge locks (when known).
  final int? attemptsLeft;

  /// Raw error string from the server, for logs and debugging.
  final String? detail;

  const AuthCodeException(this.reason, {this.attemptsLeft, this.detail});

  @override
  String toString() =>
      'AuthCodeException($reason${detail == null ? '' : ': $detail'})';
}

/// The account is banned on the identity stack.
///
/// Thrown from sign-in/refresh when the identity refuses the account
/// (auth plane), and from [MediasartAuth.signIn] when a freshly minted
/// token still carries a LIVE `kit_banned_until` claim (data plane —
/// the kill-switch embeds it in every token minted or refreshed while a
/// ban is active). A subclass of [AuthCodeException] with reason
/// `banned`, so existing `catch (e) if (e is AuthCodeException)` blocks
/// keep working; catch this type FIRST for the ban-specific UX.
///
/// [bannedUntil] is the raw ISO timestamp from the claim when known —
/// show it when your UX wants to, but treat it as advisory: an admin
/// may lift the ban earlier.
class AuthBannedException extends AuthCodeException {
  /// ISO timestamp of the ban's end, from the kit_banned_until claim
  /// (null when detected via the auth plane's refusal instead).
  final String? bannedUntil;

  const AuthBannedException({this.bannedUntil, super.detail})
      : super('banned');

  @override
  String toString() => 'AuthBannedException(banned'
      '${bannedUntil == null ? '' : ' until $bannedUntil'}'
      '${detail == null ? '' : ': $detail'})';
}
