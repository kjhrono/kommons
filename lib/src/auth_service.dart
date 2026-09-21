import 'dart:convert';

import 'package:http/http.dart' as http;

/// A GoTrue session as the app carries it: the bearer pair the auth service
/// issued plus the identity it belongs to. Serialized to SharedPreferences
/// by [AccountController] (app_settings.dart), refreshed by [AuthService].
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;

  /// Epoch seconds after which the access token stops working.
  final int expiresAt;
  final String userId;
  final String email;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt,
        'user_id': userId,
        'email': email,
      };

  static AuthSession? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) {
      return null;
    }
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: json['expires_at'] is int ? json['expires_at'] as int : 0,
      userId: json['user_id'] is String ? json['user_id'] as String : '',
      email: json['email'] is String ? json['email'] as String : '',
    );
  }
}

/// A typed failure from the auth service. [code] carries GoTrue's
/// `error_code` when the server sent one ('user_already_registered',
/// 'invalid_login_credentials', 'email_not_confirmed', …) so callers can
/// branch without parsing messages.
class AuthException implements Exception {
  const AuthException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Supabase auth (GoTrue) over plain REST — the same no-SDK approach as the
/// game's PostgREST sync: only the server URL the player already configured
/// for online rooms, plus the anon key that fronts the gateway. Endpoints:
///
///   POST `<server>/auth/v1/signup`                      → register + first session
///   POST `<server>/auth/v1/token?grant_type=password`   → sign in
///   POST `<server>/auth/v1/token?grant_type=refresh_token`
///   POST `<server>/auth/v1/logout`
///
/// The server-side counterpart lives in the Supabase stack's env: with no
/// real SMTP configured, `GOTRUE_MAILER_AUTOCONFIRM=true` is what makes
/// signups return a session immediately instead of trying (and failing) to
/// mail a confirmation link.
class AuthService {
  AuthService({required String serverUrl, String? apiKey, http.Client? client})
      : _apiKey = apiKey,
        _client = client ?? http.Client() {
    final normalized = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
    _base = Uri.parse('$normalized/auth/v1');
  }

  final String? _apiKey;
  final http.Client _client;
  late final Uri _base;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_apiKey != null && _apiKey!.isNotEmpty) 'apikey': _apiKey!,
      };

  /// Registers the account and returns its first session. GoTrue answers
  /// `user_already_registered` for known addresses — callers (the account
  /// controller) turn that into a sign-in attempt with the same password,
  /// so "sign up or in" feels like one action.
  Future<AuthSession> signUp({required String email, required String password}) async {
    return _sessionCall(
      _base.replace(path: '${_base.path}/signup'),
      jsonEncode({'email': email, 'password': password}),
    );
  }

  /// Signs an existing account in with its password.
  Future<AuthSession> signIn({required String email, required String password}) async {
    return _sessionCall(
      _base.replace(path: '${_base.path}/token', queryParameters: {'grant_type': 'password'}),
      jsonEncode({'email': email, 'password': password}),
    );
  }

  /// Exchanges a refresh token for a fresh session pair (the access token
  /// is short-lived by design; the refresh token survives it).
  Future<AuthSession> refresh(String refreshToken) async {
    return _sessionCall(
      _base.replace(path: '${_base.path}/token', queryParameters: {'grant_type': 'refresh_token'}),
      jsonEncode({'refresh_token': refreshToken}),
    );
  }

  /// Confirms a signup with the code (or the token embedded in the link)
  /// from the confirmation email, returning the first session. GoTrue's
  /// verify endpoint answers for both flavors: an email template that
  /// embeds `{{ .Token }}` shows a short numeric code, and one that embeds
  /// `{{ .ConfirmationURL }}` carries the same token in its query string.
  Future<AuthSession> verifySignup({required String email, required String token}) async {
    return _sessionCall(
      _base.replace(path: '${_base.path}/verify'),
      jsonEncode({'type': 'signup', 'email': email, 'token': token}),
    );
  }

  /// Re-sends the signup confirmation email. A no-op server-side when the
  /// address is already confirmed (GoTrue answers 200 without mailing).
  Future<void> resendConfirmation({required String email}) async {
    final http.Response response;
    try {
      response = await _client.post(
        _base.replace(path: '${_base.path}/resend'),
        headers: _headers,
        body: jsonEncode({'type': 'signup', 'email': email}),
      );
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Map<String, dynamic>? json;
      if (response.body.isNotEmpty) {
        try {
          json = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          json = null;
        }
      }
      final code = json?['error_code'] as String? ?? 'http_${response.statusCode}';
      final message = json?['msg'] as String? ?? json?['message'] as String? ?? response.body;
      throw AuthException(code, message.isEmpty ? 'Could not resend (HTTP ${response.statusCode})' : message);
    }
  }

  /// Best-effort server-side revocation; sessions also simply expire, so
  /// callers may ignore failures of this call entirely.
  Future<void> signOutRemote(String accessToken) async {
    try {
      await _client.post(
        _base.replace(path: '${_base.path}/logout'),
        headers: {..._headers, 'Authorization': 'Bearer $accessToken'},
      );
    } catch (_) {
      // Logout is advisory: the token expires on its own regardless.
    }
  }

  Future<AuthSession> _sessionCall(Uri url, String body) async {
    final http.Response response;
    try {
      response = await _client.post(url, headers: _headers, body: body);
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }

    Map<String, dynamic>? json;
    if (response.body.isNotEmpty) {
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        json = null; // non-JSON error page — fall through to the status path
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = json?['error_code'] as String? ?? 'http_${response.statusCode}';
      final message = json?['msg'] as String? ?? json?['message'] as String? ?? response.body;
      throw AuthException(code, message.isEmpty ? 'Auth failed (${response.statusCode})' : message);
    }
    if (json == null) {
      throw AuthException('http_${response.statusCode}', 'Unexpected empty auth response');
    }

    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) {
      // GoTrue answers 200 without a session when signup needs e-mail
      // confirmation (autoconfirm off): the account exists, the session
      // does not. Surface that distinctly so the UI can explain it.
      final user = json['user'] as Map<String, dynamic>?;
      final confirmed = user?['email_confirmed_at'] != null;
      throw AuthException(
        confirmed ? 'session_missing' : 'email_not_confirmed',
        confirmed ? 'The server accepted the account but issued no session' : 'Confirm the email (inbox link) before signing in',
      );
    }

    final user = json['user'] as Map<String, dynamic>?;
    final expiresAt = json['expires_at'] is int
        ? json['expires_at'] as int
        : (DateTime.now().millisecondsSinceEpoch ~/ 1000) + ((json['expires_in'] as num?)?.toInt() ?? 3600);
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      userId: user?['id'] as String? ?? '',
      email: (user?['email'] as String?) ?? (json['email'] as String? ?? ''),
    );
  }
}
