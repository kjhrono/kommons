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
