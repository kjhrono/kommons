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
    this.userMetadata = const {},
    this.providerToken,
    this.providerName,
  });

  final String accessToken;
  final String refreshToken;

  /// Epoch seconds after which the access token stops working.
  final int expiresAt;
  final String userId;
  final String email;

  /// The user's private metadata blob, echoed by GoTrue in every session
  /// answer. The shell reads the `must_change_password` flag (set by the
  /// server operator alongside an admin-issued temporary password) so the
  /// settings screen can force the change-password form on.
  final Map<String, dynamic> userMetadata;

  /// The provider's own grant token (`provider_token` from an OAuth
  /// redirect fragment — the Google/GitHub grant itself, distinct from
  /// GoTrue's session pair). Present only on provider sessions;
  /// [AccountController.signOut] uses it to revoke the grant where the
  /// provider allows a client-side revocation (Google).
  final String? providerToken;

  /// Which provider issued [providerToken] ('google', 'github', …).
  final String? providerName;

  /// True when the server flagged this session as signed in with a
  /// temporary password that must be changed before it's usable.
  bool get mustChangePassword => userMetadata['must_change_password'] == true;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  /// A copy of this session with the given fields replaced — how the
  /// controller refreshes metadata in place without losing the provider
  /// grant (or the tokens) it was signed in with.
  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    int? expiresAt,
    String? userId,
    String? email,
    Map<String, dynamic>? userMetadata,
    String? providerToken,
    String? providerName,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      userMetadata: userMetadata ?? this.userMetadata,
      providerToken: providerToken ?? this.providerToken,
      providerName: providerName ?? this.providerName,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt,
        'user_id': userId,
        'email': email,
        'user_metadata': userMetadata,
        if (providerToken != null) 'provider_token': providerToken,
        if (providerName != null) 'provider_name': providerName,
      };

  static AuthSession? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      return null;
    }
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: json['expires_at'] is int ? json['expires_at'] as int : 0,
      userId: json['user_id'] is String ? json['user_id'] as String : '',
      email: json['email'] is String ? json['email'] as String : '',
      userMetadata: json['user_metadata'] is Map<String, dynamic>
          ? json['user_metadata'] as Map<String, dynamic>
          : const {},
      providerToken: json['provider_token'] is String
          ? json['provider_token'] as String
          : null,
      providerName: json['provider_name'] is String
          ? json['provider_name'] as String
          : null,
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
///   POST `<server>/auth/v1/recover`                     → password-reset email
///   POST `<server>/auth/v1/verify` (type=recovery)      → recovery code → session
///   PUT  `<server>/auth/v1/user`                        → set a new password
///
/// OAuth providers (Google, GitHub, …) run as GoTrue's hosted web flow:
/// the app opens `<server>/auth/v1/authorize?provider={provider}`, the server
/// holds the provider secrets, and the redirect comes back as an implicit
/// fragment that [sessionFromImplicitFragment] decodes — the app never sees a
/// client secret.
///
/// That is GoTrue's own route, and Kong serves it as an OPEN route (no apikey,
/// no key-auth plugin), which is exactly what makes a plain browser redirect
/// work. Every self-hosted Supabase stack answers it out of the box, so no
/// per-site rewrite is needed — and the redirect target must be listed in the
/// stack's `GOTRUE_URI_ALLOW_LIST`, or GoTrue refuses it with
/// "redirect URI not allowed" instead of redirecting.
///
/// The server-side counterpart lives in the Supabase stack's env: with no
/// real SMTP configured, `GOTRUE_MAILER_AUTOCONFIRM=true` is what makes
/// signups return a session immediately instead of trying (and failing) to
/// mail a confirmation link.
class AuthService {
  AuthService({required String serverUrl, String? apiKey, http.Client? client})
      : _apiKey = apiKey,
        _client = client ?? http.Client() {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    _base = Uri.parse('$normalized/auth/v1');
  }

  final String? _apiKey;
  final http.Client _client;
  late final Uri _base;

