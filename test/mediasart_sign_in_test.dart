import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Sign in with MediaSart": the hub (mediasart.com/<lang>/connect) hands
/// the app its own session in the provider-redirect fragment shape, so
/// the flow rides the same collectors as Google. No browser here — the
/// collector is injected, the HTTP layer mocked.
void main() {
  const fragment = '#access_token=a1&refresh_token=r1&expires_in=3600'
      '&expires_at=4102444800&token_type=bearer&type=handoff&provider=mediasart';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.value = null;
  });

  group('AuthService.mediasartConnectUrl', () {
    test('points at the hub connect page with the redirect', () {
      final url = AuthService.mediasartConnectUrl(
        hub: Uri.parse('https://mediasart.com'),
        redirectTo: Uri.parse('https://kalcio.mediasart.com'),
      );
      expect(url.toString(),
          'https://mediasart.com/en/connect/?redirect_to=https%3A%2F%2Fkalcio.mediasart.com');
    });

    test('Italian hub page for Italian, English otherwise', () {
      Uri build(String? lang) => AuthService.mediasartConnectUrl(
            hub: Uri.parse('https://mediasart.com/'),
            redirectTo: Uri.parse('kognitio://auth'),
            language: lang,
          );
      expect(build('it').path, '/it/connect/');
      expect(build('de').path, '/en/connect/');
      expect(build(null).path, '/en/connect/');
      expect(build('it').queryParameters['redirect_to'], 'kognitio://auth');
    });
  });

  group('AccountController.signInWithMediaSart', () {
    late Uri? opened;

    Future<void> givenServer() async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://kalcio.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://kalcio.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            expect(request.headers['Authorization'], 'Bearer a1');
            return http.Response(
                jsonEncode({
                  'id': 'u1',
                  'email': 'player@example.com',
                  'email_confirmed_at': '2026-01-01T00:00:00Z',
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    setUp(() {
      opened = null;
      account.collectOAuthFragment = (url) async {
        opened = Uri.parse(url);
        return fragment;
      };
    });

    test('opens the hub, installs the handed-off session as mediasart',
        () async {
      await givenServer();
      account.oauthRedirectUri = Uri.parse('kalcio://auth');
      await account.signInWithMediaSart();

      expect(opened!.host, 'mediasart.com');
      expect(opened!.path, '/en/connect/');
      expect(opened!.queryParameters['redirect_to'], 'kalcio://auth');
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.provider, 'mediasart');
      expect(account.value!.email, 'player@example.com');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'), contains('"a1"'));
    });

    test('follows the app language and a custom hub', () async {
      await givenServer();
      appLocale.value = ShellLanguage.italiano;
      account.mediasartHub = Uri.parse('https://staging.mediasart.com');
      await account.signInWithMediaSart(
          redirectTo: Uri.parse('https://kalcio.mediasart.com/'));
      expect(opened.toString(),
          'https://staging.mediasart.com/it/connect/?redirect_to=https%3A%2F%2Fkalcio.mediasart.com%2F');
    });

    test('closing the hub page cancels quietly', () async {
      await givenServer();
      account.collectOAuthFragment = (_) async => null;
      await account.signInWithMediaSart();
      expect(account.value, isNull);
    });

    test('a cancelled hub (error fragment) is a typed cancel', () async {
      await givenServer();
      account.collectOAuthFragment =
          (_) async => '#error=access_denied&error_description=cancelled';
      await expectLater(
        account.signInWithMediaSart(),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'oauth_cancelled')),
      );
    });

    test('no game server configured → no_server', () async {
      account.serverConnection = () async => null;
      await expectLater(
        account.signInWithMediaSart(),
        throwsA(
            isA<AuthException>().having((e) => e.code, 'code', 'no_server')),
      );
      expect(opened, isNull);
    });

    test('oauthPopupHandlers wires the mediasart button by default', () {
      expect(oauthPopupHandlers().keys,
          containsAll(<String>['mediasart', 'google', 'github']));
    });
  });
}
