import 'dart:async';
import 'dart:convert';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The signup-confirmation path: with the server's confirmation mail
/// enabled (autoconfirm off), a fresh registration parks in the
/// check-your-inbox state until the emailed proof lands — a 6-digit
/// code typed in, or the `{{ .ConfirmationURL }}` link opening the app
/// (cold or warm) to be confirmed straight away. Covered: the parser,
/// the service's verify calls, the controller's completion methods, and
/// ShellApp's link delivery.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
  });

  group('confirmation link parsing', () {
    test('the fragment token form parses with the type guard', () {
      final link = confirmationLinkFromUri(
          Uri.parse('https://shell.test/#token=654321&type=signup'));
      expect(link, isNotNull);
      expect(link!.token, '654321');
      expect(link.tokenHash, isNull);
      expect(link.isTokenHash, isFalse);
    });

    test('the query token_hash form parses (newer GoTrue generation)', () {
      final link = confirmationLinkFromUri(Uri.parse(
          'https://shell.test/auth/callback?token_hash=deadbeef&type=signup'));
      expect(link, isNotNull);
      expect(link!.tokenHash, 'deadbeef');
      expect(link.token, isNull);
      expect(link.isTokenHash, isTrue);
    });

    test('a mobile app-link delivery with a stripped # still parses', () {
      final link = confirmationLinkFromUri(
          Uri.parse('mygame://confirm?token=654321&type=signup'));
      expect(link, isNotNull);
      expect(link!.token, '654321');
    });

    test('a recovery link is NOT a confirmation link', () {
      expect(
        confirmationLinkFromUri(
            Uri.parse('https://shell.test/#token=123456&type=recovery')),
        isNull,
      );
      expect(
        recoveryLinkFromUri(
            Uri.parse('https://shell.test/#token=123456&type=signup')),
        isNull,
      );
    });

    test('join and OAuth links are untouched by the parser', () {
      expect(
        confirmationLinkFromUri(Uri.parse('https://shell.test/#join=K7QX2')),
        isNull,
      );
      expect(
        confirmationLinkFromUri(
            Uri.parse('https://shell.test/#access_token=at&refresh_token=rt')),
        isNull,
      );
    });

    test('both token spellings at once is malformed, not richer', () {
      expect(
        confirmationLinkFromUri(
            Uri.parse('https://shell.test/?token=1&token_hash=2&type=signup')),
        isNull,
      );
    });

    test('clipboard text parses forgivingly', () {
      expect(
        confirmationLinkFromClipboardText(
                '  https://shell.test/?token_hash=zz&type=signup  ')
            ?.tokenHash,
        'zz',
      );
      expect(
        confirmationLinkFromClipboardText('#token=42&type=signup')!.token,
        '42',
      );
      expect(confirmationLinkFromClipboardText(null), isNull);
      expect(confirmationLinkFromClipboardText('   '), isNull);
      expect(confirmationLinkFromClipboardText('not a link at all'), isNull);
    });
  });

  group('AccountController confirmation flows', () {
    late List<http.Request> posts;

    /// Points the controller at a MockClient answering `/verify` with a
    /// session (recording every POST for assertions).
    void givenServer() {
      posts = [];
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/verify')) {
            posts.add(request);
            return http.Response(
                jsonEncode({
                  'access_token': 'at-1',
                  'refresh_token': 'rt-1',
                  'user': {'id': 'u1', 'email': 'fresh@shell.test'},
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    test('a parked signup completes through the typed code', () async {
      givenServer();
      await account.parkPendingSignup('fresh@shell.test');
      await account.confirmSignupCode(' 654321 ');
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'fresh@shell.test');
      expect(account.pendingSignupEmail, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'), isNotNull);
      expect(prefs.getString('prefs.account.pendingSignup'), isNull);
      expect(posts.single.body, contains('"type":"signup"'));
      expect(posts.single.body, contains('654321'));
    });

    test('the emailed link completes via the parked email', () async {
      givenServer();
      await account.parkPendingSignup('fresh@shell.test');
      await account.completeSignupConfirmationLink(
          const ConfirmationLink.token('654321'));
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'fresh@shell.test');
      expect(posts.single.body, contains('"email":"fresh@shell.test"'));
    });

    test('the token_hash link is self-addressing (no parked email)', () async {
      givenServer();
      // Cold start on a device that never registered: the hash itself
      // addresses the account, so the flow still completes.
      await account.completeSignupConfirmationLink(
          const ConfirmationLink.tokenHash('deadbeef'));
      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'fresh@shell.test');
      expect(posts.single.body, contains('"token_hash":"deadbeef"'));
      expect(posts.single.body, isNot(contains('"email"')));
    });

    test('a plain-token link with nothing parked declines explicitly',
        () async {
      givenServer();
      await expectLater(
        account.completeSignupConfirmationLink(
            const ConfirmationLink.token('654321')),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'confirmation_email_unknown')),
      );
      expect(account.isCloudSignedIn, isFalse);
      expect(posts, isEmpty);
    });

    test('completing clears the check-your-inbox state (persisted)', () async {
      givenServer();
      await account.parkPendingSignup('fresh@shell.test');
      await account.completeSignupConfirmationLink(
          const ConfirmationLink.tokenHash('deadbeef'));
      // A fresh controller reads no parked signup back from prefs.
      final second = AccountController();
      expect(second.pendingSignupEmail, isNull);
    });
  });

  group('ShellApp confirmation delivery', () {
    final links = _FakeLinks();
    final originalPlatform = AppLinksPlatform.instance;

    setUp(() {
      AppLinksPlatform.instance = links;
      links.initialLink = null;
    });
    tearDown(() => AppLinksPlatform.instance = originalPlatform);

    Future<void> pumpShell(WidgetTester tester) async {
      await tester.pumpWidget(ShellApp(
        title: 'HERALD',
        seedColor: const Color(0xff7a5c2e),
        home: const Scaffold(body: Text('splash')),
      ));
      await tester.pump();
    }

    testWidgets('a cold-start confirmation link signs the player in',
        (tester) async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/verify')) {
            return http.Response(
                jsonEncode({
                  'access_token': 'at-1',
                  'refresh_token': 'rt-1',
                  'user': {'id': 'u1', 'email': 'fresh@shell.test'},
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await account.parkPendingSignup('fresh@shell.test');
      links.initialLink =
          Uri.parse('https://shell.test/#token=654321&type=signup');

      await pumpShell(tester);

      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'fresh@shell.test');
      expect(account.pendingSignupEmail, isNull);
    });

    testWidgets('a warm return with a token_hash link confirms too',
        (tester) async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'access_token': 'at-1',
              'refresh_token': 'rt-1',
              'user': {'id': 'u1', 'email': 'fresh@shell.test'},
            }),
            200)),
      );
      await pumpShell(tester);

      links.controller
          .add(Uri.parse('mygame://confirm?token_hash=zz9&type=signup'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'fresh@shell.test');
    });

    testWidgets('a stale link (nothing parked, plain token) stays quiet',
        (tester) async {
      var verifyCalls = 0;
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/verify')) {
            verifyCalls++;
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await pumpShell(tester);
      links.initialLink =
          Uri.parse('https://shell.test/#token=654321&type=signup');

      // Re-pump: the same cold start, now with nothing parked.
      await tester.pumpWidget(ShellApp(
        title: 'HERALD',
        seedColor: const Color(0xff7a5c2e),
        home: const Scaffold(body: Text('splash')),
      ));
      await tester.pump();
      await tester.pump();

      expect(account.isCloudSignedIn, isFalse);
      expect(verifyCalls, 0);
    });

    testWidgets('a recovery link never confirms a signup (disjoint kinds)',
        (tester) async {
      var verifyCalls = 0;
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/verify')) {
            verifyCalls++;
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await pumpShell(tester);

      links.controller
          .add(Uri.parse('https://shell.test/#token=123456&type=recovery'));
      await tester.pump();
      await tester.pump();

      // The recovery watcher has no handler here (onRecoveryLink unset),
      // so nothing happens at all — and the confirmation flow is not fed.
      expect(verifyCalls, 0);
      expect(account.isCloudSignedIn, isFalse);
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
