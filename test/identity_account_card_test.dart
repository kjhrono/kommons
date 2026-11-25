import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:mediasart_auth_client/mediasart_auth_client.dart' as kit;
import 'package:shared_preferences/shared_preferences.dart';

/// The shared identity account card: who is signed in and how, and the
/// Google row's sign-in-or-link rule (a signed-in member ADDS Google to the
/// same account instead of minting a second one). No network: the identity
/// client and the redirect collector are fakes.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.value = null;
  });

  group('IdentityAccountInfo.fromSession', () {
    test('no session is anonymous', () {
      final info = IdentityAccountInfo.fromSession(null);
      expect(info.signedIn, isFalse);
      expect(info.kinds, {IdentitySignInKind.anonymous});
    });

    test('reads the linked providers out of the JWT', () {
      final info = IdentityAccountInfo.fromSession(
        _session('u1', 'a@b.it', providers: ['email', 'google']),
      );
      expect(info.signedIn, isTrue);
      expect(info.email, 'a@b.it');
      expect(info.kinds, {IdentitySignInKind.email, IdentitySignInKind.google});
    });

    test('an unreadable token still counts as an email account', () {
      const s = kit.AuthSession(
        userId: 'u1',
        email: 'a@b.it',
        accessToken: 'not-a-jwt',
        refreshToken: 'r',
      );
      expect(
        IdentityAccountInfo.fromSession(s).kinds,
        {IdentitySignInKind.email},
      );
    });
  });

  group('signInOrLinkGoogle', () {
    test('signed out: adopts the Google session', () async {
      final host = _Host();
      expect(await signInOrLinkGoogle(host), GoogleAccountResult.signedIn);
      expect(host.adopted.single.userId, 'g1');
      expect(host.auth.links, isEmpty);
      expect(host.prepared, 1);
    });

    test(
        'signed in with email: links Google onto THIS account and adopts '
        'the refreshed session', () async {
      final host = _Host(current: _session('p1', 'a@b.it'));
      expect(await signInOrLinkGoogle(host), GoogleAccountResult.linked);
      expect(host.auth.links, ['p1<-g1 (a@b.it)']);
      expect(host.adopted.single.accessToken, 'refreshed-p1');
    });

    test('backed out of the Google page: nothing changes', () async {
      final host = _Host(code: null);
      expect(await signInOrLinkGoogle(host), GoogleAccountResult.cancelled);
      expect(host.adopted, isEmpty);
      expect(host.auth.links, isEmpty);
    });

    test('the PKCE pair and the redirect reach the exchange', () async {
      final host = _Host();
      await signInOrLinkGoogle(host);
      expect(host.auth.redirects, ['katalogus://auth-callback']);
      expect(host.auth.verifierSeen, isNotEmpty);
    });
  });

  group('IdentityAccountCard', () {
    Future<_Host> pump(WidgetTester tester, _Host host) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdentityAccountCard(
              host: host,
              notSignedInText: 'Works on this device only.',
            ),
          ),
        ),
      );
      await tester.pump();
      return host;
    }

    testWidgets('signed out: the sign-in doors and the host note', (
      tester,
    ) async {
      await pump(tester, _Host());
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Works on this device only.'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('account-sign-in-email')), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-sign-out')), findsNothing);
    });

    testWidgets('Google off in this build: says so instead of a button', (
      tester,
    ) async {
      await pump(tester, _Host(googleEnabled: false));
      expect(find.text('Not available yet'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('account-sign-in-google')), findsNothing);
    });

    testWidgets(
        'signed in with email: the address on the email row, and '
        'Google offered as an addition', (tester) async {
      final host = await pump(tester, _Host(current: _session('p1', 'a@b.it')));
      expect(find.text('a@b.it'), findsOneWidget);
      expect(find.text('Signed in'), findsOneWidget);
      expect(find.text('Add Google'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-sign-out')));
      expect(host.signedOut, 1);
    });

    testWidgets('both linked: two ticks, no buttons', (tester) async {
      await pump(
        tester,
        _Host(
            current: _session('p1', 'a@b.it', providers: ['email', 'google'])),
      );
      expect(find.text('Signed in'), findsNWidgets(2));
      expect(
          find.byKey(const ValueKey('account-sign-in-google')), findsNothing);
    });

    testWidgets('Add Google links, refreshes and confirms', (tester) async {
      final host = await pump(tester, _Host(current: _session('p1', 'a@b.it')));
      await tester.tap(find.text('Add Google'));
      await tester.pumpAndSettle();
      expect(host.auth.links, ['p1<-g1 (a@b.it)']);
      expect(find.text('Google added to your account'), findsOneWidget);
      // The adopted (refreshed) session lists Google now.
      expect(find.text('Signed in'), findsNWidgets(2));
    });

    testWidgets('Italian follows the app language', (tester) async {
      await appLocale.setLanguage(ShellLanguage.italiano);
      await pump(tester, _Host());
      expect(find.text('Accedi con Google'), findsOneWidget);
      expect(find.text('Accedi'), findsOneWidget);
    });
  });
  group('change password', () {
    Future<_Host> open(WidgetTester tester, List<String> providers) async {
      final host =
          _Host(current: _session('u1', 'a@b.it', providers: providers));
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: IdentityAccountCard(host: host))));
      return host;
    }

    testWidgets('only accounts with a password get the button', (tester) async {
      await open(tester, ['google']);
      expect(
          find.byKey(const ValueKey('account-change-password')), findsNothing);
      await open(tester, ['email', 'google']);
      expect(find.byKey(const ValueKey('account-change-password')),
          findsOneWidget);
    });

    testWidgets('checks the repeat, refuses weak, adopts the rotated session',
        (tester) async {
      final host = await open(tester, ['email']);
      await tester.tap(find.byKey(const ValueKey('account-change-password')));
      await tester.pumpAndSettle();

      Future<void> submit(String a, String b) async {
        await tester.enterText(
            find.byKey(const ValueKey('account-new-password')), a);
        await tester.enterText(
            find.byKey(const ValueKey('account-confirm-password')), b);
        await tester
            .tap(find.byKey(const ValueKey('account-change-password-save')));
        await tester.pumpAndSettle();
      }

      await submit('longer-pass', 'different');
      expect(find.text('The two passwords differ.'), findsOneWidget);
      await submit('abc', 'abc');
      expect(find.textContaining('Too short'), findsOneWidget);
      await submit('longer-pass', 'longer-pass');
      expect(host.auth.passwords, ['longer-pass']);
      expect(host.adopted.single.refreshToken, 'rotated');
      expect(find.text('Password changed'), findsOneWidget);
    });
  });
}

