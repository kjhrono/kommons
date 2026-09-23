import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The cross-project preference sync: the codec's merge rules, the
/// controller's pull-seed-on-sign-in, and the debounced push of local
/// edits — the loop that carries theme, language and player name between
/// every game sharing the auth server.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
  });

  group('codec: metadata round-trip', () {
    test('reads the namespaced blob and ignores everything else', () {
      final metadata = {
        'must_change_password': true,
        'provider_token': 'x',
        'kommons': {
          'theme': 'dark',
          'locale': 'it',
          'playerName': 'Marcuz',
          'updatedAt': {'theme': 100, 'locale': 200},
        },
      };

      final prefs = shellPreferencesFromMetadata(metadata);

      expect(prefs['theme'], 'dark');
      expect(prefs['locale'], 'it');
      expect(prefs['playerName'], 'Marcuz');
      expect(shellPreferenceTimestamps(prefs)['theme'], 100);
      expect(shellPreferenceTimestamps(prefs)['locale'], 200);
    });

    test('malformed blobs read as empty, never throw', () {
      expect(shellPreferencesFromMetadata({}), isEmpty);
      expect(shellPreferencesFromMetadata({'kommons': 'oops'}), isEmpty);
      expect(shellPreferencesFromMetadata({'kommons': 42}), isEmpty);
    });

    test('writing merges under the namespace, preserving other keys', () {
      final metadata = {'must_change_password': true};
      final written = shellPreferencesToMetadata(metadata, {'theme': 'dark'});
      expect(written['kommons'], {'theme': 'dark'});
      expect(written['must_change_password'], true);
      // The input was not mutated.
      expect(metadata.containsKey('kommons'), isFalse);
    });

    test('patch stamps changed keys and carries untouched stamps forward', () {
      final current = {
        'theme': 'dark',
        'locale': 'en',
        'updatedAt': {'theme': 100, 'locale': 50},
      };

      final patched = shellPreferencePatch(current, {'locale': 'it'}, 999);

      expect(patched['theme'], 'dark');
      expect(patched['locale'], 'it');
      expect(patched['updatedAt'], {'theme': 100, 'locale': 999});
    });

    test('patch with a null change removes the key but keeps its history', () {
      final current = {
        'locale': 'it',
        'updatedAt': {'locale': 50},
      };

      final patched = shellPreferencePatch(current, {'locale': null}, 900);

      expect(patched.containsKey('locale'), isFalse);
      expect(patched['updatedAt'], {'locale': 900});
    });
  });

  group('codec: reconcile rules', () {
    test('a key the cloud holds and the device never edited pulls', () {
      final result = shellPreferencesReconcile(
        cloudPreferences: {
          'theme': 'light',
          'updatedAt': {'theme': 500},
        },
        localTheme: 'dark', // device default, never stamped
        localLocale: null,
        localPlayerName: 'Player',
        localStamps: const {},
      );

      expect(result.pull, {ShellPrefKey.theme: 'light'});
      // The codec is value-agnostic: the default-looking 'Player' is a
      // string like any other, so it seeds up. The controller filters the
      // default out before reconcile (a device that never chose a name
      // has nothing to say).
      expect(result.push, {ShellPrefKey.playerName: 'Player'});
    });

    test('a locally-stamped key newer than the cloud push-seeds up', () {
      final result = shellPreferencesReconcile(
        cloudPreferences: const {}, // fresh account: nothing there yet
        localTheme: 'light',
        localLocale: 'it',
        localPlayerName: 'Marcuz',
        localStamps: const {
          'theme': 900,
          'locale': 900,
          'playerName': 900,
        },
      );

      expect(result.pull, isEmpty);
      expect(result.push, {
        ShellPrefKey.theme: 'light',
        ShellPrefKey.locale: 'it',
        ShellPrefKey.playerName: 'Marcuz',
      });
    });

    test('a key the cloud never saw seeds up even without a local stamp', () {
      // The pre-sync playerName: locally set, never stamped, absent from
      // the cloud blob. It is still the only truth there is.
      final result = shellPreferencesReconcile(
        cloudPreferences: const {},
        localTheme: null,
        localLocale: null,
        localPlayerName: 'Marcuz',
        localStamps: const {},
      );

      expect(result.pull, isEmpty);
      expect(result.push, {ShellPrefKey.playerName: 'Marcuz'});
    });

    test('a newer cloud edit wins over a stale local one (last writer wins)',
        () {
      final result = shellPreferencesReconcile(
        cloudPreferences: {
          'locale': 'en',
          'updatedAt': {'locale': 2000},
        },
        localTheme: null,
        localLocale: 'it',
        localPlayerName: null,
        localStamps: const {'locale': 1000},
      );

      expect(result.pull, {ShellPrefKey.locale: 'en'});
      expect(result.push, isEmpty);
    });

    test('a newer local edit pushes at sign-in (offline edits propagate)', () {
      final result = shellPreferencesReconcile(
        cloudPreferences: {
          'locale': 'en',
          'updatedAt': {'locale': 1000},
        },
        localTheme: null,
        localLocale: 'it',
        localPlayerName: null,
        localStamps: const {'locale': 2000},
      );

      expect(result.pull, isEmpty);
      // The local edit is newer (made offline, or its flush failed): the
      // sign-in's union push carries it up — last-writer-wins holds on
      // the server too. An equal stamp means the flush already delivered
      // the value and this adds no PUT.
      expect(result.push, {ShellPrefKey.locale: 'it'});
    });

    test('different keys edited on different devices merge in both directions',
        () {
      final result = shellPreferencesReconcile(
        cloudPreferences: {
          'theme': 'light',
          'updatedAt': {'theme': 800},
        },
        localTheme: 'dark', // unstamped default, but cloud has the key → pull
        localLocale: 'it',
        localPlayerName: 'Marcuz',
        localStamps: const {'locale': 900, 'playerName': 910},
      );

      expect(result.pull, {ShellPrefKey.theme: 'light'});
      expect(result.push, {
        ShellPrefKey.locale: 'it',
        ShellPrefKey.playerName: 'Marcuz',
      });
    });
  });

  group('codec: provenance (ShellPrefOrigin)', () {
    test('round-trips through prefs; device entries stay unrecorded', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(shellPrefOriginsFromPrefs(prefs), isEmpty);

      await writeShellPrefOrigins(prefs, {
        ShellPrefKey.theme: ShellPrefOrigin.cloud,
        ShellPrefKey.locale: ShellPrefOrigin.local,
        ShellPrefKey.playerName: ShellPrefOrigin.device,
      });

      final origins = shellPrefOriginsFromPrefs(prefs);
      expect(origins[ShellPrefKey.theme], ShellPrefOrigin.cloud);
      expect(origins[ShellPrefKey.locale], ShellPrefOrigin.local);
      // device = no story: removed, not stored.
      expect(origins.containsKey(ShellPrefKey.playerName), isFalse);
    });

    test('writes grow the record; clearing back to device removes the file',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await writeShellPrefOrigins(
          prefs, {ShellPrefKey.theme: ShellPrefOrigin.local});
      await writeShellPrefOrigins(
          prefs, {ShellPrefKey.locale: ShellPrefOrigin.cloud});
      expect(shellPrefOriginsFromPrefs(prefs).length, 2);

      // Back to device for one key; the other survives.
      await writeShellPrefOrigins(
          prefs, {ShellPrefKey.theme: ShellPrefOrigin.device});
      final origins = shellPrefOriginsFromPrefs(prefs);
      expect(origins.keys, [ShellPrefKey.locale]);

      await writeShellPrefOrigins(
          prefs, {ShellPrefKey.locale: ShellPrefOrigin.device});
      expect(prefs.getString(shellPrefOriginsKey), isNull);
    });

    test('malformed records read as empty, never throw', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(shellPrefOriginsKey, 'not json');
      expect(shellPrefOriginsFromPrefs(prefs), isEmpty);
      await prefs.setString(
          shellPrefOriginsKey, jsonEncode({'dragon': 'cloud'}));
      expect(shellPrefOriginsFromPrefs(prefs), isEmpty);
    });
  });

  group('AccountController preference sync', () {
    late List<http.Request> puts;

    void givenServer({
      Map<String, dynamic> metadata = const {},
      String email = 'sync@shell.test',
    }) {
      puts = [];
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/signup')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'user_already_registered',
                  'msg': 'User already registered',
                }),
                422);
          }
          if (request.url.path.endsWith('/auth/v1/token')) {
            return http.Response(
                jsonEncode({
                  'access_token': 'at-sync',
                  'refresh_token': 'rt-sync',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u9',
                    'email': email,
                    'user_metadata': metadata
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            if (request.method == 'PUT') {
              puts.add(request);
              return http.Response('{}', 200);
            }
            return http.Response(
                jsonEncode({
                  'id': 'u9',
                  'email': email,
                  'user_metadata': metadata,
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    test('sign-in pulls cloud preferences into the local notifiers', () async {
      givenServer(metadata: {
        'kommons': {
          'theme': 'light',
          'locale': 'it',
          'playerName': 'CloudName',
          'updatedAt': {
            'theme': 1900000000,
            'locale': 1900000000,
            'playerName': 1900000000,
          },
        },
      });

      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      expect(appTheme.value, ThemeMode.light);
      expect(appLocale.value, ShellLanguage.italiano);
      expect(account.playerName, 'CloudName');
    });

    test('sign-in pushes this device\'s values onto a fresh account', () async {
      // Local edits first (no session: they only persist locally).
      appTheme.mode = ThemeMode.light;
      await appLocale.setLanguage(ShellLanguage.italiano);
      await account.setPlayerName('LocalLass');

      givenServer();

      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      expect(puts, isNotEmpty);
      final data = jsonDecode(puts.last.body)['data'] as Map<String, dynamic>;
      final kommons = data['kommons'] as Map<String, dynamic>;
      expect(kommons['theme'], 'light');
      expect(kommons['locale'], 'it');
      expect(kommons['playerName'], 'LocalLass');
      expect((kommons['updatedAt'] as Map).keys.toSet(),
          {'theme', 'locale', 'playerName'});
    });

    test('a local edit stamps and pushes through the debounced flush',
        () async {
      givenServer();
      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();
      final putsAfterSignIn = puts.length;

      appTheme.mode = ThemeMode.light;
      // The edit's queueing is fire-and-forget: let it settle, then the
      // flush lands the PUT.
      await pumpEventQueue();
      await account.debugFlushPendingPreferencePushes();

      expect(puts.length, greaterThan(putsAfterSignIn));
      final data = jsonDecode(puts.last.body)['data'] as Map<String, dynamic>;
      expect(data['kommons']['theme'], 'light');

      final prefs = await SharedPreferences.getInstance();
      final stamps = jsonDecode(prefs.getString('prefs.account.prefStamps')!)
          as Map<String, dynamic>;
      expect(stamps['theme'], isPositive);
    });

    test('edits while signed out stay local (no push, but marked + stamped)',
        () async {
      appTheme.mode = ThemeMode.light;
      await account.debugFlushPendingPreferencePushes();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.prefStamps'), isNull);

      // The choice is still this device's story: it shows as local now and
      // carries a stamp so a cloud value can never silently clobber it at
      // the next sign-in (the reconcile loses, the edit pushes instead).
      expect(
          account.preferenceOrigin(ShellPrefKey.theme), ShellPrefOrigin.local);
      givenServer();
      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();
      final stamps = jsonDecode(prefs.getString('prefs.account.prefStamps')!)
          as Map<String, dynamic>;
      expect(stamps['theme'], isPositive);
      final data = jsonDecode(puts.last.body)['data'] as Map<String, dynamic>;
      expect(data['kommons']['theme'], 'light');
    });

    test('sign-out clears the pending push queue', () async {
      givenServer();
      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      appTheme.mode = ThemeMode.light;
      await account.signOut();
      await account.debugFlushPendingPreferencePushes();

      // No PUT for the queued edit: it died with the session.
      expect(
          puts.where((r) =>
              (jsonDecode(r.body)['data'] as Map<String, dynamic>)['kommons']
                  ?['theme'] ==
              'light'),
          isEmpty);
    });

    test('an unreachable server leaves the session intact (quiet no-op)',
        () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/signup')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'user_already_registered',
                  'msg': 'User already registered',
                }),
                422);
          }
          if (request.url.path.endsWith('/auth/v1/token')) {
            return http.Response(
                jsonEncode({
                  'access_token': 'at-off',
                  'refresh_token': 'rt-off',
                  'expires_at': 1900000000,
                  'user': {'id': 'u9', 'email': 'sync@shell.test'},
                }),
                200);
          }
          throw Exception('server down');
        }),
      );

      await account.signInWithPassword('sync@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      // The sign-in itself survived; the sync quietly did nothing.
      expect(account.isCloudSignedIn, isTrue);
      expect(appTheme.value, ThemeMode.dark);
    });
  });
}
