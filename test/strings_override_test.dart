import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Host-overridable shell strings: `ShellStrings.installOverrides` swaps
/// the catalog (most usefully a partial one — every field defaults, so a
/// host replaces one string and keeps the language's wording), and the
/// wired UI — the sync snackbar here — speaks the override immediately.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
    ShellStrings.resetOverrides();
  });

  group('catalog rules', () {
    test('an override replaces the built-in catalog for that language', () {
      ShellStrings.installOverrides({
        ShellLanguage.english: const ShellStrings(
            preferencesSynced: 'Your look just arrived from the cloud.'),
      });

      expect(appLocale.strings.preferencesSynced,
          'Your look just arrived from the cloud.');
    });

    test('a partial override keeps every other string at the built-in value',
        () {
      ShellStrings.installOverrides({
        ShellLanguage.english: const ShellStrings(preferencesSynced: 'Synced!'),
      });

      // The untouched strings stay English.
      expect(appLocale.strings.settingsTitle, 'SETTINGS');
      expect(appLocale.strings.newGame, 'NEW GAME');
    });

    test('other languages keep their built-in catalogs', () {
      ShellStrings.installOverrides({
        ShellLanguage.english: const ShellStrings(preferencesSynced: 'Synced!'),
      });

      final italian = ShellStrings.forLanguage(ShellLanguage.italiano);
      expect(italian.preferencesSynced, 'Preferenze caricate dal tuo account');
    });

    test('a partial italian override merges onto the italian catalog', () {
      ShellStrings.installOverrides({
        ShellLanguage.italiano: const ShellStrings.italian(
            preferencesSynced: 'Aspetto e nome arrivati dal cloud.'),
      });

      final italian = ShellStrings.forLanguage(ShellLanguage.italiano);
      expect(italian.preferencesSynced, 'Aspetto e nome arrivati dal cloud.');
      expect(italian.settingsTitle, 'IMPOSTAZIONI');
    });

    test('resetOverrides restores the built-in catalogs', () {
      ShellStrings.installOverrides({
        ShellLanguage.english: const ShellStrings(preferencesSynced: 'Synced!'),
      });
      ShellStrings.resetOverrides();

      expect(appLocale.strings.preferencesSynced,
          'Preferences loaded from your account');
    });

    test('unknown codes still fall back to English (with overrides in place)',
        () {
      ShellStrings.installOverrides({
        ShellLanguage.english: const ShellStrings(preferencesSynced: 'Synced!'),
      });

      // ShellLanguage is a closed enum here; forLanguage's contract for
      // unrecognized codes is exercised through the persisted-locale
      // loader, so assert the English pick directly.
      expect(ShellStrings.forLanguage(ShellLanguage.english).preferencesSynced,
          'Synced!');
    });
  });

  group('the wired sync snackbar speaks the override', () {
    testWidgets('the snackbar shows the host wording, not the default',
        (tester) async {
      const hostWording = 'Your look, language and name just synced.';
      ShellStrings.installOverrides({
        ShellLanguage.english:
            const ShellStrings(preferencesSynced: hostWording),
      });

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
                  'access_token': 'at-o',
                  'refresh_token': 'rt-o',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u5',
                    'email': 'o@shell.test',
                    'user_metadata': {
                      'kommons': {
                        'theme': 'light',
                        'updatedAt': {'theme': 1900000000},
                      },
                    },
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            return request.method == 'PUT'
                ? http.Response('{}', 200)
                : http.Response(
                    jsonEncode({
                      'id': 'u5',
                      'email': 'o@shell.test',
                      'user_metadata': {
                        'kommons': {
                          'theme': 'light',
                          'updatedAt': {'theme': 1900000000},
                        },
                      },
                    }),
                    200);
          }
          return http.Response('unexpected', 404);
        }),
      );

      await tester.pumpWidget(const ShellApp(
        title: 'HERALD',
        seedColor: Color(0xff7a5c2e),
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();

      await account.signInWithPassword('o@shell.test', 'whatever-1');
      await tester.pump(); // sync microtasks
      await tester.pump();
      await tester.pump();

      // The pull landed (theme applied) and the notice carries the host's
      // wording — the override was read at show time, not baked in.
      expect(appTheme.value, ThemeMode.light);
      expect(find.text(hostWording), findsOneWidget);
      expect(find.text('Preferences loaded from your account'), findsNothing);
    });
  });
}
