import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

/// A game-server (auth-backend) connection an app hands to the account
/// controller: where the GoTrue-compatible auth service lives and which
/// anon key fronts it.
class ServerConnection {
  const ServerConnection({required this.url, this.apiKey});

  final String url;
  final String? apiKey;
}

/// Resolves the connection used for cloud sign-in. Apps with the standard
/// storage convention get the default resolver for free; others inject
/// their own (a config file, a remote default, …).
typedef ServerConnectionResolver = Future<ServerConnection?> Function();

/// The default resolver: reads the well-known prefs keys the shell's
/// connect-server dialogs write ('prefs.online.serverUrl' /
/// 'prefs.online.anonKey').
Future<ServerConnection?> readStandardServerConnection() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('prefs.online.serverUrl') ?? '';
  if (url.isEmpty) return null;
  final key = prefs.getString('prefs.online.anonKey');
  return ServerConnection(url: url, apiKey: (key == null || key.isEmpty) ? null : key);
}

/// The app's theme mode, persisted and read by the root widget. A global
/// [ValueNotifier] so a toggle in the top bar repaints the whole app
/// without any inherited-widget plumbing, and so any future game hosted in
/// this shell shares the same switch.
class AppThemeNotifier extends ValueNotifier<ThemeMode> {
  AppThemeNotifier() : super(ThemeMode.dark);

  /// Whether the current mode renders the light palette.
  bool get isLight => value == ThemeMode.light;

  /// Convenience read of the current mode.
  ThemeMode get mode => value;

  set mode(ThemeMode mode) {
    value = mode;
    _persist();
  }

  /// Restores the remembered choice at startup (before the first frame
  /// reads the mode).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = prefs.getString(_prefKey) == 'light' ? ThemeMode.light : ThemeMode.dark;
  }

  /// Clears in-memory state for tests (see [AccountController.resetForTest]).
  @visibleForTesting
  void resetForTest() {
    value = ThemeMode.dark;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, value == ThemeMode.light ? 'light' : 'dark');
  }

  static const _prefKey = 'prefs.app.themeMode';
}

/// The app-wide theme notifier. The root MaterialApp listens to it.
final appTheme = AppThemeNotifier();

/// The signed-in account, when there is one. Backed by a persisted local
/// record for now — the auth service (Google, GitHub, email+cloud) plugs
/// in behind [signOut] and [signInWithEmail] without the UI changing.
class Account {
  const Account({required this.displayName, required this.email, required this.provider});

  /// Human-facing name ('Marcuz', or the provider's display name).
  final String displayName;

  /// The account's email, shown in settings.
  final String email;

  /// 'guest' while anonymous; 'email', 'google', 'github', … once signed in.
  final String provider;
}

/// The account controller: persisted name for the anonymous case, and the
/// seam where the real auth service lands.
///
/// Two flavors of "signed in" exist:
///  * device-local — an email remembered on this device only (no password):
///    [Account.provider] stays 'email' and nothing leaves the phone.
///  * cloud — email + password verified by the game server's auth service
///    ([AuthService], GoTrue REST): a [AuthSession] is held and persisted,
///    refreshed before expiry, and revoked server-side on sign-out.
///    [isCloudSignedIn] tells the two apart; [validAccessToken] hands the
///    bearer token to future cloud features (save sync, profiles).
class AccountController extends ValueNotifier<Account?> {
  AccountController() : super(null);

  static const _nameKey = 'prefs.account.playerName';
  static const _emailKey = 'prefs.account.email';
  static const _sessionKey = 'prefs.account.session';
  static const _pendingKey = 'prefs.account.pendingSignup';

  /// Injectable for tests: a service built over a MockClient. Production
  /// code leaves this null and the controller builds one from the
  /// [serverConnection] resolver (the same URL/key the lobby uses).
  AuthService? authService;

  /// Where the auth service lives. Defaults to the standard prefs keys;
  /// apps with a different configuration source set this after
  /// construction (before any sign-in).
  ServerConnectionResolver serverConnection = readStandardServerConnection;

  AuthSession? _session;
  bool _loaded = false;

  /// A signup awaiting email confirmation: the address is registered on
  /// the game server but GoTrue issued no session until the confirmation
  /// email's code (or link) is verified. Persisted so a reload (or app
  /// restart) returns the player to the same check-your-inbox state.
  String? _pendingSignupEmail;

  /// The address with a confirmation pending, when one is.
  String? get pendingSignupEmail => _pendingSignupEmail;

  /// True once [load] has run (cloud-room lists wait for the player name
  /// it restores, so callers can await this instead of guessing).
  bool get isLoaded => _loaded;

  /// The live cloud session, when signed in with a password.
  AuthSession? get session => _session;

  /// True when the account is verified by the game server (not just
  /// remembered locally).
  bool get isCloudSignedIn => _session != null;

