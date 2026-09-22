import 'dart:async';
import 'dart:convert';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recovery-link path: a `{{ .ConfirmationURL }}` reset email opens
/// the app as a link (or is pasted whole into the reset sub-form) and
/// signs the player back in — landing in the same forced change-password
/// state as the 6-digit code. Covered: the parser, the controller's
/// completion method, and ShellApp's delivery.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    appTheme.resetForTest();
    account.resetForTest();
  });

  group('recovery link parsing', () {
    test('the fragment token form parses with the type guard', () {
      final link = recoveryLinkFromUri(
          Uri.parse('https://shell.test/#token=123456&type=recovery'));
      expect(link, isNotNull);
      expect(link!.token, '123456');
      expect(link.tokenHash, isNull);
      expect(link.isTokenHash, isFalse);
    });

    test('the query token_hash form parses (newer GoTrue generation)', () {
      final link = recoveryLinkFromUri(Uri.parse(
          'https://shell.test/auth/callback?token_hash=abc123&type=recovery'));
      expect(link, isNotNull);
      expect(link!.tokenHash, 'abc123');
      expect(link.token, isNull);
      expect(link.isTokenHash, isTrue);
    });

    test('a mobile app-link delivery with a stripped # still parses', () {
      final link = recoveryLinkFromUri(
          Uri.parse('mygame://reset?token=123456&type=recovery'));
      expect(link!.token, '123456');
    });

    test('type=recovery is mandatory', () {
      expect(recoveryLinkFromUri(Uri.parse('https://shell.test/#token=123456')),
          isNull);
      expect(
          recoveryLinkFromUri(
              Uri.parse('https://shell.test/?token_hash=x&type=signup')),
          isNull);
      expect(
          recoveryLinkFromUri(
              Uri.parse('https://shell.test/?token_hash=x&type=magiclink')),
          isNull);
    });

    test('both spellings at once is malformed, not richer', () {
      expect(
          recoveryLinkFromUri(Uri.parse(
              'https://shell.test/?token=a&token_hash=b&type=recovery')),
          isNull);
    });

    test('a token without a value is no link at all', () {
      expect(
          recoveryLinkFromUri(
              Uri.parse('https://shell.test/?token=&type=recovery')),
          isNull);
    });

    test('join links and OAuth fragments never parse as recovery links', () {
      expect(
          recoveryLinkFromUri(Uri.parse('https://x.game/#join=K7QX2')), isNull);
      expect(
          recoveryLinkFromUri(Uri.parse(
              'https://x.game/#access_token=at&refresh_token=rt&expires_in=3600')),
          isNull);
    });

    test('a recovery link never parses as a join link either', () {
      expect(
          joinInviteFromUri(
              Uri.parse('https://x.game/#token=123456&type=recovery')),
          isNull);
    });

    test('clipboard text carries whole pasted links', () {
      final link = recoveryLinkFromClipboardText(
          '  https://shell.test/?token_hash=zz9&type=recovery  \n');
      expect(link!.tokenHash, 'zz9');
      expect(recoveryLinkFromClipboardText(null), isNull);
      expect(recoveryLinkFromClipboardText('   '), isNull);
      expect(recoveryLinkFromClipboardText('not a link at all'), isNull);
      // A fragment-only paste (no scheme) still parses.
      expect(
          recoveryLinkFromClipboardText('#token=123456&type=recovery')!.token,
          '123456');
    });
  });

  group('AccountController.completeRecoveryLink', () {
    late List<http.Request> posts;

    void givenServer({
      String email = 'back@shell.test',
      Object? Function() tokenBody = _never,
    }) {
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
                  'access_token': 'at-link',
                  'refresh_token': 'rt-link',
                  'expires_at': 1900000000,
                  'user': {'id': 'u5', 'email': email},
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    test('a token-hash link signs in without any email', () async {
      givenServer();

      await account
          .completeRecoveryLink(const RecoveryLink.tokenHash('abc123'));

      expect(account.isCloudSignedIn, isTrue);
      expect(account.passwordResetPending, isTrue);
      expect(account.recoveryInProgress, isTrue);
      final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
      expect(body, {'type': 'recovery', 'token_hash': 'abc123'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'), isNotNull);
    });

    test('a plain-token link rides the parked reset email (pasted link)',
        () async {
      givenServer();
      await account.parkPasswordReset('lost@shell.test');

      await account.completeRecoveryLink(const RecoveryLink.token('123456'));

      expect(account.isCloudSignedIn, isTrue);
      expect(account.passwordResetPending, isTrue);
      final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
      expect(body,
          {'type': 'recovery', 'email': 'lost@shell.test', 'token': '123456'});
      // The reset is consumed, exactly like the code path.
      expect(account.pendingResetEmail, isNull);
    });

    test('a plain-token link without a parked email explains itself', () async {
      givenServer();

      await expectLater(
        account.completeRecoveryLink(const RecoveryLink.token('123456')),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'recovery_email_unknown')),
      );
      expect(account.isCloudSignedIn, isFalse);
      expect(posts, isEmpty);
    });

    test('a failed verification leaves the state untouched', () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/verify')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'otp_expired',
                  'msg': 'Recovery link expired',
                }),
                401);
          }
          return http.Response('unexpected', 404);
        }),
      );

      await expectLater(
        account.completeRecoveryLink(const RecoveryLink.tokenHash('stale')),
        throwsA(
            isA<AuthException>().having((e) => e.code, 'code', 'otp_expired')),
      );
      expect(account.isCloudSignedIn, isFalse);
    });

    test('the completed session clears on changePassword, as recovery does',
        () async {
      givenServer();
      await account
          .completeRecoveryLink(const RecoveryLink.tokenHash('abc123'));

      // The forced form guards sign-out...
      await expectLater(
        account.signOut(),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'reset_in_progress')),
      );
      // ...until a new password lands.
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await account.changePassword('brand-new-7');
      expect(account.passwordResetPending, isFalse);
      expect(account.recoveryInProgress, isFalse);
    });
  });

  group('ShellApp recovery delivery', () {
    final links = _FakeLinks();
    final originalPlatform = AppLinksPlatform.instance;

    setUp(() {
      AppLinksPlatform.instance = links;
      links.initialLink = null;
    });
    tearDown(() => AppLinksPlatform.instance = originalPlatform);

    Future<void> pumpShell(
        WidgetTester tester, List<RecoveryLink> delivered) async {
      await tester.pumpWidget(ShellApp(
        title: 'HERALD',
        seedColor: const Color(0xff7a5c2e),
        onRecoveryLink: delivered.add,
        home: const Scaffold(body: Text('splash')),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a cold-start recovery link reaches the handler once',
        (tester) async {
      links.initialLink =
          Uri.parse('https://shell.test/#token=123456&type=recovery');
      final delivered = <RecoveryLink>[];
      await pumpShell(tester, delivered);

      expect(delivered, hasLength(1));
      expect(delivered.single.token, '123456');
    });

    testWidgets('a warm return with a token_hash link arrives too',
        (tester) async {
      final delivered = <RecoveryLink>[];
      await pumpShell(tester, delivered);

      links.controller
          .add(Uri.parse('mygame://reset?token_hash=zz9&type=recovery'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(delivered, hasLength(1));
      expect(delivered.single.tokenHash, 'zz9');
    });

    testWidgets('a join link never fires the recovery handler', (tester) async {
      links.initialLink = Uri.parse('https://shell.test/#join=K7QX2');
      final delivered = <RecoveryLink>[];
      await pumpShell(tester, delivered);

      expect(delivered, isEmpty);
    });

    testWidgets('a recovery link never fires the join handler', (tester) async {
      links.initialLink =
          Uri.parse('https://shell.test/#token=123456&type=recovery');
      final joined = <Uri>[];
      await tester.pumpWidget(ShellApp(
        title: 'HERALD',
        seedColor: const Color(0xff7a5c2e),
        onJoinInvite: (invite) => joined.add(Uri.parse('join:${invite.code}')),
        home: const Scaffold(body: Text('splash')),
      ));
      await tester.pump();
      await tester.pump();

      expect(joined, isEmpty);
    });
  });
}

Object? _never() => throw StateError('not used');

class _FakeLinks extends AppLinksPlatform {
  Uri? initialLink;
  final controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriLinkStream => controller.stream;
}
