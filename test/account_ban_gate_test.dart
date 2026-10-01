import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ban kill-switch at the controller level: a `banned` answer from the
/// auth service is terminal — the suspension is stamped for the settings
/// card, the stored session dies on every path (sign-in, verification,
/// silent refresh, startup restore), and sign-out clears the state again.
/// The same file covers the native reset parking: requestPasswordReset
/// parks the address itself, so the recovery UI state survives a rebuild
/// without the screen remembering to park.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    account.resetForTest();
  });

  AuthSession session({String email = 'seat@shell.test'}) => AuthSession(
        accessToken: 'at',
        refreshToken: 'rt',
        expiresAt: 1900000000,
        userId: 'u1',
        email: email,
      );

  AuthService serviceReturning(AuthSession? Function() next) =>
      AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          final sessionOrError = next();
          if (sessionOrError == null) {
            return http.Response(
                jsonEncode(
                    {'error_code': 'banned', 'msg': 'Account suspended'}),
                403);
          }
          return http.Response(jsonEncode({
            'access_token': sessionOrError.accessToken,
            'refresh_token': sessionOrError.refreshToken,
            'expires_at': sessionOrError.expiresAt,
            'user': {
              'id': sessionOrError.userId,
              'email': sessionOrError.email
            },
          }), 200);
        }),
      );

  group('ban gate on sign-in paths', () {
    test('sign-in refusal stamps the suspension and keeps it', () async {
      account.authService = serviceReturning(() => null);

      await expectLater(
        account.signInWithPassword('seat@shell.test', 'pass-1'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'banned')),
      );
      expect(account.banned, isTrue);
      // The message carries no window: bannedUntil stays empty.
      expect(account.bannedUntil, isEmpty);
    });

    test('a window in the refusal message is captured', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'error_code': 'banned',
              'msg': 'Account suspended until 2026-10-10T10:00:00Z.'
            }),
            403)),
      );

      await expectLater(
        account.signInWithPassword('seat@shell.test', 'pass-1'),
        throwsA(isA<AuthException>()),
      );
      expect(account.banned, isTrue);
      expect(account.bannedUntil, '2026-10-10T10:00:00Z');
    });

    test('a banned fallback sign-in (after user_already_registered) also '
        'stamps the suspension', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      var calls = 0;
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/auth/v1/signup')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'user_already_registered',
                  'msg': 'Email already registered'
                }),
                422);
          }
          return http.Response(
              jsonEncode(
                  {'error_code': 'banned', 'msg': 'Account suspended'}),
              403);
        }),
      );

      await expectLater(
        account.signInWithPassword('seat@shell.test', 'pass-1'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'banned')),
      );
      expect(account.banned, isTrue);
      expect(calls, 2);
    });

    test('the dead session is dropped from storage on any banned path',
        () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      // A stale (expired) session sits in storage; the silent restore
      // refresh then answers banned. The stored copy must not survive.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'prefs.account.session',
          jsonEncode(session().toJson())
              .replaceFirst('"expires_at":1900000000', '"expires_at":1000'));

      account.authService = serviceReturning(() => null);
      await account.load();

      expect(account.banned, isTrue);
      expect(await account.validAccessToken(), isNull);
      expect(prefs.getString('prefs.account.session'), isNull);
    });

    test('sign-out clears the suspension state', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = serviceReturning(() => null);
      await expectLater(
        account.signInWithPassword('seat@shell.test', 'pass-1'),
        throwsA(isA<AuthException>()),
      );
      expect(account.banned, isTrue);

      await account.signOut();
      expect(account.banned, isFalse);
      expect(account.bannedUntil, isEmpty);
    });
  });

  group('native reset parking', () {
    test('requestPasswordReset parks the address itself', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/auth/v1/recover'));
          return http.Response('', 200);
        }),
      );

      expect(account.pendingResetEmail, isNull);
      await account.requestPasswordReset('lost@shell.test');
      expect(account.pendingResetEmail, 'lost@shell.test');
      // No double park needed from the caller; re-parking is harmless.
      await account.parkPasswordReset('lost@shell.test');
      expect(account.pendingResetEmail, 'lost@shell.test');
    });

    test('resendPasswordReset rides the parked address', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      late http.Request captured;
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      await account.requestPasswordReset('lost@shell.test');
      await account.resendPasswordReset();
      expect(captured.url.path, endsWith('/auth/v1/recover'));
    });
  });

  group('settings card suspension banner', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: const SettingsScreen(),
      ));
      await tester.pump();
    }

    testWidgets('a stamped suspension shows the banner instead of the '
        'sign-in pitch', (tester) async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = serviceReturning(() => null);
      await expectLater(
        account.signInWithPassword('seat@shell.test', 'pass-1'),
        throwsA(isA<AuthException>()),
      );

      await pumpSettings(tester);

      expect(find.byKey(const ValueKey('account-suspended-banner')),
          findsOneWidget);
      expect(find.text('ACCOUNT SUSPENDED'), findsOneWidget);
      expect(find.textContaining('suspended'), findsWidgets);
    });
  });
}