  /// The player's chosen name — anonymous players get this from settings,
  /// signed-in players from their account.
  String playerName = 'Player';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    playerName = prefs.getString(_nameKey) ?? 'Player';
    final email = prefs.getString(_emailKey);
    if (email != null && email.isNotEmpty) {
      value = Account(displayName: playerName, email: email, provider: 'email');
    }
    _pendingSignupEmail = prefs.getString(_pendingKey);
    await _restoreSession(prefs);
    _loaded = true;
  }

  /// Restores the persisted cloud session, refreshing an expired access
  /// token once. A session that cannot be revived (server moved, token
  /// revoked) degrades gracefully to the device-local record — the player
  /// keeps their name and email, they just sign in again for cloud writes.
  Future<void> _restoreSession(SharedPreferences prefs) async {
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return;
    final restored = AuthSession.fromJson(jsonDecode(raw));
    if (restored == null) {
      await prefs.remove(_sessionKey);
      return;
    }
    if (!restored.isExpired) {
      _session = restored;
      return;
    }
    final service = await _ensureService();
    if (service == null) {
      await prefs.remove(_sessionKey);
      return;
    }
    try {
      _session = await service.refresh(restored.refreshToken);
      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
    } on AuthException {
      _session = null;
      await prefs.remove(_sessionKey);
    }
  }

  /// Builds the auth service from the app's connection resolver. Returns
  /// null when no server was configured yet (cloud sign-in then explains
  /// itself).
  Future<AuthService?> _ensureService() async {
    if (authService != null) return authService;
    final connection = await serverConnection();
    if (connection == null || connection.url.isEmpty) return null;
    return AuthService(serverUrl: connection.url, apiKey: connection.apiKey);
  }

  /// A bearer token for cloud calls, silently refreshed when the cached one
  /// has expired. Null when not cloud-signed-in or the server is unreachable.
  Future<String?> validAccessToken() async {
    final current = _session;
    if (current == null) return null;
    if (!current.isExpired) return current.accessToken;
    final service = await _ensureService();
    if (service == null) return null;
    try {
      _session = await service.refresh(current.refreshToken);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
      return _session!.accessToken;
    } on AuthException {
      return null;
    }
  }

  /// Sets the anonymous player's name (settings → player name).
  Future<void> setPlayerName(String name) async {
    playerName = name.trim().isEmpty ? 'Player' : name.trim();
    if (value != null && value!.provider == 'email') {
      value = Account(displayName: playerName, email: value!.email, provider: 'email');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, playerName);
  }

  /// Signs in with email only: the account is recorded on this device
  /// (no password involved, nothing leaves the phone) — enough for the
  /// welcome message and for games to address the player.
  Future<void> signInWithEmail(String email) async {
    final clean = email.trim();
    value = Account(displayName: playerName, email: clean, provider: 'email');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, clean);
  }

  /// Signs in — or on first use, registers — a cloud account with the game
  /// server: GoTrue verifies the password, the account persists server-side,
  /// and the returned session is kept (and refreshed) on this device.
  /// Throws [AuthException] with a user-presentable message on failure
  /// (wrong password, server unreachable, …).
  Future<void> signInWithPassword(String email, String password) async {
    final clean = email.trim();
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server', 'Configure the game server first (host or join an online room once).');
    }
    AuthSession session;
    try {
      session = await service.signUp(email: clean, password: password);
    } on AuthException catch (error) {
      if (error.code == 'email_not_confirmed') {
        // The server registered the address but withheld the session until
        // the confirmation email is verified (autoconfirm off). Park the
        // signup so any caller — settings today, other screens later —
        // lands in the check-your-inbox state, then rethrow.
        await parkPendingSignup(clean);
        rethrow;
      }
      // Known address: fall through to a password sign-in, so "sign up or
      // in" is one action for the player.
      if (error.code != 'user_already_registered' && error.code != 'email_exists') rethrow;
      session = await service.signIn(email: clean, password: password);
    }
    _session = session;
    _pendingSignupEmail = null;
    value = Account(displayName: playerName, email: session.email.isNotEmpty ? session.email : clean, provider: 'email');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
  }

  /// Called by the settings screen when the server answers that the
  /// address still needs confirmation: the signup is parked until the
  /// email's code (or link) is verified.
  Future<void> parkPendingSignup(String email) async {
    _pendingSignupEmail = email.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKey, _pendingSignupEmail!);
    notifyListeners();
  }

  /// Confirms the parked signup with the code from the email (the link's
  /// token works too — same endpoint). On success the account is signed
  /// in exactly as a password sign-in would have; a wrong code rethrows
  /// and the parked state survives for another try.
  Future<void> confirmSignupCode(String code) async {
    final email = _pendingSignupEmail;
    if (email == null) {
      throw const AuthException('no_pending', 'No registration is waiting for confirmation.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server', 'Configure the game server first (host or join an online room once).');
    }
    final session = await service.verifySignup(email: email, token: code.trim());
    _session = session;
    _pendingSignupEmail = null;
    value = Account(displayName: playerName, email: session.email.isNotEmpty ? session.email : email, provider: 'email');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
    notifyListeners();
  }

  /// Re-sends the confirmation email for the parked registration.
  Future<void> resendSignupConfirmation() async {
    final email = _pendingSignupEmail;
    if (email == null) {
      throw const AuthException('no_pending', 'No registration is waiting for confirmation.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server', 'Configure the game server first (host or join an online room once).');
    }
    await service.resendConfirmation(email: email);
  }

  /// Abandons the parked registration (player wants a different address,
  /// or prefers to stay anonymous). The server record, if any, simply
  /// never gets confirmed.
  Future<void> cancelPendingSignup() async {
    _pendingSignupEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingKey);
    notifyListeners();
  }

  /// Signs out, keeping the local player name. A cloud session is also
  /// revoked server-side (best effort — it expires on its own anyway).
  Future<void> signOut() async {
    final session = _session;
    _session = null;
    _pendingSignupEmail = null;
    value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailKey);
    await prefs.remove(_sessionKey);
    await prefs.remove(_pendingKey);
    if (session != null) {
      final service = await _ensureService();
      await service?.signOutRemote(session.accessToken);
    }
  }

  /// Clears all in-memory state. Tests use this between cases: the
  /// controllers are process-wide singletons and would otherwise leak a
  /// signed-in account (or a light theme) into the next test.
  @visibleForTesting
  void resetForTest() {
    value = null;
    _session = null;
    _pendingSignupEmail = null;
    _loaded = false;
    playerName = 'Player';
    authService = null; // tests inject their own per case
    serverConnection = readStandardServerConnection;
  }
}

/// The app-wide account controller.
final account = AccountController();
