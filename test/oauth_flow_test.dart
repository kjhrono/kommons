import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reference OAuth flow: the game server's hosted authorize page plus
/// an implicit-fragment popup. No browser in tests — the fragment collector
/// is injected, the HTTP layer mocked.
void main() {
  const fragment = '#access_token=a1&refresh_token=r1'
      '&expires_at=4102444800&provider=google&provider_id=pid9';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
  });

  group('AuthService.authorizeUrl', () {
    // The regression this pins: the URL used to be Netlify Identity's shape
    // (`/.netlify/identity/gt/{provider}/authorize?redirectTo=…`), which a
    // self-hosted Supabase stack does not serve at all — the request fell
    // through to the SPA and sign-in silently never started, so every host had
    // to add a redirect of its own in nginx. GoTrue's own route needs none.
    test('targets GoTrue\'s authorize route, with GoTrue\'s parameter names',
        () {
      final service = AuthService(serverUrl: 'https://shell.test', apiKey: 'k');
      final url = service.authorizeUrl(
        provider: 'google',
        redirectTo: Uri.parse('https://shell.test'),
      );
      expect(
          url.toString(),
          'https://shell.test/auth/v1/authorize?provider=google'
          '&redirect_to=https%3A%2F%2Fshell.test');
      expect(url.path, '/auth/v1/authorize');
      // Nothing about this URL may depend on a server-side rewrite.
      expect(url.toString(), isNot(contains('netlify')));
    });

    test('keeps a base path and supports other providers', () {
      final service =
          AuthService(serverUrl: 'https://shell.test/sub', apiKey: 'k');
      final url = service.authorizeUrl(
        provider: 'github',
        redirectTo: Uri.parse('https://shell.test/sub/'),
      );
      expect(url.path, '/sub/auth/v1/authorize');
      expect(url.queryParameters['provider'], 'github');
      expect(url.queryParameters['redirect_to'], 'https://shell.test/sub/');
    });

    test('a mobile deep link rides along as the redirect target', () {
      final service = AuthService(serverUrl: 'https://kalcio.test');
      final url = service.authorizeUrl(
        provider: 'google',
        redirectTo: Uri.parse('kalcio://auth'),
      );
      expect(url.path, '/auth/v1/authorize');
      expect(url.queryParameters['redirect_to'], 'kalcio://auth');
    });
  });

  group('AuthService.sessionFromImplicitFragment', () {
    test('decodes a full fragment', () {
      final session = AuthService.sessionFromImplicitFragment(fragment)!;
      expect(session.accessToken, 'a1');
      expect(session.refreshToken, 'r1');
      expect(session.expiresAt, 4102444800);
      expect(session.userId, 'pid9');
      expect(session.isExpired, isFalse);
    });

    test('expires_in is the fallback when expires_at is absent', () {
      final session = AuthService.sessionFromImplicitFragment(
          '#access_token=a&refresh_token=r&expires_in=1200')!;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(session.expiresAt, inExclusiveRange(now + 1100, now + 1300));
    });

    test('missing tokens, errors and emptiness decode to null', () {
      expect(AuthService.sessionFromImplicitFragment('#error=access_denied'),
          isNull);
      expect(
          AuthService.sessionFromImplicitFragment('#access_token=a'), isNull);
      expect(AuthService.sessionFromImplicitFragment('#'), isNull);
      expect(AuthService.sessionFromImplicitFragment(''), isNull);
    });
  });

  group('AccountController.signInWithProvider', () {
    late Uri? capturedAuthorize;

    Future<void> givenServer() async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response(
                jsonEncode({
                  'id': 'u9',
                  'email': 'g@gmail.com',
                  'email_confirmed_at': '2026-01-01T00:00:00Z',
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    setUp(() {
      capturedAuthorize = null;
      account.collectOAuthFragment = (url) async {
        capturedAuthorize = Uri.parse(url);
        return fragment;
      };
    });

    test('happy path: session lands, email is fetched, provider recorded',
        () async {
      await givenServer();
      await account.signInWithProvider('google');

      expect(capturedAuthorize!.path, '/auth/v1/authorize');
      expect(capturedAuthorize!.queryParameters['provider'], 'google');
      expect(capturedAuthorize!.queryParameters['redirect_to'], isNotNull);
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.provider, 'google');
      expect(account.value!.email, 'g@gmail.com');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'), isNotNull);
      expect(prefs.getString('prefs.account.email'), 'g@gmail.com');
      expect(account.pendingSignupEmail, isNull);
    });

    test('a dismissed popup cancels quietly', () async {
      await givenServer();
      account.collectOAuthFragment = (_) async => null;
      await account.signInWithProvider('google');
      expect(account.value, isNull);
      expect(account.isCloudSignedIn, isFalse);
    });

    test('an error fragment surfaces as a cancelled flow', () async {
      await givenServer();
      account.collectOAuthFragment =
          (_) async => '#error=access_denied&error_description=nope';
      await expectLater(
        account.signInWithProvider('google'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'oauth_cancelled')),
      );
      expect(account.value, isNull);
    });

    test('an unconfirmed provider identity is rejected', () async {
      await givenServer();
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async => http.Response(
            jsonEncode({'id': 'u9', 'email': 'g@gmail.com'}), 200)),
      );
      await expectLater(
        account.signInWithProvider('github'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'email_not_confirmed')),
      );
      expect(account.value, isNull);
    });

    test('no configured server explains itself', () async {
      await expectLater(
        account.signInWithProvider('google'),
        throwsA(
            isA<AuthException>().having((e) => e.code, 'code', 'no_server')),
      );
    });

    test('an unsupported collector surfaces as oauth_unsupported', () async {
      await givenServer();
      account.collectOAuthFragment = (_) async =>
          throw UnsupportedError('OAuth sign-in runs on the web build.');
      await expectLater(
        account.signInWithProvider('google'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'oauth_unsupported')),
      );
    });
  });

  group('settings wiring', () {
    testWidgets('the Google button runs the reference flow end to end',
        (tester) async {
      Uri? captured;
      account.serverConnection =
          () async => const ServerConnection(url: 'https://shell.test');
      account.collectOAuthFragment = (url) async {
        captured = Uri.parse(url);
        return null; // the popup would be cancelled right away
      };

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(
          gameId: 'probe',
          oauthProviders: oauthPopupHandlers(),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(
          tester
              .widget<OutlinedButton>(
                  find.byKey(const ValueKey('oauth-google')))
              .onPressed,
          isNotNull);

      await tester.tap(find.byKey(const ValueKey('oauth-google')));
      for (var i = 0; i < 10 && captured == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      // The button reached the game server's hosted authorize page — a
      // cancelled popup then leaves the screen quiet (no error snackbar).
      expect(captured, isNotNull);
      expect(captured!.path, '/auth/v1/authorize');
      expect(captured!.queryParameters['provider'], 'google');
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
