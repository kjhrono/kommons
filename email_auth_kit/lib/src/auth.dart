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
  /// password). Throws [AuthCodeException] `invalid_credentials` on a
  /// rejected login.
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
      throw const AuthCodeException('invalid_credentials');
    }
    return AuthSession.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Rotates the session tokens (Supabase revokes the old refresh token
  /// after a password change, so the app must persist the new ones).
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
      throw const AuthCodeException('invalid_credentials');
    }
    return AuthSession.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
}
