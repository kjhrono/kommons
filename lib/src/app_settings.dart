import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'auth_service.dart';
import 'oauth_popup_launcher.dart' as oauth_launcher;
import 'oauth_revoke.dart';
import 'recovery_link.dart';
import 'shell_preferences.dart';
import 'shell_strings.dart';

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
  return ServerConnection(
      url: url, apiKey: (key == null || key.isEmpty) ? null : key);
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
    // Sync write-through: a session on any game sharing the auth server
    // inherits this choice (quiet no-op when not signed in / offline).
    unawaited(account.preferenceEdited(
        ShellPrefKey.theme, mode == ThemeMode.light ? 'light' : 'dark'));
  }

  /// Restores the remembered choice at startup (before the first frame
  /// reads the mode).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value =
        prefs.getString(_prefKey) == 'light' ? ThemeMode.light : ThemeMode.dark;
  }

  /// Applies a synced value (from another device, via the account
  /// controller) without firing the sync push loop again.
  @visibleForTesting
  Future<void> applySynced(ThemeMode mode) async {
    value = mode;
    await _persist();
  }

  /// Clears in-memory state for tests (see [AccountController.resetForTest]).
  @visibleForTesting
  void resetForTest() {
    value = ThemeMode.dark;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefKey, value == ThemeMode.light ? 'light' : 'dark');
  }

  static const _prefKey = 'prefs.app.themeMode';
}

/// The app's language, persisted and read by the root widget to build the
/// MaterialApp's `locale`. Same shape as [AppThemeNotifier]: a global
/// [ValueNotifier] so the picker in settings repaints the whole app, and a
/// [load] that restores the remembered choice at startup — run it next to
/// `appTheme.load()` before the first frame.
///
/// Unset stays null: hosts leave `supportedLocales`/`localizationsDelegates`
/// to their own defaults and the app runs in English. The value only becomes
/// non-null when the player (or the host) picks a language.
class AppLocaleNotifier extends ValueNotifier<ShellLanguage?> {
  AppLocaleNotifier() : super(null);

  /// Whether a language was picked (or restored) this session.
  bool get isSet => value != null;

  /// The strings for the current language — English until a choice exists.
  ShellStrings get strings =>
      ShellStrings.forLanguage(value ?? ShellLanguage.english);

  /// The language as a MaterialApp locale (null = no choice made yet).
  Locale? get locale => value?.locale;

  /// Restores the remembered choice at startup (before the first frame
  /// reads the language). An unknown persisted code (a renamed enum, a
  /// downgrade) falls back to unset — English, never a crash.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey);
    value = code == null ? null : _fromCode(code);
  }

  /// Picks a language and persists it.
  Future<void> setLanguage(ShellLanguage language) async {
    value = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, language.code);
    // Sync write-through, as the theme toggle does.
    unawaited(account.preferenceEdited(ShellPrefKey.locale, language.code));
  }

  /// Applies a synced language (from another device, via the account
  /// controller) without firing the sync push loop again.
  @visibleForTesting
  Future<void> applySynced(ShellLanguage language) async {
    value = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, language.code);
  }

  /// Back to the unset state (English). Clears the persisted choice.
  Future<void> clear() async {
    value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }

  ShellLanguage? _fromCode(String code) {
    for (final language in ShellLanguage.values) {
      if (language.code == code) return language;
    }
    return null;
  }

  /// Clears in-memory state for tests (see [AccountController.resetForTest]).
  @visibleForTesting
  void resetForTest() {
    value = null;
  }

  static const _prefKey = 'prefs.app.language';
}

/// The app-wide locale notifier. The root MaterialApp listens to it (along
/// [appTheme]) so a settings pick repaints the shell in the new language.
final appLocale = AppLocaleNotifier();

/// The app-wide theme notifier. The root MaterialApp listens to it.
final appTheme = AppThemeNotifier();

/// The signed-in account, when there is one. Backed by a persisted local
/// record for now — the auth service (Google, GitHub, email+cloud) plugs
/// in behind [signOut] and [signInWithEmail] without the UI changing.
class Account {
  const Account(
      {required this.displayName, required this.email, required this.provider});

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

  /// The collector behind [signInWithProvider]: the shared popup flow on
  /// the web, the deep-link flow (system browser out, app-link redirect
  /// back) on Android and iOS. Injectable for tests and for hosts with a
  /// custom delivery (a dedicated callback page, a replayed redirect).
  Future<String?> Function(String authorizeUrl)? collectOAuthFragment;

  /// True while [signInWithProvider]'s collector is waiting for the
  /// authorize redirect: the flow owns the delivery, so the shell's
  /// session-link watcher must not also restore it. Exposed for the
  /// delivery-time gate in ShellApp.
  @visibleForTesting
  bool get oauthFlowInFlight => _oauthFlowInFlight;
  bool _oauthFlowInFlight = false;

  /// The fragment the OAuth flow last consumed (its redirect completed
  /// the flow) — the shell's watcher dedupes against it so the same link
  /// is never installed twice (flow install + watcher restore).
  String? _fragmentConsumedByFlow;

  /// Test seam: pretends the sign-in flow consumed [fragment] (what a
  /// completed deep-link flow does), so the watcher's dedupe can be
  /// driven without a real browser round-trip.
  @visibleForTesting
  void debugMarkFragmentConsumedByFlow(String fragment) {
    _fragmentConsumedByFlow = fragment;
  }

