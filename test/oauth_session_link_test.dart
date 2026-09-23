import 'dart:async';
import 'dart:convert';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The OAuth session-fragment app link: an authorize redirect that re-opens
/// the app when no collector was waiting restores the session it carries —
/// through the same sign-in seam as every other path, so the preference
/// sync (and its visible notice) runs on it too.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
  });

  group('classifier: session fragments vs everything else', () {
    test('a session fragment reads true', () {
      expect(
        oauthSessionFragment(
            '#access_token=at-1&refresh_token=rt-1&expires_at=1900000000'),
        isTrue,
      );
      expect(
        oauthSessionLinkFromUri(
            Uri.parse('mygame://auth#access_token=at-1&refresh_token=rt-1')),
        isTrue,
      );
    });

    test('join, recovery, error, PKCE and junk fragments read false', () {
      expect(oauthSessionFragment('#join=K7QX2'), isFalse);
      expect(oauthSessionFragment('#token=123456&type=recovery'), isFalse);
      expect(oauthSessionFragment('#token_hash=zz9&type=recovery'), isFalse);
      expect(oauthSessionFragment('#error=access_denied'), isFalse);
      expect(oauthSessionFragment('#code=abc'), isFalse); // PKCE
      expect(oauthSessionFragment(''), isFalse);
      expect(
        oauthSessionLinkFromUri(Uri.parse('https://shell.test/#join=K7QX2')),
        isFalse,
      );
    });

    test('a fragment missing the refresh token is not a session', () {
      expect(oauthSessionFragment('#access_token=at-1'), isFalse);
    });
  });

  group('AccountController.restoreFromSessionFragment', () {
    late List<http.Request> puts;

    void givenServer({Map<String, dynamic> metadata = const {}}) {
      puts = [];
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            if (request.method == 'PUT') {
              puts.add(request);
              return http.Response('{}', 200);
            }
            return http.Response(
                jsonEncode({
                  'id': 'u7',
                  'email': 'warm@shell.test',
                  'email_confirmed_at': '2026-01-01T00:00:00Z',
                  'user_metadata': metadata,
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    const fragment =
        '#access_token=at-warm&refresh_token=rt-warm&expires_at=1900000000';

    test('a live fragment signs in and pulls cloud preferences', () async {
      givenServer(metadata: {
        'kommons': {
          'theme': 'light',
          'locale': 'it',
          'updatedAt': {'theme': 1900000000, 'locale': 1900000000},
        },
      });

      final restored = await account.restoreFromSessionFragment(fragment);
      await account.debugFlushPendingPreferencePushes();

      expect(restored, isTrue);
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value?.email, 'warm@shell.test');
      expect(appTheme.value, ThemeMode.light);
      expect(appLocale.value, ShellLanguage.italiano);
      // The restore IS a sign-in for the sync: both cloud values were
      // applied (2 changed) — the pull signal that drives the notice.
      expect(account.preferencesPulled.value, 2);
    });

    test('a dead fragment (revoked/expired token) restores nothing, quietly',
        () async {
      givenServer();
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response(
                jsonEncode({'error': 'invalid_grant', 'msg': 'Token expired'}),
                401);
          }
          return http.Response('unexpected', 404);
        }),
      );

      final restored = await account.restoreFromSessionFragment(fragment);

      expect(restored, isFalse);
      expect(account.isCloudSignedIn, isFalse);
      // Nothing was marked pulled: no notice can fire on a dead link.
      expect(account.preferencesPulled.value, 0);
    });

    test('an unconfirmed provider identity throws typed', () async {
      givenServer();
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response(
                jsonEncode({
                  'id': 'u7',
                  'email': 'warm@shell.test',
                  'user_metadata': {},
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );

      await expectLater(
        account.restoreFromSessionFragment(fragment),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'email_not_confirmed')),
      );
    });

    test(
        'a fragment no collector consumed restores; one the flow consumed '
        'is never double-installed', () async {
      givenServer();

      // The flow marks what it consumed (a completed deep-link flow does).
      account.debugMarkFragmentConsumedByFlow(fragment);
      final restored = await account.restoreFromSessionFragment(fragment);

      expect(restored, isFalse);
      expect(account.isCloudSignedIn, isFalse);
    });
  });

  group('ShellApp session-link delivery', () {
    final links = _FakeLinks();
    final originalPlatform = AppLinksPlatform.instance;

    setUp(() {
      AppLinksPlatform.instance = links;
      links.initialLink = null;
    });
    tearDown(() => AppLinksPlatform.instance = originalPlatform);

    void givenServer() {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            return request.method == 'PUT'
                ? http.Response('{}', 200)
                : http.Response(
                    jsonEncode({
                      'id': 'u7',
                      'email': 'warm@shell.test',
                      'email_confirmed_at': '2026-01-01T00:00:00Z',
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
    }

    testWidgets('a warm session link signs in and posts the sync notice',
        (tester) async {
      givenServer();
      await tester.pumpWidget(const ShellApp(
        title: 'HERALD',
        seedColor: Color(0xff7a5c2e),
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();

      links.controller.add(Uri.parse(
          'mygame://auth#access_token=at-w2&refresh_token=rt-w2&expires_at=1900000000'));
      await tester.pump(); // post-frame callback
      await tester.pump(); // restore microtasks
      await tester.pump(); // sync microtasks
      await tester.pump();

      expect(account.isCloudSignedIn, isTrue);
      expect(appLocale.value, ShellLanguage.italiano);
      expect(find.text(appLocale.strings.preferencesSynced), findsOneWidget);
    });

    testWidgets('a join link never restores a session (watchers disjoint)',
        (tester) async {
      givenServer();
      await tester.pumpWidget(const ShellApp(
        title: 'HERALD',
        seedColor: Color(0xff7a5c2e),
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();

      links.controller.add(Uri.parse('https://shell.test/#join=K7QX2'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(account.isCloudSignedIn, isFalse);
      expect(account.preferencesPulled.value, 0);
    });

    testWidgets('restoreSessionsFromLinks:false ignores the link',
        (tester) async {
      givenServer();
      await tester.pumpWidget(const ShellApp(
        title: 'HERALD',
        seedColor: Color(0xff7a5c2e),
        restoreSessionsFromLinks: false,
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();

      links.controller.add(Uri.parse(
          'mygame://auth#access_token=at-x&refresh_token=rt-x&expires_at=1900000000'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(account.isCloudSignedIn, isFalse);
    });

    testWidgets('a session link cold start delivers through the initial link',
        (tester) async {
      givenServer();
      links.initialLink = Uri.parse(
          'https://shell.test/#access_token=at-c&refresh_token=rt-c&expires_at=1900000000');
      await tester.pumpWidget(const ShellApp(
        title: 'HERALD',
        seedColor: Color(0xff7a5c2e),
        home: Scaffold(body: Text('splash')),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(account.isCloudSignedIn, isTrue);
    });
  });
}

class _FakeLinks extends AppLinksPlatform {
  Uri? initialLink;
  final controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriLinkStream => controller.stream;
}