/// A session whose JWT carries [providers] in `app_metadata`.
kit.AuthSession _session(
  String id,
  String email, {
  List<String> providers = const ['email'],
  String? accessToken,
}) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final jwt = '${b64({'alg': 'none'})}.'
      '${b64({
        'sub': id,
        'app_metadata': {'providers': providers},
      })}.sig';
  return kit.AuthSession(
    userId: id,
    email: email,
    accessToken: accessToken ?? jwt,
    refreshToken: 'r-$id',
  );
}

class _Host extends IdentityAccountHost {
  _Host({this.current, this.code = 'the-code', this.googleEnabled = true});

  kit.AuthSession? current;
  final String? code;
  @override
  final bool googleEnabled;

  @override
  final _FakeAuth auth = _FakeAuth();
  final adopted = <kit.AuthSession>[];
  final _changes = StreamController<Object?>.broadcast();
  int prepared = 0;
  int signedOut = 0;

  @override
  String get oauthRedirectTo => 'katalogus://auth-callback';

  @override
  String get resetRedirectTo => 'https://example.test/#/reset';

  @override
  kit.AuthSession? get currentSession => current;

  @override
  Stream<Object?> get sessionChanges => _changes.stream;

  @override
  Future<void> adoptSession(kit.AuthSession session) async {
    adopted.add(session);
    // What a real host does: the refreshed token now lists Google too.
    current = session.accessToken.startsWith('refreshed-')
        ? _session(
            session.userId,
            session.email,
            providers: ['email', 'google'],
          )
        : session;
    _changes.add(null);
  }

  @override
  Future<void> signOut() async {
    signedOut++;
    current = null;
    _changes.add(null);
  }

  @override
  Future<void> prepare() async => prepared++;

  @override
  Future<String?> collectCode(String authorizeUrl) async => code;
}

class _FakeAuth implements kit.MediasartAuth {
  final links = <String>[];
  final passwords = <String>[];

  @override
  Future<void> changePassword({
    required kit.AuthSession session,
    required String newPassword,
    void Function(kit.AuthSession newSession)? onSessionUpdated,
  }) async {
    if (newPassword.length < 6) {
      throw const kit.AuthCodeException('weak_password');
    }
    passwords.add(newPassword);
    onSessionUpdated?.call(kit.AuthSession(
      userId: session.userId,
      email: session.email,
      accessToken: session.accessToken,
      refreshToken: 'rotated',
    ));
  }

  final redirects = <String?>[];
  String verifierSeen = '';

  @override
  String googleOAuthUrl({
    required String redirectTo,
    required String codeChallenge,
  }) =>
      'https://auth.example.test/authorize?challenge=$codeChallenge';

  @override
  Future<kit.AuthSession> signInWithGoogleCode({
    required String code,
    required String codeVerifier,
    String? redirectTo,
  }) async {
    verifierSeen = codeVerifier;
    redirects.add(redirectTo);
    return _session('g1', 'a@b.it', providers: ['google']);
  }

  @override
  Future<bool> linkGoogleIdentity({
    required kit.AuthSession passwordSession,
    required String googleUserId,
    required String expectedEmail,
  }) async {
    links.add('${passwordSession.userId}<-$googleUserId ($expectedEmail)');
    return true;
  }

  @override
  Future<kit.AuthSession> refreshSession({
    required kit.AuthSession session,
    void Function(kit.AuthSession newSession)? onSessionUpdated,
  }) async =>
      kit.AuthSession(
        userId: session.userId,
        email: session.email,
        accessToken: 'refreshed-${session.userId}',
        refreshToken: session.refreshToken,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