  /// Where the game server's authorize redirect should land on the mobile
  /// builds — the app's custom scheme or universal-link origin, e.g.
  /// `Uri.parse('mygame://auth')`. The server must allow-list it next to
  /// the web origin, and the app must be able to receive it (Android App
  /// Links / iOS Universal Links, or a custom scheme). The default
  /// collector leaves the redirect to the server's own configuration until
  /// the host sets this; on the web it stays null and [Uri.base.origin]
  /// is used.
  Uri? oauthRedirectUri;

  /// Where the auth service lives. Defaults to the standard prefs keys;
  /// apps with a different configuration source set this after
  /// construction (before any sign-in).
  ServerConnectionResolver serverConnection = readStandardServerConnection;

  AuthSession? _session;
  bool _loaded = false;

  /// The address a password-reset email was sent to, while the player is
  /// entering its code (mirrors [_pendingSignupEmail]'s shape).
  String? _resetEmail;

  /// Whether the current session came from a password recovery and must
  /// choose a new password before anything else (the settings screen
  /// gates the account card on this).
  bool _resetPasswordArmed = false;

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

  /// The address a reset email was sent to (the reset sub-form pre-fills
  /// and confirms it).
  String? get pendingResetEmail => _resetEmail;

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
      // The provider story survives restarts: a restored provider session
      // is a google/github account, not a local email record.
      if (restored.providerName != null) {
        value = Account(
            displayName: playerName,
            email: restored.email,
            provider: restored.providerName!);
      }
      // A temp-password session restored from disk re-opens the shell's
      // forced change-password form — the flag survives restarts until
      // the change lands.
      _resetPasswordArmed = restored.mustChangePassword;
      // Cross-project preferences ride along with the restored session:
      // another device's newest theme/language/name applies here too.
      unawaited(syncPreferencesOnSignIn());
      return;
    }
    final service = await _ensureService();
    if (service == null) {
      await prefs.remove(_sessionKey);
      return;
    }
    try {
      _session = await service
          .refresh(restored.refreshToken)
          // A refreshed session never repeats the fragment's provider
          // grant; carry the persisted one so sign-out can still revoke.
          .then((s) => s.copyWith(
              providerToken: restored.providerToken,
              providerName: restored.providerName));
      if (restored.providerName != null) {
        value = Account(
            displayName: playerName,
            email: _session!.email,
            provider: restored.providerName!);
      }

      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
      unawaited(syncPreferencesOnSignIn());
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
      _session = await service.refresh(current.refreshToken).then((s) =>
          s.copyWith(
              providerToken: current.providerToken,
              providerName: current.providerName));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
      return _session!.accessToken;
    } on AuthException {
      return null;
    }
  }

  // -- Cross-project preference sync -----------------------------------------

  /// Local edit stamps (epoch seconds) for the synced preferences, kept in
  /// a side file so the pull decision works without touching the notifiers
  /// themselves. First edits before any sync run stamp 0 and still win by
  /// the seed rule (cloud lacks the key → push).
  static const _stampsKey = 'prefs.account.prefStamps';

  /// Debounce for the push-after-edit loop; null when nothing is pending.
  Timer? _syncPushTimer;

  /// Reads the local edit stamps (empty file → empty map).
  static Future<Map<String, int>> readLocalPreferenceStamps(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_stampsKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map((k, v) => MapEntry('$k', v is int ? v : 0));
    } catch (_) {
      return const {};
    }
  }

  /// Persists the local edit stamps.
  static Future<void> writeLocalPreferenceStamps(
      SharedPreferences prefs, Map<String, int> stamps) async {
    await prefs.setString(_stampsKey, jsonEncode(stamps));
  }

  /// Cached provenance per synced preference (null until first read; a key
  /// without a record is [ShellPrefOrigin.device] — the shell's default).
  Map<ShellPrefKey, ShellPrefOrigin>? _prefOrigins;

  bool _originsLoadStarted = false;

  /// Where the current value of [key] came from — what the settings
  /// screen's provenance line shows. Device-default keys (never chosen
  /// anywhere) read [ShellPrefOrigin.device].
  ShellPrefOrigin preferenceOrigin(ShellPrefKey key) {
    _ensureOriginsLoaded();
    return _prefOrigins?[key] ?? ShellPrefOrigin.device;
  }

  /// Loads the persisted origins once, lazily (a screen can render before
  /// [load] finishes). A mark that landed first keeps the cache: it is the
  /// fresher story and the same delta is being persisted anyway.
  void _ensureOriginsLoaded() {
    if (_originsLoadStarted) return;
    _originsLoadStarted = true;
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      final fromDisk = shellPrefOriginsFromPrefs(prefs);
      _prefOrigins ??= fromDisk;
    }());
  }

  /// Merges [origins] into the in-memory cache and persists the delta.
  Future<void> _markPreferenceOrigins(
      SharedPreferences prefs, Map<ShellPrefKey, ShellPrefOrigin> origins) {
    _prefOrigins =
        Map<ShellPrefKey, ShellPrefOrigin>.from(_prefOrigins ?? const {})
          ..addAll(origins);
    return writeShellPrefOrigins(prefs, origins);
  }

  /// Sets the anonymous player's name (settings → player name).
  Future<void> setPlayerName(String name) async {
    playerName = name.trim().isEmpty ? 'Player' : name.trim();
    if (value != null && value!.provider == 'email') {
      value = Account(
          displayName: playerName, email: value!.email, provider: 'email');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, playerName);
    // Sync write-through, as the theme and language pickers do.
    unawaited(preferenceEdited(ShellPrefKey.playerName, playerName));
  }

  // -- Cross-project preference sync ----------------------------------------

  /// Runs the cross-project preference sync for a fresh session (call on
  /// every sign-in path and on a restored session): reconcile the cloud
  /// `kommons` metadata blob against the local notifiers, apply the pull
  /// side, then push back so the server ends up holding the union.
  ///
  /// Per-key last-writer-wins via [ShellPrefKey] stamps (see
  /// shell_preferences.dart); keys this device never touched are seeded
  /// from the cloud; values the cloud never saw are seeded up. Offline or
  /// unconfigured servers fail quietly — the local experience is already
  /// correct and the next sign-in retries the merge.
  Future<void> syncPreferencesOnSignIn() async {
    final session = _session;
    if (session == null) return;
    final service = await _ensureService();
    if (service == null) return;
    final prefs = await SharedPreferences.getInstance();

    Map<String, dynamic> cloudPreferences;
    Map<String, dynamic> cloudMetadata;
    try {
      final user = await service.fetchUser(session.accessToken);
      cloudMetadata = user.metadata;
      cloudPreferences = shellPreferencesFromMetadata(cloudMetadata);
    } catch (_) {
      // Unreachable server, revoked token, malformed answer: quiet no-op —
      // the local experience is already correct and the next sign-in
      // retries the merge. The sync must never break the sign-in itself.
      return;
    }

    final localStamps = await readLocalPreferenceStamps(prefs);
    final locale = appLocale.value;
    final reconcile = shellPreferencesReconcile(
      cloudPreferences: cloudPreferences,
      localTheme: appTheme.value == ThemeMode.light ? 'light' : 'dark',
      localLocale: locale?.code,
      // The shell's default name is not a choice: a device that never
      // picked a name has nothing to push, and the cloud value (if any)
      // applies. A chosen name goes through setPlayerName and is stamped.
      localPlayerName:
          playerName == 'Player' && !localStamps.containsKey('playerName')
              ? null
              : playerName,
      localStamps: localStamps,
    );

    // Per-game maps ride the same session fetch: reconcile them against
    // this device's saved maps — the same last-writer-wins rules, one
    // level down (see shell_preferences.dart).
    final localGames = _localGames ?? await readLocalGameSettings(prefs);
    final localGameStamps = _gameStamps ?? await readLocalGameStamps(prefs);
    final gameReconcile = shellGameSettingsReconcile(
      cloudMetadata: cloudMetadata,
      localGames: localGames,
      localStamps: localGameStamps,
    );

    if (reconcile.pull.isNotEmpty) {
      var changed = 0;
      for (final entry in reconcile.pull.entries) {
        if (await _applyPreferenceLocally(entry.key, entry.value)) changed++;
      }
      await _stampLocalEdits(prefs, reconcile.pull,
          cloudStampFor: (key) =>
              shellPreferenceTimestamps(cloudPreferences)[key] ?? 0);
      await _markPreferenceOrigins(prefs, {
        for (final key in reconcile.pull.keys) key: ShellPrefOrigin.cloud,
      });
      if (changed > 0) _notifyPreferencesPulled(changed);
    }

    if (gameReconcile.pull.isNotEmpty) {
      var changed = 0;
      final games =
          Map<String, Map<String, dynamic>>.from(_localGames ?? localGames);
      gameReconcile.pull.forEach((gameId, cloudMap) {
        if (!_jsonEquals(games[gameId], cloudMap)) changed++;
        games[gameId] = cloudMap;
      });
      _localGames = games;
      await writeLocalGameSettings(prefs, games);
      // Stamp with the cloud's own stamps: this device has seen the merge.
      final cloudGameStamps = shellGameSettingsStamps(cloudMetadata);
      final stamps = Map<String, int>.from(localGameStamps);
      for (final gameId in gameReconcile.pull.keys) {
        stamps[gameId] = cloudGameStamps[gameId] ?? 0;
      }
      _gameStamps = stamps;
      await writeLocalGameStamps(prefs, stamps);
      // The same pull signal drives the "preferences loaded" notice: a
      // game's map arriving from the account is the account bringing
      // preferences in, just for the game's own scope.
      if (changed > 0) {
        _notifyPreferencesPulled(changed);
        notifyListeners();
      }
    }

    // Push back so the server carries the union (a fresh account gets this
    // device's defaults; a merge keeps both sides' newest keys). The patch
    // stamps the pushed keys now and carries the cloud stamps forward.
    // Values this device kept (its edit is fresher than the cloud's) keep
    // their local origin — the push does not change their story. Untouched
    // keys are absent from push and stay device-default.
    // Push back so the server carries the union (shell keys and per-game
    // maps composed into one PUT when both sides have something). Values
    // this device kept (its edit is fresher than the cloud's) keep their
    // local origin — the push does not change their story.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var pushMetadata = session.userMetadata;
    if (reconcile.push.isNotEmpty) {
      await _markPreferenceOrigins(prefs,
          {for (final key in reconcile.push.keys) key: ShellPrefOrigin.local});
      // Stamp what we push with the same timestamp the server blob now
      // carries: a delivered edit is this device's story locally too, and
      // the next reconcile sees equal stamps and adds no PUT.
      await _stampLocalEdits(prefs, reconcile.push, cloudStampFor: (_) => now);
      pushMetadata = shellPreferencesToMetadata(
          pushMetadata,
          shellPreferencePatch(
              cloudPreferences,
              {
                for (final entry in reconcile.push.entries)
                  entry.key.key: entry.value,
              },
              now));
    }
    if (gameReconcile.push.isNotEmpty) {
      final stamps = Map<String, int>.from(localGameStamps);
      for (final gameId in gameReconcile.push.keys) {
        stamps[gameId] = now;
      }
      _gameStamps = stamps;
      await writeLocalGameStamps(prefs, stamps);
      pushMetadata = shellGameSettingsToMetadata(
          pushMetadata,
          {
            for (final entry in gameReconcile.push.entries)
              entry.key: entry.value,
          },
          now);
    }
    if (!identical(pushMetadata, session.userMetadata)) {
      try {
        await service.updateUserMetadata(
          accessToken: session.accessToken,
          data: pushMetadata,
        );
        // Refresh the local session's metadata copy so a later push (e.g.
        // a settings edit without a new fetch) sees the union.
        _session = session.copyWith(userMetadata: pushMetadata);
        await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
      } on AuthException {
        // The pull already applied; the push retries on the next sign-in.
      }
    }
  }

  /// Pulled-preference signal: fires with the number of values that
  /// actually changed locally (a pull that only re-confirms known values
  /// stays silent). ShellApp listens and tells the player their account
  /// brought their preferences in; hosts can listen too. UIs acknowledge
  /// an event via [shouldShowSyncNotice] / [markSyncNoticeShown] so each
  /// event shows at most once.
  final ValueNotifier<int> preferencesPulled = ValueNotifier<int>(0);

  /// The pull event the UI last acknowledged (see
  /// [shouldShowSyncNotice]).
  int _syncNoticeAck = 0;

  void _notifyPreferencesPulled(int changed) {
    preferencesPulled.value = preferencesPulled.value + changed;
  }

  /// True when the pull event [event] has not been acknowledged yet —
  /// the UI may show its sync notice for it. Zero (no pull so far) never
  /// shows.
  bool shouldShowSyncNotice(int event) => event > _syncNoticeAck;

  /// Acknowledges the pull event [event]: the sync notice for it will
  /// not show again (test re-pumps, host re-listens).
  void markSyncNoticeShown(int event) {
    if (event > _syncNoticeAck) _syncNoticeAck = event;
  }

  /// Writes one pulled or edited preference into the live notifiers (and
  /// their persisted keys) without triggering the push loop again.
  /// Returns true when the local value actually changed (same-value pulls
  /// are no-ops and stay invisible).
  Future<bool> _applyPreferenceLocally(ShellPrefKey key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    switch (key) {
      case ShellPrefKey.theme:
        final mode = value == 'light' ? ThemeMode.light : ThemeMode.dark;
        if (appTheme.value != mode) {
          await appTheme.applySynced(mode); // no push side effects
          return true;
        }
        return false;
      case ShellPrefKey.locale:
        for (final language in ShellLanguage.values) {
          if (language.code == value) {
            if (appLocale.value != language) {
              await appLocale.applySynced(language);
              return true;
            }
            return false;
          }
        }
        return false;
      case ShellPrefKey.playerName:
        if (playerName != value && value.trim().isNotEmpty) {
          playerName = value.trim();
          if (this.value != null && this.value!.provider == 'email') {
            this.value = Account(
                displayName: playerName,
                email: this.value!.email,
                provider: 'email');
          }
          await prefs.setString(_nameKey, playerName);
          notifyListeners();
          return true;
        }
        return false;
    }
  }

  /// Stamps the local side of an edit (epoch seconds). Pulled values stamp
  /// with the cloud's own timestamp so a later merge does not re-apply.
  Future<void> _stampLocalEdits(
    SharedPreferences prefs,
    Map<ShellPrefKey, String?> changes, {
    int Function(String key)? cloudStampFor,
  }) async {
    final stamps =
        Map<String, int>.from(await readLocalPreferenceStamps(prefs));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    changes.forEach((key, value) {
      stamps[key.key] = cloudStampFor?.call(key.key) ?? now;
    });
    await writeLocalPreferenceStamps(prefs, stamps);
  }

  /// One local preference edit (theme toggle, language pick, name save).
  /// Stamps the edit locally and queues the debounced push; a no-op when
  /// not cloud-signed-in. Never throws. Rapid edits coalesce: the flush
  /// drains every key queued since the last successful write in one PUT.
  Future<void> preferenceEdited(ShellPrefKey key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    // Origin first, guard second: a signed-out edit is still this device's
    // choice — it must outlive sign-in as both provenance (what settings
    // shows) and a stamp (so a cloud value cannot silently clobber an
    // offline choice at the next sign-in).
    await _markPreferenceOrigins(prefs, {key: ShellPrefOrigin.local});
    if (_session == null) return;
    await _stampLocalEdits(prefs, {key: value});
    _pendingPushes[key] = value;
    _syncPushTimer?.cancel();
    _syncPushTimer = Timer(_syncPushDebounce, _flushPendingPushes);
  }

  /// Keys queued by [preferenceEdited] awaiting the debounced flush.
  final Map<ShellPrefKey, String> _pendingPushes = {};

  /// The in-flight sign-in sync, if one is running (test seam reads it;
  /// a new sync replaces it — the latest session wins).
  Future<void>? _signInSync;

  Future<void> _flushPendingPushes() async {
    final session = _session;
    if (session == null ||
        (_pendingPushes.isEmpty && _pendingGamePushes.isEmpty)) {
      return;
    }
    final service = await _ensureService();
    if (service == null) return;
    final pending = Map<ShellPrefKey, String>.from(_pendingPushes);
    _pendingPushes.clear();
    final pendingGames =
        Map<String, Map<String, dynamic>>.from(_pendingGamePushes);
    _pendingGamePushes.clear();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var metadata = session.userMetadata;
    if (pending.isNotEmpty) {
      final current = shellPreferencesFromMetadata(session.userMetadata);
      metadata = shellPreferencesToMetadata(
          metadata,
          shellPreferencePatch(
              current,
              {for (final entry in pending.entries) entry.key.key: entry.value},
              now));
    }
    if (pendingGames.isNotEmpty) {
      final stamps = Map<String, int>.from(_gameStamps ??
          await readLocalGameStamps(await SharedPreferences.getInstance()));
      for (final gameId in pendingGames.keys) {
        stamps[gameId] = now;
      }
      _gameStamps = stamps;
      metadata = shellGameSettingsToMetadata(metadata, pendingGames, now);
    }
    try {
      await service.updateUserMetadata(
        accessToken: session.accessToken,
        data: metadata,
      );
      _session = session.copyWith(userMetadata: metadata);
      if (pendingGames.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await writeLocalGameStamps(prefs, _gameStamps!);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
    } on AuthException {
      // Offline or token trouble: re-queue so a later edit's flush (or the
      // next sign-in's reconcile) carries these edits up. The local stamps
      // already mark this device the winner.
      _pendingPushes.addAll(pending);
    }
  }

  // ------------------------------------------------------------------
  // Per-game settings: local persistence + the host-facing sync API
  // ------------------------------------------------------------------

  /// This device's per-game settings maps, and their edit stamps — cached
  /// after the first read so reads never re-decode the file.
  Map<String, Map<String, dynamic>>? _localGames;
  Map<String, int>? _gameStamps;

  /// Loads a game's settings map from this device's store (empty when the
  /// game has none here). Cheap after the first call.
  Future<Map<String, dynamic>> gameSettings(String gameId) async {
    final games = _localGames;
    if (games != null) {
      return games[gameId] ?? const {};
    }
    final prefs = await SharedPreferences.getInstance();
    final loaded = await readLocalGameSettings(prefs);
    _localGames = loaded;
    return loaded[gameId] ?? const {};
  }

  /// Saves [settings] as [gameId]'s local map, and — when signed in —
  /// queues the debounced push exactly like the shell preferences do.
  /// Never throws; offline edits keep the newer stamp and ride the next
  /// sign-in's reconcile. The reserved stamps key inside [settings] is
  /// stripped (hosts must not set it).
  Future<void> setGameSettings(
      String gameId, Map<String, dynamic> settings) async {
    final clean = Map<String, dynamic>.from(settings)
      ..remove(kShellGamesStampsKey);
    final prefs = await SharedPreferences.getInstance();
    final games =
        Map<String, Map<String, dynamic>>.from(_localGames ?? const {});
    if (_jsonEquals(games[gameId], clean)) return;
    games[gameId] = clean;
    _localGames = games;
    await writeLocalGameSettings(prefs, games);
    final stamps =
        Map<String, int>.from(_gameStamps ?? await readLocalGameStamps(prefs));
    stamps[gameId] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _gameStamps = stamps;
    await writeLocalGameStamps(prefs, stamps);
    if (_session == null) return;
    _pendingGamePushes[gameId] = clean;
    _syncPushTimer?.cancel();
    _syncPushTimer = Timer(_syncPushDebounce, _flushPendingPushes);
  }

  /// Per-game maps queued by [setGameSettings] awaiting the flush.
  final Map<String, Map<String, dynamic>> _pendingGamePushes = {};

  /// Observers for provider-grant revocations attempted at sign-out (a
  /// test seam — production code has no reason to spy on this). Each
  /// callback receives whether the revoke URL was handed off to the
  /// platform launcher.
  final List<void Function(bool handedOff)> _revokeObservers = [];

  /// Registers a revocation observer (see [_revokeObservers]).
  @visibleForTesting
  void debugObserveProviderRevocation(void Function(bool) observer) {
    _revokeObservers.add(observer);
  }

  /// Deep-equality over JSON-shaped values  /// Deep-equality over JSON-shaped values (used to avoid re-writing and
  /// re-pushing maps whose content did not change).
  static bool _jsonEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static const _gamesKey = 'prefs.account.gameSettings';
  static const _gameStampsKey = 'prefs.account.gameSettings.stamps';

  /// Reads the persisted per-game maps. Malformed records read empty —
  /// never a crash; entries that are not maps are dropped.
  static Future<Map<String, Map<String, dynamic>>> readLocalGameSettings(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_gamesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, Map<String, dynamic>>{};
      decoded.forEach((gameId, value) {
        if (value is Map) {
          out['$gameId'] = value.map((key, v) => MapEntry('$key', v));
        }
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Persists the per-game maps.
  static Future<void> writeLocalGameSettings(
      SharedPreferences prefs, Map<String, Map<String, dynamic>> games) async {
    await prefs.setString(_gamesKey, jsonEncode(games));
  }

  /// Reads the persisted per-game stamps.
  static Future<Map<String, int>> readLocalGameStamps(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_gameStampsKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map((k, v) => MapEntry('$k', v is int ? v : 0));
    } catch (_) {
      return const {};
    }
  }

  /// Persists the per-game stamps.
  static Future<void> writeLocalGameStamps(
      SharedPreferences prefs, Map<String, int> stamps) async {
    await prefs.setString(_gameStampsKey, jsonEncode(stamps));
  }

  static const _syncPushDebounce = Duration(seconds: 3);

  /// Test seam: runs the debounced push immediately instead of waiting out
  /// the timer (widget tests use fake clocks; plain tests want no sleeps).
  @visibleForTesting
  Future<void> debugFlushPendingPreferencePushes() async {
    final running = _signInSync;
    await running;
    await _flushPendingPushes();
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
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
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
      if (error.code != 'user_already_registered' &&
          error.code != 'email_exists') {
        rethrow;
      }
      session = await service.signIn(email: clean, password: password);
    }
    _session = session;
    _pendingSignupEmail = null;
    // A session the server flagged with must_change_password (an
    // admin-issued temporary password) opens the shell's change-password
    // form right away — but leaves sign-out available: the player knows
    // this password, they just shouldn't keep it.
    _resetPasswordArmed = session.mustChangePassword;
    value = Account(
        displayName: playerName,
        email: session.email.isNotEmpty ? session.email : clean,
        provider: 'email');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
    notifyListeners();
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
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
      throw const AuthException(
          'no_pending', 'No registration is waiting for confirmation.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    final session =
        await service.verifySignup(email: email, token: code.trim());
    _session = session;
    _pendingSignupEmail = null;
    _resetPasswordArmed = session.mustChangePassword;
    value = Account(
        displayName: playerName,
        email: session.email.isNotEmpty ? session.email : email,
        provider: 'email');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
    notifyListeners();
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
  }

  /// Sends the "forgot password" email: the game server mails the
  /// address a recovery link (or short code, per the server's template).
  /// Validation-level failures (no server, empty email) throw; server
  /// answers surface as [AuthException] messages for the UI. A
  /// non-existent address stays quiet server-side (no enumeration), so
  /// success here only means "the request was accepted" — the player
  /// checks their inbox for the actual proof.
  Future<void> requestPasswordReset(String email) async {
    final clean = email.trim();
    if (clean.isEmpty) {
      throw const AuthException('invalid_email', 'Enter the email to recover.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    await service.resetPassword(email: clean);
  }

  /// Finishes the recovery: verifies the code (or link token) from the
  /// password-reset email and signs the player in. [markPasswordReset]
  /// then arms the shell's forced change-password form, which blocks
  /// sign-out (a recovered session may only be left by choosing a new
  /// password first) until [changePassword] succeeds — the "temp
  /// password → connect → change it" loop, all in-app.
  Future<void> verifyRecoveryCode(String code) async {
    final email = _resetEmail;
    if (email == null) {
      throw const AuthException('no_reset',
          'Request a password reset first (enter your email and tap the reset link below the sign-in form).');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    final session =
        await service.verifyRecovery(email: email, token: code.trim());
    _session = session;
    _pendingSignupEmail = null;
    _resetEmail = null; // the reset is complete: the player is back in
    // Recovery always forces the change; the flag (set alongside an
    // admin-issued temp password) is redundant here but harmless.
    _resetPasswordArmed = true;
    _recoveryNoPassword = true;
    value = Account(
      displayName: playerName,
      email: session.email.isNotEmpty ? session.email : email,
      provider: 'email',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
    notifyListeners();
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
  }

  /// Completes a password reset that arrived as a whole link — the
  /// `{{ .ConfirmationURL }}` template's email opened the app (cold
  /// start, or the player pasted the link into the reset sub-form).
  ///
  /// Token-hash links (`?token_hash=…`) are self-addressing — they sign
  /// back in wherever they are opened. Plain-token links (`#token=…`)
  /// verify against the account's email, which only the device that
  /// requested the reset knows: there the parked reset email (this
  /// device's own "forgot password" request) completes the flow, and a
  /// cold start without one throws `recovery_email_unknown` — the fix is
  /// the 6-digit code, or a server template on the token_hash generation.
  /// Success lands exactly where the code lands: signed in, forced to
  /// choose a new password.
  Future<void> completeRecoveryLink(RecoveryLink link) async {
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    if (!link.isTokenHash && (_resetEmail == null || _resetEmail!.isEmpty)) {
      throw const AuthException(
          'recovery_email_unknown',
          'This recovery link must be opened on the device that requested '
              'the reset (or the server should mail token-hash links).');
    }
    final session = link.isTokenHash
        ? await service.verifyRecoveryTokenHash(link.tokenHash!)
        : await service.verifyRecovery(
            email: _resetEmail ?? '', token: link.token!);
    _session = session;
    _pendingSignupEmail = null;
    _resetEmail = null;
    _resetPasswordArmed = true;
    _recoveryNoPassword = true;
    value = Account(
      displayName: playerName,
      email: session.email.isNotEmpty ? session.email : '',
      provider: 'email',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_emailKey, value!.email);
    await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    await prefs.remove(_pendingKey);
    notifyListeners();
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
  }

  /// True while the current cloud session came from a password recovery —
  /// the settings screen shows the change-password form (and no other
  /// account actions) until the player sets their own password.
  bool get passwordResetPending => _resetPasswordArmed;

  /// True when the current session carries the server's
  /// `must_change_password` flag — the player signed in with an
  /// admin-issued temporary password, and the shell opens the
  /// change-password form for it on entry. Cleared server-side and
  /// locally once [changePassword] lands. [passwordResetPending] covers
  /// the recovery variant of the same form.
  bool get mustChangePassword => _session?.mustChangePassword ?? false;

  /// True when the forced change comes from a *recovery* — a session whose
  /// password the player cannot know — rather than from the server's
  /// `must_change_password` flag on a temporary password they just typed.
  /// The settings screen keeps sign-out available in the flag case (the
  /// player can always sign back in with the temp password) and hides it
  /// in the recovery case (leaving would strand the account).
  bool get recoveryInProgress => _recoveryNoPassword;

  /// Set by [verifyRecoveryCode]; cleared once a new password is chosen.
  bool _recoveryNoPassword = false;

  /// Arms the forced change-password state without touching persistence
  /// (used by [verifyRecoveryCode]; the flag is session-scoped on
  /// purpose — a restart lands on the normal sign-in form).
  @visibleForTesting
  void markPasswordReset() => _resetPasswordArmed = true;

  /// Changes the signed-in cloud account's password, then lifts the
  /// forced-change state — clearing the server's `must_change_password`
  /// flag in the same call so future sessions stop arriving flagged. The
  /// current session stays valid (GoTrue keeps the token pair on a
  /// password change) so no refresh is needed.
  Future<void> changePassword(String newPassword) async {
    final session = _session;
    if (session == null) {
      throw const AuthException(
          'not_signed_in', 'Sign in before changing the password.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    if (session.mustChangePassword) {
      await service.updatePassword(
        accessToken: session.accessToken,
        newPassword: newPassword,
        clearMetadata: const {
          'must_change_password': null, // GoTrue merges: null removes the key
        },
      );
    } else {
      await service.updatePassword(
          accessToken: session.accessToken, newPassword: newPassword);
    }
    // Keep the local copy honest: the flag is gone from this session too.
    if (session.userMetadata.isNotEmpty) {
      final meta = Map<String, dynamic>.from(session.userMetadata)
        ..remove('must_change_password');
      _session = AuthSession(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        expiresAt: session.expiresAt,
        userId: session.userId,
        email: session.email,
        userMetadata: meta,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
    }
    _resetPasswordArmed = false;
    _recoveryNoPassword = false;
    notifyListeners();
  }

  /// Abandons an in-progress password reset (back to the sign-in form).
  Future<void> cancelPasswordReset() async {
    _resetEmail = null;
    notifyListeners();
  }

  /// The reference OAuth sign-in: opens the game server's hosted authorize
  /// page for [provider] ('google', 'github') — a popup back onto the app's
  /// origin on the web, the system browser with an app-link redirect on
  /// Android and iOS — and decodes the implicit fragment the redirect
  /// carries into a real session. The server holds the provider secrets.
  ///
  /// Requires a configured game server (the same one cloud sign-in uses).
  /// The redirect target: [redirectTo] if passed, else
  /// [oauthRedirectUri] (hosts set it per app for the mobile builds), else
  /// the web origin. Hosts embedding the shell elsewhere swap the
  /// [collectOAuthFragment] collector to match their delivery.
  ///
  /// Throws [AuthException] with a user-presentable message on failure;
  /// the player dismissing the provider's consent screen returns quietly
  /// (a cancelled flow, not an error).
  Future<void> signInWithProvider(String provider, {Uri? redirectTo}) async {
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    final collector =
        collectOAuthFragment ?? oauth_launcher.collectOAuthFragment;

    // The default web collector pops a window back onto this app's origin
    // (null off the web); custom collectors — tests, callback pages, deep
    // links — pick their own target and may ignore the redirect entirely.
    final target = redirectTo ?? oauthRedirectUri ?? _webOrigin() ?? Uri();
    final authorize =
        service.authorizeUrl(provider: provider, redirectTo: target);

    // A parked email signup would be overwritten by the provider session —
    // mirror the cancel path: the player chose a different route in.
    await cancelPendingSignup();

    String? fragment;
    _oauthFlowInFlight = true;
    try {
      fragment = await collector(authorize.toString());
      _fragmentConsumedByFlow = fragment;
    } on UnsupportedError catch (error) {
      // A host's custom collector may declare the platform unsupported —
      // surface it as the flow's own typed failure.
      throw AuthException('oauth_unsupported', '$error');
    } finally {
      _oauthFlowInFlight = false;
    }
    if (fragment == null) return; // popup closed: cancelled, not an error
    final session = AuthService.sessionFromImplicitFragment(fragment);
    if (session == null) {
      throw const AuthException(
          'oauth_cancelled', 'Provider sign-in was cancelled.');
    }

    // The fragment carries no email: fetch the account to fill it (and to
    // fail loudly if the provider identity was never confirmed server-side).
    final user = await service.fetchUser(session.accessToken);
    if (!user.confirmed) {
      throw const AuthException('email_not_confirmed',
          'Confirm the email (inbox link) before signing in.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingKey);
    // A provider session on a flagged account opens the change-password
    // form too — the temporary password (and its flag) is identity-agnostic.
    _resetPasswordArmed = user.metadata['must_change_password'] == true;
    // copyWith keeps the fragment's provider fields (the grant and its
    // name) — later metadata writes must not drop them.
    _session = session.copyWith(
        userId: user.id, email: user.email, userMetadata: user.metadata);
    _pendingSignupEmail = null;
    value = Account(
      displayName: playerName,
      email: user.email,
      provider: provider,
    );
    await prefs.setString(_emailKey, user.email);
    await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
    notifyListeners();
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
  }

  /// Installs an OAuth session carried by an app link and runs the
  /// cross-project preference sync on it — a warm return (or cold start)
  /// from an authorize redirect that no collector was waiting for. The
  /// identity is confirmed via `fetchUser` (the fragment carries no
  /// email); failures throw typed errors the caller surfaces.
  ///
  /// Returns false without throwing when the token was already redeemed,
  /// revoked or expired: the fragment itself is proof the server once
  /// issued it, so a dead link is a quiet "nothing to restore", not a
  /// sign-in failure to punish the player with.
  Future<bool> restoreFromSessionFragment(String fragment) async {
    // The sign-in flow owns its own redirect: a delivery racing an armed
    // collector completes the flow, and the fragment it consumed must not
    // be installed a second time by the watcher.
    if (_oauthFlowInFlight || fragment == _fragmentConsumedByFlow) {
      return false;
    }
    final session = AuthService.sessionFromImplicitFragment(fragment);
    if (session == null) {
      throw const AuthException(
          'oauth_invalid', 'The link carries no sign-in session.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    ({
      String id,
      String email,
      bool confirmed,
      Map<String, dynamic> metadata
    }) user;
    try {
      user = await service.fetchUser(session.accessToken);
    } on AuthException {
      // Redeemed/revoked/expired token: the provider link is dead — not
      // an error the player can act on.
      return false;
    }
    if (!user.confirmed) {
      throw const AuthException('email_not_confirmed',
          'Confirm the email (inbox link) before signing in.');
    }

    final prefs = await SharedPreferences.getInstance();
    await cancelPendingSignup();
    _resetPasswordArmed = user.metadata['must_change_password'] == true;
    _session = session.copyWith(
        userId: user.id, email: user.email, userMetadata: user.metadata);
    _pendingSignupEmail = null;
    // The specific provider (the fragment names it) — 'oauth' only when
    // an older fragment predates the field.
    value = Account(
      displayName: playerName,
      email: user.email,
      provider: session.providerName ?? 'oauth',
    );
    await prefs.setString(_emailKey, user.email);
    await prefs.setString(_sessionKey, jsonEncode(_session!.toJson()));
    notifyListeners();
    // The restore IS a sign-in for the preference sync: the pull fires
    // the same "preferences loaded" notice as any other path.
    _signInSync = syncPreferencesOnSignIn();
    unawaited(_signInSync!);
    return true;
  }

  /// This app's origin on the web (the authorize redirect's target there),
  /// or null off the web — the mobile target is [oauthRedirectUri], set by
  /// the host to its app-link origin or scheme.
  Uri? _webOrigin() {
    if (!kIsWeb) return null;
    return Uri.parse(Uri.base.origin);
  }

  /// Sends the reset email and parks the address for the code entry (the
  /// parked state survives a settings-screen rebuild; a full app restart
  /// just asks again).
  Future<void> parkPasswordReset(String email) async {
    _resetEmail = email.trim();
    notifyListeners();
  }

  /// Re-sends the reset email for the parked address.
  Future<void> resendPasswordReset() async {
    final email = _resetEmail;
    if (email == null) {
      throw const AuthException(
          'no_reset', 'No password reset is in progress.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
    }
    await service.resendResetEmail(email: email);
  }

  /// Re-sends the confirmation email for the parked registration.
  Future<void> resendSignupConfirmation() async {
    final email = _pendingSignupEmail;
    if (email == null) {
      throw const AuthException(
          'no_pending', 'No registration is waiting for confirmation.');
    }
    final service = await _ensureService();
    if (service == null) {
      throw const AuthException('no_server',
          'Configure the game server first (host or join an online room once).');
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
    if (_resetPasswordArmed && _recoveryNoPassword) {
      // A recovered session has no known password behind it: leaving it
      // here would strand the player outside their own account. The UI
      // hides the affordance; this guard keeps any future caller honest.
      // (A must_change_password-flagged session is different: the player
      // knows the temporary password and may simply leave.)
      throw const AuthException('reset_in_progress',
          'Choose a new password first (a recovered session has none to fall back on).');
    }
    final session = _session;
    _session = null;
    _pendingSignupEmail = null;
    _syncPushTimer?.cancel();
    _pendingPushes.clear();
    value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailKey);
    await prefs.remove(_sessionKey);
    await prefs.remove(_pendingKey);
    if (session != null) {
      final service = await _ensureService();
      await service?.signOutRemote(session.accessToken);
      // A provider session also revokes the grant itself, best effort —
      // so the next provider sign-in shows the consent screen again
      // instead of silently re-approving. Only providers with a
      // client-side revocation endpoint are touched (Google); for the
      // rest this is a quiet no-op (GitHub's grant needs the server-held
      // secret — see OAUTH_SERVER_SETUP.md).
      final providerToken = session.providerToken;
      final providerName = session.providerName;
      if (providerToken != null && canRevokeProviderGrant(providerName)) {
        unawaited(revokeProviderGrant(
                providerName: providerName!, providerToken: providerToken)
            .then((handedOff) {
          for (final o in _revokeObservers) {
            o(handedOff);
          }
        }));
      }
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
    _resetEmail = null;
    _resetPasswordArmed = false;
    _loaded = false;
    playerName = 'Player';
    authService = null; // tests inject their own per case
    collectOAuthFragment = null;
    _oauthFlowInFlight = false;
    _fragmentConsumedByFlow = null;
    oauthRedirectUri = null;
    _prefOrigins = null;
    _originsLoadStarted = false;
    serverConnection = readStandardServerConnection;
    _syncPushTimer?.cancel();
    _pendingPushes.clear();
    _pendingGamePushes.clear();
    _localGames = null;
    _gameStamps = null;
    preferencesPulled.value = 0;
    _syncNoticeAck = 0;
  }
}

/// The app-wide account controller.
final account = AccountController();
