import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Provider-grant revocation: the fragment's `provider_token` is captured
/// onto the session, survives every session refresh and metadata write,
/// and sign-out launches the provider's revoke URL through the same
/// url_launcher plumbing the authorize link uses — Google revocable,
/// GitHub honestly not.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    account.resetForTest();
  });

  group('codec: provider grant capture', () {
    test('the fragment parser captures provider_token and provider', () {
      final session = AuthService.sessionFromImplicitFragment(
          'access_token=a&refresh_token=r&provider_token=pt&provider=google');
      expect(session!.providerToken, 'pt');
      expect(session.providerName, 'google');
    });

    test('a session without the provider fields stays password-shaped', () {
      final session = AuthService.sessionFromImplicitFragment(
          'access_token=a&refresh_token=r');
      expect(session!.providerToken, isNull);
      expect(session.providerName, isNull);
    });

    test('the grant survives the session JSON round-trip', () {
      const session = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: 1900000000,
        userId: 'u',
        email: 'x',
        providerToken: 'pt',
        providerName: 'github',
      );
      final restored = AuthSession.fromJson(
          jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>)!;
      expect(restored.providerToken, 'pt');
      expect(restored.providerName, 'github');
    });

    test('copyWith replaces fields without losing the grant', () {
      const session = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: 1,
        userId: 'u',
        email: 'e',
        providerToken: 'pt',
        providerName: 'google',
      );
      final copied =
          session.copyWith(userMetadata: {'must_change_password': true});
      expect(copied.userMetadata, {'must_change_password': true});
      expect(copied.providerToken, 'pt');
      expect(copied.providerName, 'google');
    });
  });

  group('codec: revoke URL', () {
    test('google builds its documented endpoint from the token', () {
      final url = providerGrantRevokeUrl('google', 'TOKEN');
      expect(url, isNotNull);
      expect(url!.toString(),
          'https://accounts.google.com/o/oauth2/revoke?token=TOKEN');
      expect(canRevokeProviderGrant('google'), isTrue);
    });

    test('github has no client-side revocation — the honest answer is false',
        () {
      expect(canRevokeProviderGrant('github'), isFalse);
      expect(providerGrantRevokeUrl('github', 'TOKEN'), isNull);
      // Case-insensitive on the provider id.
      expect(canRevokeProviderGrant('GitHub'), isFalse);
    });

    test('unknown or absent providers never claim revocation', () {
      expect(canRevokeProviderGrant('gitlab'), isFalse);
      expect(canRevokeProviderGrant(null), isFalse);
      expect(providerGrantRevokeUrl('gitlab', 'T'), isNull);
    });
  });

  group('sign-out launches the revoke URL', () {
    late _FakeLauncher launcher;

    void givenServer({
      required String providerName,
      required String providerToken,
    }) {
      launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: _mockClient(),
      );
    }

    test('a google session revokes the grant on sign-out', () async {
      givenServer(providerName: 'google', providerToken: 'pt-google');
      account.collectOAuthFragment = (url) async =>
          '#access_token=a&refresh_token=r&provider_token=pt-google&provider=google';
      await account.signInWithProvider('google');
      await account.debugFlushPendingPreferencePushes();

      await account.signOut();
      await pumpEventQueue();

      expect(launcher.launchedUrls, hasLength(1));
      expect(launcher.launchedUrls.single,
          'https://accounts.google.com/o/oauth2/revoke?token=pt-google');
      expect(account.isCloudSignedIn, isFalse);
    });

    test('a github session signs out without pretending to revoke', () async {
      givenServer(providerName: 'github', providerToken: 'pt-github');
      account.collectOAuthFragment = (url) async =>
          '#access_token=a&refresh_token=r&provider_token=pt-github&provider=github';
      await account.signInWithProvider('github');
      await account.debugFlushPendingPreferencePushes();

      await account.signOut();
      await pumpEventQueue();

      // Nothing launched: GitHub's grant needs the server-held secret.
      expect(launcher.launchedUrls, isEmpty);
      expect(account.isCloudSignedIn, isFalse);
    });

    test('a password session revokes nothing', () async {
      launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
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
                  'access_token': 'a',
                  'refresh_token': 'r',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u9',
                    'email': 'p@shell.test',
                    'user_metadata': <String, dynamic>{},
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            if (request.method == 'PUT') return http.Response('{}', 200);
            return http.Response(
                jsonEncode({
                  'id': 'u9',
                  'email': 'p@shell.test',
                  'user_metadata': <String, dynamic>{},
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/logout')) {
            return http.Response('', 204);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await account.signInWithPassword('p@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      await account.signOut();
      await pumpEventQueue();

      expect(launcher.launchedUrls, isEmpty);
    });

    test('a failed launch is a quiet skip, not a sign-out failure', () async {
      givenServer(providerName: 'google', providerToken: 'pt-x');
      launcher.launchSucceeds = false;
      account.collectOAuthFragment = (url) async =>
          '#access_token=a&refresh_token=r&provider_token=pt-x&provider=google';
      await account.signInWithProvider('google');
      await account.debugFlushPendingPreferencePushes();

      await expectLater(account.signOut(), completes);
      expect(account.isCloudSignedIn, isFalse);
    });
  });
}

MockClient _mockClient() {
  return MockClient((request) async {
    if (request.url.path.endsWith('/auth/v1/user')) {
      if (request.method == 'PUT') return http.Response('{}', 200);
      return http.Response(
          jsonEncode({
            'id': 'u9',
            'email': 'ada@shell.test',
            'email_confirmed_at': '2026-01-01',
            'user_metadata': <String, dynamic>{},
          }),
          200);
    }
    if (request.url.path.endsWith('/auth/v1/logout')) {
      return http.Response('', 204);
    }
    return http.Response('unexpected', 404);
  });
}

class _FakeLauncher extends UrlLauncherPlatform {
  final launchedUrls = <String>[];
  bool launchSucceeds = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launchedUrls.add(url);
    return launchSucceeds;
  }
}
