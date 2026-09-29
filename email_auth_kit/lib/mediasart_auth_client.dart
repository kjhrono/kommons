/// mediasart_auth_client — generic Supabase + Brevo email-auth flows.
///
/// Three flows, one client:
///
///   * email confirmation code at registration — [requestCode] / [verifyCode]
///   * change password at will — [changePassword]
///   * forgot password via link → temp password — [requestReset] / [completeReset]
///
/// Pure Dart (no Flutter, no dart:io), so every mediasart project —
/// web, desktop, mobile — wires it in as-is. Typed errors
/// ([AuthCodeException.reason]) keep UI branching clean.
library;

import 'dart:convert';

import 'src/auth.dart';
import 'src/errors.dart';
import 'src/http.dart';

export 'src/auth.dart' show AuthSession;
export 'src/errors.dart';

class MediasartAuth {
  /// Supabase project URL, e.g. https://katalogus.mediasart.com
  final String supabaseUrl;

  /// Supabase anon (publishable) key — safe to embed in the app.
  final String anonKey;

  MediasartAuth({required this.supabaseUrl, required this.anonKey});

  static const _emailVerificationPath = '/functions/v1/email-verification';
  static const _passwordResetPath = '/functions/v1/password-reset';

  // ------------------------------------------------------------------
  // Flow 1 — email confirmation code (registration proof)
  // ------------------------------------------------------------------

  /// Sends a 6-digit confirmation code to [email]. The answer is
  /// identical whether or not the address has an account (no user
  /// enumeration).
  Future<void> requestCode(String email) async {
    await _post(_emailVerificationPath, {'action': 'request', 'email': email});
  }

  /// Kit-native signup: creates the auth user UNCONFIRMED via the edge
  /// function and sends the 6-digit code — no GoTrue signup mail, no
  /// session. The device is NOT signed in; [verifyCode] completes the
  /// activation and the app then offers a normal sign-in. Throws
  /// `weak_password` when the password is under the server's minimum.
  Future<void> signUpWithConfirmation({
    required String email,
    required String password,
  }) async {
    await _post(_emailVerificationPath, {
      'action': 'signup',
      'email': email,
      'password': password,
    });
  }

  /// Verifies the [code] previously sent to [email]. Throws
  /// [AuthCodeException] with reason `invalid` ([attemptsLeft] set),
  /// `locked`, `expired`, `no_pending`, or `rate_limited`.
  Future<void> verifyCode(String email, String code) =>
      _post(_emailVerificationPath, {'action': 'verify', 'email': email, 'code': code});

  // ------------------------------------------------------------------
  // Flow 2 — change password at will
  // ------------------------------------------------------------------

  /// Changes the password of the signed-in user to [newPassword].
  ///
  /// No e-mail involved. Supabase rotates the refresh token after a
  /// password change, so [onSessionUpdated] hands the app the fresh
  /// tokens to persist.
  Future<void> changePassword({
    required AuthSession session,
    required String newPassword,
    void Function(AuthSession newSession)? onSessionUpdated,
  }) async {
    final updated = await SupabaseAuth.updatePassword(
      baseUrl: supabaseUrl,
      anonKey: anonKey,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      newPassword: newPassword,
    );
    onSessionUpdated?.call(updated);
  }

  // ------------------------------------------------------------------
  // Flow 3 — forgot password (link → temp password)
  // ------------------------------------------------------------------

  /// Asks for a reset e-mail whose link opens YOUR reset page
  /// ([redirectTo], https) as `?email=...&token=...`; that page calls
  /// [completeReset].
  Future<void> requestReset({
    required String email,
    required String redirectTo,
  }) async {
    await _post(_passwordResetPath, {
      'action': 'request',
      'email': email,
      'redirect_to': redirectTo,
    });
  }

  /// Completes a reset started by the user clicking the e-mailed link:
  /// the server sets a **temp password** and e-mails it; other sessions
  /// are revoked.
  ///
  /// The temp password is never returned to the app — it goes only to
  /// the inbox. In production the user then signs in with it through
  /// the normal login screen ([mustChangePassword] on the result tells
  /// the UI to force a change right after). [fetchTempPassword] is an
  /// optional testing/support seam: when supplied, the client polls it
  /// for the temp password and signs in directly, returning the session.
  Future<ResetResult> completeReset({
    required String email,
    required String token,
    Future<String?> Function()? fetchTempPassword,
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 60),
  }) async {
    await _post(_passwordResetPath, {'action': 'confirm', 'email': email, 'token': token});

    if (fetchTempPassword == null) {
      return const ResetResult(
        tempPasswordKnownToApp: false,
        mustChangePassword: true,
      );
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final temp = await fetchTempPassword();
      if (temp != null && temp.isNotEmpty) {
        final session = await SupabaseAuth.signInWithPassword(
          baseUrl: supabaseUrl,
          anonKey: anonKey,
          email: email,
          password: temp,
        );
        return ResetResult(
          tempPasswordKnownToApp: true,
          mustChangePassword: true,
          session: session,
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    throw const AuthCodeException('temp_password_timeout');
  }

  /// Optional: "your password was changed" notice. Requires the user's
  /// session — the function verifies the JWT itself.
  Future<void> notifyPasswordChanged({required AuthSession session}) async {
    await _post(
      _passwordResetPath,
      {'action': 'notify', 'user_id': session.userId},
      bearer: session.accessToken,
    );
  }

  // ------------------------------------------------------------------
  // Plumbing
  // ------------------------------------------------------------------

  Future<void> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) async {
    final headers = {
      'content-type': 'application/json',
      'apikey': anonKey,
      if (bearer != null) 'authorization': 'Bearer $bearer',
    };

    final PostResponse res;
    try {
      res = await Poster.send(
        'POST',
        Uri.parse('$supabaseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      );
    } on AuthCodeException {
      rethrow;
    } on Exception {
      throw const AuthCodeException('network');
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return;
    }

    final reason = _errorOf(res.body);
    if (reason.startsWith('rate_limited')) throw const AuthCodeException('rate_limited');
    switch (reason) {
      case 'code_invalid':
      case 'token_invalid':
        throw AuthCodeException('invalid', attemptsLeft: _attemptsOf(res.body));
      case 'code_locked':
      case 'token_locked':
        throw const AuthCodeException('locked');
      case 'code_expired':
      case 'token_expired':
        throw const AuthCodeException('expired');
      case 'no_pending_code':
      case 'no_pending_reset':
        throw const AuthCodeException('no_pending');
      case 'weak_password':
        throw const AuthCodeException('weak_password');
      case 'signup_failed':
        throw const AuthCodeException('server', detail: 'signup_failed');
      case 'missing_bearer':
      case 'invalid_token':
      case 'user_mismatch':
        throw const AuthCodeException('unauthorized');
      default:
        throw AuthCodeException('server', detail: reason);
    }
  }

  static String _errorOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // fall through
    }
    return 'http_error';
  }  static int? _attemptsOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['attempts_left'] is int) {
        return decoded['attempts_left'] as int;
      }
    } on FormatException {
      // fall through
    }
    return null;
  }
}

/// Result of [MediasartAuth.completeReset].
class ResetResult {
  /// Whether the app itself knows the temp password (assisted flow).
  final bool tempPasswordKnownToApp;

  /// The UI must force a password change before anything else.
  final bool mustChangePassword;

  /// Session, only present in the assisted flow (temp password fetched
  /// and used to sign in directly).
  final AuthSession? session;

  const ResetResult({
    required this.tempPasswordKnownToApp,
    required this.mustChangePassword,
    this.session,
  });
}
