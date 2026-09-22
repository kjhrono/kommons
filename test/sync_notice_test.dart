import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The player-facing side of the preference sync: when a sign-in pulls
/// cloud values in, a small snackbar says so — once per pull, only when
/// something actually changed, never for same-value re-confirms.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
  });

  group('pull event rules (controller)', () {
    void givenServer({
      Map<String, dynamic> metadata = const {},
    }) {
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
                  'access_token': 'at-n',
                  'refresh_token': 'rt-n',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u2',
                    'email': 'n@shell.test',
                    'user_metadata': metadata
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            if (request.method == 'PUT') return http.Response('{}', 200);
            return http.Response(
                jsonEncode({
                  'id': 'u2',
                  'email': 'n@shell.test',
                  'user_metadata': metadata,
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    test('a real change fires the event; a re-confirm stays silent', () async {
      givenServer(metadata: {
        'kommons': {
          'theme': 'light',
          'updatedAt': {'theme': 1900000000},
        },
      });

      await account.signInWithPassword('n@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();
      expect(account.preferencesPulled.value, 1);

      // Sign in again with the same cloud state: the theme now matches —
      // nothing changed, nothing fires.
      await account.signOut();
      await account.signInWithPassword('n@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();
      expect(account.preferencesPulled.value, 1);
    });

    test('a fresh cloud value on an already-synced device fires again',
        () async {
      givenServer(metadata: {
        'kommons': {
          'theme': 'light',
          'updatedAt': {'theme': 1900000000},
        },
      });
      await account.signInWithPassword('n@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();
      expect(account.preferencesPulled.value, 1);

      // The server's metadata changed (another device pushed a locale).
      givenServer(metadata: {
        'kommons': {
          'theme': 'light',
          'locale': 'it',
          'updatedAt': {'theme': 1900000000, 'locale': 1900000001},
        },
      });
      await account.signOut();
      await account.signInWithPassword('n@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      expect(appLocale.value, ShellLanguage.italiano);
      expect(account.preferencesPulled.value, 2);
    });

    test('the acknowledge marks each event shown exactly once', () {
      expect(account.shouldShowSyncNotice(1), isTrue);
      account.markSyncNoticeShown(1);
      expect(account.shouldShowSyncNotice(1), isFalse);
      expect(account.shouldShowSyncNotice(2), isTrue);
      // Zero is never a showable event.
      expect(account.shouldShowSyncNotice(0), isFalse);
    });
  });

  group('ShellApp sync notice', () {
    testWidgets('the notice itself is wired in ShellApp', (tester) async {
      // Drive a real pull under a ShellApp and find the snackbar.
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
                  'access_token': 'at-w',
                  'refresh_token': 'rt-w',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u3',
                    'email': 'w@shell.test',
                    'user_metadata': {
                      'kommons': {
                        'locale': 'it',
                        'updatedAt': {'locale': 1900000000},
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
                      'id': 'u3',
                      'email': 'w@shell.test',
                      'user_metadata': {
                        'kommons': {
                          'locale': 'it',
                          'updatedAt': {'locale': 1900000000},
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
      await tester.pump(); // first frame (messenger key registers)

      await account.signInWithPassword('w@shell.test', 'whatever-1');
      await tester.pump(); // sync microtasks
      await tester.pump();
      await tester.pump();

      expect(find.text(appLocale.strings.preferencesSynced), findsOneWidget);
      expect(appLocale.value, ShellLanguage.italiano);
    });

    testWidgets('showPreferencesSyncedNotice:false hushes the snackbar',
        (tester) async {
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
                  'access_token': 'at-q',
                  'refresh_token': 'rt-q',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u4',
                    'email': 'q@shell.test',
                    'user_metadata': {
                      'kommons': {
                        'locale': 'it',
                        'updatedAt': {'locale': 1900000000},
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
                      'id': 'u4',
                      'email': 'q@shell.test',
                      'user_metadata': {
                        'kommons': {
                          'locale': 'it',
                          'updatedAt': {'locale': 1900000000},
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
        showPreferencesSyncedNotice: false,
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();

      await account.signInWithPassword('q@shell.test', 'whatever-1');
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The pull still happened (locale applied) — only the notice is muted.
      expect(appLocale.value, ShellLanguage.italiano);
      expect(find.text(appLocale.strings.preferencesSynced), findsNothing);
    });
  });
}