  /// The server root: the configured URL without the `/auth/v1` suffix.
  Uri get serverRoot {
    var path = _base.path;
    if (path.endsWith('/auth/v1')) {
      path = path.substring(0, path.length - '/auth/v1'.length);
    }
    return _base.replace(path: path);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_apiKey != null && _apiKey!.isNotEmpty) 'apikey': _apiKey!,
      };

  /// Registers the account and returns its first session. GoTrue answers
  /// `user_already_registered` for known addresses — callers (the account
  /// controller) turn that into a sign-in attempt with the same password,
  /// so "sign up or in" feels like one action.
  Future<AuthSession> signUp(
      {required String email, required String password}) async {
    return _sessionCall(
      _base.replace(path: '${_base.path}/signup'),
      jsonEncode({'email': email, 'password': password}),
    );
  }

  /// Signs an existing account in with its password.
  Future<AuthSession> signIn(
      {required String email, required String password}) async {
    return _sessionCall(
      _base.replace(
          path: '${_base.path}/token',
          queryParameters: {'grant_type': 'password'}),
      jsonEncode({'email': email, 'password': password}),
    );
  }

  /// The hosted authorize page for [provider] ('google', 'github'), the URL
  /// the popup collector opens.
  ///
  /// GoTrue's own route — `<server>/auth/v1/authorize?provider=…&redirect_to=…`
  /// — which the stack's gateway already serves, so this works against any
  /// self-hosted Supabase without a server-side rewrite. [redirectTo] is where
  /// the provider sends the player back: the app's own origin on the web, its
  /// deep-link scheme on mobile. GoTrue only honours targets listed in its
  /// `GOTRUE_URI_ALLOW_LIST`.
  ///
  /// (The parameter is `redirect_to`, not Netlify Identity's `redirectTo`:
  /// this is GoTrue's API shape, and a wrong name is silently ignored — the
  /// provider then bounces the player to the server's default site URL.)
  Uri authorizeUrl({required String provider, required Uri redirectTo}) {
    return _base.replace(
      path: '${_base.path}/authorize',
      queryParameters: {
        'provider': provider,
        'redirect_to': redirectTo.toString(),
      },
    );
  }

  /// Decodes the implicit fragment the authorize redirect appended
  /// (`#access_token=…&refresh_token=…`), mirroring [AuthSession.fromJson].
  /// Null when the fragment is absent or carries an error instead
  /// (`error=access_denied` when the player declines the provider's consent
  /// screen) — callers treat null as a cancelled flow.
  static AuthSession? sessionFromImplicitFragment(String fragment) {
    final raw = fragment.startsWith('#') ? fragment.substring(1) : fragment;
    if (raw.isEmpty) return null;
    final params =
        Uri(query: raw).queryParameters; // fragment is x-www-urlencoded
    final access = params['access_token'];
    final refresh = params['refresh_token'];
    if (access == null ||
        access.isEmpty ||
        refresh == null ||
        refresh.isEmpty) {
      return null;
    }
    final expiresAt =
        params['expires_at'] is String && params['expires_at']!.isNotEmpty
            ? int.tryParse(params['expires_at']!) ?? 0
            : (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
                (int.tryParse(params['expires_in'] ?? '') ?? 3600);
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      userId: params['provider_id'] ?? '',
      email: '',
      // The provider grant rides along: sign-out revokes it (Google) so
      // the next provider sign-in asks for consent again.
      providerToken: params['provider_token'],
      providerName: params['provider'],
    );
  }

  /// Fetches the account (id, email, confirmed?, metadata) for an OAuth
  /// session's access token — OAuth fragments carry no email, so the
  /// controller fills it after collecting the fragment.
  Future<
      ({
        String id,
        String email,
        bool confirmed,
        Map<String, dynamic> metadata
      })> fetchUser(String accessToken) async {
    final http.Response response;
    try {
      response = await _client
          .get(_base.replace(path: '${_base.path}/user'), headers: {
        ..._headers,
        'Authorization': 'Bearer $accessToken',
      });
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }
    Map<String, dynamic>? json;
    if (response.body.isNotEmpty) {
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        json = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code =
          json?['error_code'] as String? ?? 'http_${response.statusCode}';
      final message = json?['msg'] as String? ??
          json?['message'] as String? ??
          response.body;
      throw AuthException(code,
          message.isEmpty ? 'Auth failed (${response.statusCode})' : message);
    }
    if (json == null) {
      throw AuthException(
          'http_${response.statusCode}', 'Unexpected empty auth response');
    }
    return (
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      confirmed: json['email_confirmed_at'] != null,
      metadata: json['user_metadata'] is Map<String, dynamic>
          ? json['user_metadata'] as Map<String, dynamic>
          : const <String, dynamic>{},
    );
  }

  /// Exchanges a refresh token for a fresh session pair (the access token
  /// is short-lived by design; the refresh token survives it).
  Future<AuthSession> refresh(String refreshToken) async {
    return _sessionCall(
      _base.replace(
          path: '${_base.path}/token',
          queryParameters: {'grant_type': 'refresh_token'}),
      jsonEncode({'refresh_token': refreshToken}),
    );
  }

  /// Confirms a signup with the code (or the token embedded in the link)
  /// from the confirmation email, returning the first session. GoTrue's
  /// verify endpoint answers for both flavors: an email template that
  /// embeds `{{ .Token }}` shows a short numeric code, and one that embeds
  /// `{{ .ConfirmationURL }}` carries the same token in its query string.
  Future<AuthSession> verifySignup(
      {required String email, required String token}) async {
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
      final code =
          json?['error_code'] as String? ?? 'http_${response.statusCode}';
      final message = json?['msg'] as String? ??
          json?['message'] as String? ??
          response.body;
      throw AuthException(
          code,
          message.isEmpty
              ? 'Could not resend (HTTP ${response.statusCode})'
              : message);
    }
  }

  /// Sends the password-reset ("forgot password") email. GoTrue mails the
  /// server's recovery template — either a `{{ .ConfirmationURL }}` link or
  /// a `{{ .Token }}` short code, per the template config. The happy answer
  /// is 200 with an empty body (and, to prevent address enumeration, 200 is
  /// returned for unknown addresses too — the player simply receives
  /// nothing and retries with the right address).
  Future<void> resetPassword({required String email}) async {
    final http.Response response;
    try {
      response = await _client.post(
        _base.replace(path: '${_base.path}/recover'),
        headers: _headers,
        body: jsonEncode({'email': email}),
      );
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response, 'Could not send the reset email');
    }
  }

  /// Re-sends the password-reset email. A thin alias over [resetPassword]
  /// so callers read symmetrically with the signup resend.
  Future<void> resendResetEmail({required String email}) =>
      resetPassword(email: email);

  /// Verifies the recovery code (or the token embedded in the reset link)
  /// from the password-reset email, returning a fresh session — the player
  /// is now signed in and should choose a new password
  /// ([updatePassword]). A `{{ .Token }}` template mails a short numeric
  /// code; a `{{ .ConfirmationURL }}` link's fragment token works here
  /// too (see [verifyRecoveryTokenHash] for the query-string generation).
  Future<AuthSession> verifyRecovery(
      {required String email, required String token}) {
    return _sessionCall(
      _base.replace(path: '${_base.path}/verify'),
      jsonEncode({'type': 'recovery', 'email': email, 'token': token}),
    );
  }

  /// Verifies the *hashed* recovery token a `{{ .ConfirmationURL }}` link
  /// carries in its query string (`?token_hash=…&type=recovery`) — the
  /// newer GoTrue/Supabase generation, where the server mails a link
  /// whose value is already the secret. No email accompanies it: the
  /// hash itself addresses the account. A failure (expired, already
  /// used, wrong generation) surfaces as a typed [AuthException].
  Future<AuthSession> verifyRecoveryTokenHash(String tokenHash) {
    return _sessionCall(
      _base.replace(path: '${_base.path}/verify'),
      jsonEncode({'type': 'recovery', 'token_hash': tokenHash}),
    );
  }

  /// Sets a new password for the signed-in account ([accessToken] comes
  /// from the session — a normal password sign-in or a [verifyRecovery]
  /// session alike). Pass [clearMetadata] keys to remove from the user's
  /// metadata in the same call — the controller clears the
  /// `must_change_password` flag here so the server stops re-flagging
  /// future sessions. Servers configured with password reauthentication
  /// will reject this with a typed [AuthException] the UI surfaces.
  Future<void> updatePassword(
      {required String accessToken,
      required String newPassword,
      Map<String, dynamic>? clearMetadata}) async {
    final http.Response response;
    try {
      response = await _client.put(
        _base.replace(path: '${_base.path}/user'),
        headers: {
          ..._headers,
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({
          'password': newPassword,
          if (clearMetadata != null && clearMetadata.isNotEmpty)
            'data': clearMetadata,
        }),
      );
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response, 'Could not change the password');
    }
  }

  /// Merges [data] into the user's metadata (PUT /auth/v1/user with the
  /// `data` field — GoTrue merges top-level keys, so the shell's
  /// preferences blob under `kommons` never touches other keys). This is
  /// the write side of the cross-project preference sync: a theme or
  /// language change on one game reaches every other game that shares
  /// the auth server. Pass null values inside [data] to remove keys
  /// (GoTrue's merge contract, same as [updatePassword]'s
  /// [clearMetadata]).
  Future<void> updateUserMetadata(
      {required String accessToken, required Map<String, dynamic> data}) async {
    final http.Response response;
    try {
      response = await _client.put(
        _base.replace(path: '${_base.path}/user'),
        headers: {
          ..._headers,
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'data': data}),
      );
    } catch (error) {
      throw AuthException('network', 'Could not reach the auth server: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response, 'Could not update the account metadata');
    }
  }

  /// Parses a non-2xx auth response into a typed [AuthException], reading
  /// GoTrue's `error_code` / `msg` JSON shape when present.
  AuthException _errorFrom(http.Response response, String fallback) {
    Map<String, dynamic>? json;
    if (response.body.isNotEmpty) {
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        json = null; // non-JSON error page
      }
    }
    final code =
        json?['error_code'] as String? ?? 'http_${response.statusCode}';
    final message =
        json?['msg'] as String? ?? json?['message'] as String? ?? response.body;
    return AuthException(
        code, message.isEmpty ? '$fallback (${response.statusCode})' : message);
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
      final code =
          json?['error_code'] as String? ?? 'http_${response.statusCode}';
      final message = json?['msg'] as String? ??
          json?['message'] as String? ??
          response.body;
      throw AuthException(code,
          message.isEmpty ? 'Auth failed (${response.statusCode})' : message);
    }
    if (json == null) {
      throw AuthException(
          'http_${response.statusCode}', 'Unexpected empty auth response');
    }

    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      // GoTrue answers 200 without a session when signup needs e-mail
      // confirmation (autoconfirm off): the account exists, the session
      // does not. Surface that distinctly so the UI can explain it.
      final user = json['user'] as Map<String, dynamic>?;
      final confirmed = user?['email_confirmed_at'] != null;
      throw AuthException(
        confirmed ? 'session_missing' : 'email_not_confirmed',
        confirmed
            ? 'The server accepted the account but issued no session'
            : 'Confirm the email (inbox link) before signing in',
      );
    }

    final user = json['user'] as Map<String, dynamic>?;
    final meta = user?['user_metadata'];
    final expiresAt = json['expires_at'] is int
        ? json['expires_at'] as int
        : (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
            ((json['expires_in'] as num?)?.toInt() ?? 3600);
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      userId: user?['id'] as String? ?? '',
      email: (user?['email'] as String?) ?? (json['email'] as String? ?? ''),
      userMetadata:
          meta is Map<String, dynamic> ? meta : const <String, dynamic>{},
    );
  }
}
