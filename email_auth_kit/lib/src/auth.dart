import 'dart:convert';

import 'errors.dart';
import 'http.dart';

/// The slice of a Supabase session the flows need.
class AuthSession {
  final String userId;
  final String email;
  final String accessToken;
  final String refreshToken;
  const AuthSession({
    required this.userId,
    required this.email,
    required this.accessToken,
    required this.refreshToken,
  });

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        userId: j['user']?['id'] as String? ?? '',
        email: j['user']?['email'] as String? ?? '',
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
      );
}

/// Minimal Supabase Auth REST calls used by the flows: password sign-in
/// (temp password path), token refresh, password update. Kept tiny on
/// purpose — projects that already use supabase_flutter can keep their
/// own client and only use the edge-function methods of this package.
class SupabaseAuth {
  static Uri _auth(String baseUrl, String path) =>
      Uri.parse('$baseUrl/auth/v1$path');

  static Map<String, String> _headers(String anonKey) => {
        'content-type': 'application/json',
        'apikey': anonKey,
      };

  /// Signs in with email + password (used with the e-mailed temp
  /// password, and by [MediasartAuth.signIn]).
  ///
  /// Refusals are typed: a NATIVE ban (identity refuses the account)
  /// throws [AuthBannedException], anything else
  /// `AuthCodeException('invalid_credentials')`. A 200 whose fresh
  /// token carries a LIVE `kit_banned_until` claim (the kit's data-plane
  /// kill-switch) also throws [AuthBannedException] — with
  /// [AuthBannedException.bannedUntil] set from the claim.
  static Future<AuthSession> signInWithPassword({
    required String baseUrl,
    required String anonKey,
    required String email,
    required String password,
  }) async {
    final res = await Poster.send(
      'POST',
      _auth(baseUrl, '/token?grant_type=password'),
      headers: _headers(anonKey),
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw _refusalOf(res.body);
    }
    final session = AuthSession.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    final liveBan = _liveBanIn(session.accessToken);
    if (liveBan != null) {
      throw AuthBannedException(bannedUntil: liveBan);
    }
    return session;
  }

  /// Rotates the session tokens (Supabase revokes the old refresh token
  /// after a password change, so the app must persist the new ones).
  /// A native ban surfaces as [AuthBannedException]; stale-token
  /// refusals stay `AuthCodeException('invalid_credentials')`.
  static Future<AuthSession> refresh({
    required String baseUrl,
    required String anonKey,
    required String refreshToken,
  }) async {
    final res = await Poster.send(
      'POST',
      _auth(baseUrl, '/token?grant_type=refresh_token'),
      headers: _headers(anonKey),
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    if (res.statusCode != 200) {
      throw _refusalOf(res.body);
    }
    final session = AuthSession.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    final liveBan = _liveBanIn(session.accessToken);
    if (liveBan != null) {
      throw AuthBannedException(bannedUntil: liveBan);
    }
    return session;
  }

  /// Updates the password for the session's user, then refreshes so the
  /// caller can persist fresh tokens. Throws `weak_password` when the
  /// server rejects the new password.
  static Future<AuthSession> updatePassword({
    required String baseUrl,
    required String anonKey,
    required String accessToken,
    required String refreshToken,
    required String newPassword,
  }) async {
    final res = await Poster.send(
      'PUT',
      _auth(baseUrl, '/user'),
      headers: {
        ..._headers(anonKey),
        'authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'password': newPassword}),
    );
    if (res.statusCode == 422) {
      throw const AuthCodeException('weak_password');
    }
    if (res.statusCode == 401) {
      throw const AuthCodeException('unauthorized');
    }
    if (res.statusCode != 200) {
      throw AuthCodeException('server', detail: 'user_update_${res.statusCode}');
    }
    // Password change revokes other sessions' refresh tokens; refresh
    // this session so the caller persists valid ones.
    return refresh(baseUrl: baseUrl, anonKey: anonKey, refreshToken: refreshToken);
  }

  // ------------------------------------------------------- ban plumbing

  /// Decodes a JWT's payload claims without verifying the signature —
  /// safe here because the claims are only read AFTER the stack verified
  /// the token (it minted it), and never to grant anything ourselves.
  static Map<String, dynamic> _claimsOf(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return const {};
      final normalized = base64Url.normalize(parts[1]);
      return jsonDecode(utf8.decode(base64Url.decode(normalized)))
          as Map<String, dynamic>;
    } on Object {
      // Malformed token — RangeError (no payload segment) and
      // TypeError (payload is not a JSON object) included.
      return const {};
    }
  }

  /// The raw `kit_banned_until` claim when it is LIVE (in the future);
  /// null when absent, expired, or unparseable — matching the data
  /// plane's semantics (a stale claim never denies).
  static String? _liveBanIn(String jwt) {
    final until = _claimsOf(jwt)['kit_banned_until'];
    if (until is! String || until.isEmpty) return null;
    final when = DateTime.tryParse(until);
    if (when == null) return null;
    return when.isAfter(DateTime.now()) ? until : null;
  }

  /// Maps a GoTrue refusal body to the typed exception: native bans →
  /// [AuthBannedException], everything else →
  /// `AuthCodeException('invalid_credentials')` (the sign-in/refresh
  /// surface's one prior refusal shape, preserved for compatibility).
  static Exception _refusalOf(String body) {
    String? code;
    String? msg;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        code = decoded['error_code'] as String?;
        msg = (decoded['msg'] ?? decoded['message'] ?? decoded['error']) as String?;
      }
    } on FormatException {
      // non-JSON refusal body — fall through to invalid_credentials
    }
    final lower = (msg ?? '').toLowerCase();
    if (code == 'user_banned' || lower.contains('banned')) {
      return AuthBannedException(detail: msg);
    }
    return AuthCodeException('invalid_credentials', detail: code ?? msg);
  }
}
