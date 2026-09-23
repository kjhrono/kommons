import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The password flows: the reset email ("forgot password"), the recovery
/// code that signs the player back in with a session that must choose a
/// new password, and the plain change-password call — driven at the
/// service, controller and settings-screen levels.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
    account.resetForTest();
  });

  group('AuthService password endpoints', () {
    test('resetPassword posts the email to /recover', () async {
      late http.Request captured;
      final service = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      await service.resetPassword(email: 'lost@shell.test');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/auth/v1/recover');
      expect(jsonDecode(captured.body), {'email': 'lost@shell.test'});
      expect(captured.headers['apikey'], 'k');
    });

    test('resetPassword maps a server error to a typed AuthException',
        () async {
      final service = AuthService(
        serverUrl: 'https://shell.test',
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'error_code': 'over_email_send_rate_limit',
              'msg': 'Too many emails'
            }),
            422)),
      );

      await expectLater(
        service.resetPassword(email: 'lost@shell.test'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'over_email_send_rate_limit')
            .having((e) => e.message, 'message', 'Too many emails')),
      );
    });

    test('verifyRecovery posts type=recovery and returns the session',
        () async {
      late http.Request captured;
      final service = AuthService(
        serverUrl: 'https://shell.test',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
              jsonEncode({
                'access_token': 'a',
                'refresh_token': 'r',
                'expires_at': 1900000000,
                'user': {'id': 'u7', 'email': 'lost@shell.test'},
              }),
              200);
        }),
      );

      final session = await service.verifyRecovery(
          email: 'lost@shell.test', token: '123456');

      expect(captured.url.path, '/auth/v1/verify');
      expect(jsonDecode(captured.body), {
        'type': 'recovery',
        'email': 'lost@shell.test',
        'token': '123456',
      });
      expect(session.userId, 'u7');
      expect(session.email, 'lost@shell.test');
    });

    test('updatePassword PUTs the new password with the bearer token',
        () async {
      late http.Request captured;
      final service = AuthService(
        serverUrl: 'https://shell.test',
        client: MockClient((request) async {
          captured = request;
          return http.Response('{}', 200);
        }),
      );

      await service.updatePassword(
          accessToken: 'the-token', newPassword: 'new-secret-9');

      expect(captured.method, 'PUT');
      expect(captured.url.path, '/auth/v1/user');
      expect(captured.headers['Authorization'], 'Bearer the-token');
      expect(jsonDecode(captured.body), {'password': 'new-secret-9'});
    });
  });

  group('AccountController password flows', () {
    void givenServer() {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/recover')) {
            return http.Response('', 200);
          }
          if (request.url.path.endsWith('/auth/v1/verify')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['token'] != '123456') {
              return http.Response(
                  jsonEncode({
                    'error_code': 'otp_expired',
                    'msg': 'Invalid or expired recovery code',
                  }),
                  401);
            }
            return http.Response(
                jsonEncode({
                  'access_token': 'at-recovered',
                  'refresh_token': 'rt-recovered',
                  'expires_at': 1900000000,
                  'user': {'id': 'u7', 'email': 'lost@shell.test'},
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    test('requestPasswordReset validates the address and the server', () async {
      await expectLater(
        account.requestPasswordReset('   '),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'invalid_email')),
      );

      await expectLater(
        account.requestPasswordReset('lost@shell.test'),
        throwsA(
            isA<AuthException>().having((e) => e.code, 'code', 'no_server')),
      );

      givenServer();
      await account.requestPasswordReset('lost@shell.test');
    });

    test('verifyRecoveryCode signs in and arms the forced password change',
        () async {
      givenServer();
      await expectLater(
        account.verifyRecoveryCode('123456'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'no_reset')),
      );

      await account.parkPasswordReset('lost@shell.test');
      expect(account.pendingResetEmail, 'lost@shell.test');

      await account.verifyRecoveryCode('123456');

      expect(account.isCloudSignedIn, isTrue);
      expect(account.value!.email, 'lost@shell.test');
      expect(account.passwordResetPending, isTrue);
      expect(account.pendingResetEmail, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'), isNotNull);
    });

    test('signOut is blocked until the recovered account picks a password',
        () async {
      givenServer();
      await account.parkPasswordReset('lost@shell.test');
      await account.verifyRecoveryCode('123456');

      await expectLater(
        account.signOut(),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'reset_in_progress')),
      );
      expect(account.isCloudSignedIn, isTrue);

      await account.changePassword('brand-new-7');
      expect(account.passwordResetPending, isFalse);

      await account.signOut();
      expect(account.value, isNull);
    });

    test('changePassword without a session explains itself', () async {
      givenServer();
      await expectLater(
        account.changePassword('whatever-1'),
        throwsA(isA<AuthException>()
            .having((e) => e.code, 'code', 'not_signed_in')),
      );
    });

    test('cancelPasswordReset returns to the plain sign-in state', () async {
      givenServer();
      await account.parkPasswordReset('lost@shell.test');
      await account.cancelPasswordReset();
      expect(account.pendingResetEmail, isNull);
      await expectLater(
        account.verifyRecoveryCode('123456'),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', 'no_reset')),
      );
    });

    test('a flagged temp-password session arms the form and clears on save',
        () async {
      String flaggedSession() => jsonEncode({
            'access_token': 'at-flag',
            'refresh_token': 'rt-flag',
            'expires_at': 1900000000,
            'user': {
              'id': 'u7',
              'email': 'temp@shell.test',
              'user_metadata': {'must_change_password': true},
            },
          });

      var clearedMetadata = false;
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
            return http.Response(flaggedSession(), 200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            expect(request.method, 'PUT');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(
                (body['data'] as Map<String, dynamic>)['must_change_password'],
                isNull);
            clearedMetadata = true;
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );

      await account.signInWithPassword('temp@shell.test', 'temp-pass-1');
      expect(account.isCloudSignedIn, isTrue);
      expect(account.mustChangePassword, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.session'),
          contains('must_change_password'));

      // Unlike recovery, sign-out stays available — the player knows this
      // temporary password, they just shouldn't keep it.
      await account.signOut();
      expect(account.value, isNull);

      // Sign back in and change it: the flag clears locally and server-side
      // in the same PUT.
      await account.signInWithPassword('temp@shell.test', 'temp-pass-1');
      await account.changePassword('brand-new-7');
      expect(clearedMetadata, isTrue);
      expect(account.mustChangePassword, isFalse);
      expect(account.passwordResetPending, isFalse);
    });
  });

  group('Settings screen password forms', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: const SettingsScreen(),
      ));
      await tester.pump();
    }

    void givenServer() {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/recover')) {
            return http.Response('', 200);
          }
          if (request.url.path.endsWith('/auth/v1/verify')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['token'] != '123456') {
              return http.Response(
                  jsonEncode({
                    'error_code': 'otp_expired',
                    'msg': 'Invalid or expired recovery code',
                  }),
                  401);
            }
            return http.Response(
                jsonEncode({
                  'access_token': 'at-recovered',
                  'refresh_token': 'rt-recovered',
                  'expires_at': 1900000000,
                  'user': {'id': 'u7', 'email': 'lost@shell.test'},
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response('{}', 200);
          }
          if (request.url.path.endsWith('/auth/v1/signup')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'user_already_registered',
                  'msg': 'User already registered',
                }),
                422);
          }
          if (request.url.path.endsWith('/auth/v1/token')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body['password'] != 'the-old-8') {
              return http.Response(
                  jsonEncode({
                    'error_code': 'invalid_grant',
                    'msg': 'Invalid login credentials',
                  }),
                  400);
            }
            return http.Response(
                jsonEncode({
                  'access_token': 'at-recovered',
                  'refresh_token': 'rt-recovered',
                  'expires_at': 1900000000,
                  'user': {'id': 'u7', 'email': 'lost@shell.test'},
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );
    }

    testWidgets('forgot password → code → forced change, end to end',
        (tester) async {
      givenServer();
      await pumpSettings(tester);

      await tester.enterText(
          find.byKey(const ValueKey('email-field')), 'lost@shell.test');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('forgot-password')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forgot-password')));
      await tester.pumpAndSettle();

      // The reset sub-form replaced the sign-in form.
      expect(find.byKey(const ValueKey('reset-code-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('email-field')), findsNothing);
      expect(find.textContaining('lost@shell.test'), findsWidgets);

      // A wrong code surfaces the server's message and keeps the form.
      await tester.enterText(
          find.byKey(const ValueKey('reset-code-field')), '000000');
      await tester.tap(find.byKey(const ValueKey('verify-reset')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reset-code-field')), findsOneWidget);

      // Retire the error snackbar so it can't cover the next tap target.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // The right code signs in and forces the change-password form.
      await tester.enterText(
          find.byKey(const ValueKey('reset-code-field')), '123456');
      await tester.tap(find.byKey(const ValueKey('verify-reset')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('confirm-password-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('signout')), findsNothing);
      expect(account.isCloudSignedIn, isTrue);
      expect(account.passwordResetPending, isTrue);

      // The completion notice fired: retire it before the next snackbar
      // step (snackbars queue one at a time).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // Mismatched passwords are rejected inline.
      await tester.enterText(
          find.byKey(const ValueKey('new-password-field')), 'brand-new-7');
      await tester.enterText(
          find.byKey(const ValueKey('confirm-password-field')), 'different-9');
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      expect(find.text(appLocale.strings.passwordMismatch), findsOneWidget);
      expect(account.passwordResetPending, isTrue);

      // Retire the mismatch snackbar before the next tap at the same spot.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // Matching passwords land: the form lifts, the normal card returns.
      await tester.enterText(
          find.byKey(const ValueKey('new-password-field')), 'brand-new-7');
      await tester.enterText(
          find.byKey(const ValueKey('confirm-password-field')), 'brand-new-7');
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();

      expect(account.passwordResetPending, isFalse);
      expect(find.byKey(const ValueKey('signout')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-password-field')), findsNothing);
    });

    testWidgets(
        'a completed recovery flow tells the player to pick a new password',
        (tester) async {
      givenServer();
      await pumpSettings(tester);

      await tester.enterText(
          find.byKey(const ValueKey('email-field')), 'lost@shell.test');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('forgot-password')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forgot-password')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('reset-code-field')), '123456');
      await tester.tap(find.byKey(const ValueKey('verify-reset')));
      await tester.pumpAndSettle();

      // The completion announces the next step, localized, and the form
      // is open right away.
      expect(
          find.text(appLocale.strings.recoveryLinkCompleted), findsOneWidget);
      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
      expect(account.passwordResetPending, isTrue);

      // Retire the notice (an in-flight snackbar outlives a tree swap in
      // the test binding) so the next screen starts from a clean sheet.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // A screen opened *after* the completion does not announce again —
      // that player gets the card's standing hint instead.
      await pumpSettings(tester);
      expect(find.text(appLocale.strings.recoveryLinkCompleted), findsNothing);
      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
    });

    testWidgets('cancel returns from the reset sub-form to sign-in',
        (tester) async {
      givenServer();
      await pumpSettings(tester);

      await tester.enterText(
          find.byKey(const ValueKey('email-field')), 'lost@shell.test');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('forgot-password')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forgot-password')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reset-code-field')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancel-reset')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('email-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('reset-code-field')), findsNothing);
      expect(account.pendingResetEmail, isNull);
    });

    testWidgets('a short new password is rejected before any call',
        (tester) async {
      givenServer();
      await pumpSettings(tester);

      // Drive the controller into the recovered state directly — the form's
      // validation is what is under test here.
      await account.parkPasswordReset('lost@shell.test');
      await account.verifyRecoveryCode('123456');
      await pumpSettings(tester);

      // The completion notice fires when the state lands (the screen listens
      // to the controller): let its show animation run, then retire it
      // before driving the form.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('new-password-field')), 'abc');
      await tester.enterText(
          find.byKey(const ValueKey('confirm-password-field')), 'abc');
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();

      expect(find.text(appLocale.strings.shortPassword), findsOneWidget);
      expect(account.passwordResetPending, isTrue);
    });

    testWidgets('change-password section: wrong current password stays put',
        (tester) async {
      givenServer();
      await pumpSettings(tester);
      // A real session through the mock — 'the-old-8' is what /token accepts.
      await account.signInWithPassword('lost@shell.test', 'the-old-8');
      await tester.pumpAndSettle();

      await tester
          .ensureVisible(find.byKey(const ValueKey('open-change-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-change-password')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('current-password-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);

      // A wrong current password surfaces the server's invalid-credentials
      // message and the form stays for a corrected attempt.
      await tester.enterText(
          find.byKey(const ValueKey('current-password-field')), 'wrong-1');
      await tester.enterText(
          find.byKey(const ValueKey('new-password-field')), 'brand-new-7');
      await tester.enterText(
          find.byKey(const ValueKey('confirm-password-field')), 'brand-new-7');
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();

      expect(find.text('Invalid login credentials'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('current-password-field')), findsOneWidget);
    });

    testWidgets(
        'change-password section: empty current password is refused first',
        (tester) async {
      givenServer();
      await pumpSettings(tester);
      await account.signInWithPassword('lost@shell.test', 'the-old-8');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open-change-password')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();

      expect(find.text(appLocale.strings.enterCurrentPassword), findsOneWidget);
    });

    testWidgets('change-password section: happy path swaps the password',
        (tester) async {
      givenServer();
      await pumpSettings(tester);
      await account.signInWithPassword('lost@shell.test', 'the-old-8');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open-change-password')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('current-password-field')), 'the-old-8');
      await tester.enterText(
          find.byKey(const ValueKey('new-password-field')), 'brand-new-7');
      await tester.enterText(
          find.byKey(const ValueKey('confirm-password-field')), 'brand-new-7');
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-new-password')));
      await tester.pumpAndSettle();

      expect(find.text(appLocale.strings.passwordChanged), findsOneWidget);
      // The form clears and the section stays open on the signed-in card.
      expect(find.text('brand-new-7'), findsNothing);
      expect(account.isCloudSignedIn, isTrue);
      expect(account.passwordResetPending, isFalse);
    });

    testWidgets('a pasted whole reset link completes the same flow',
        (tester) async {
      givenServer();
      await pumpSettings(tester);

      await tester.enterText(
          find.byKey(const ValueKey('email-field')), 'lost@shell.test');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('forgot-password')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forgot-password')));
      await tester.pumpAndSettle();

      // Paste the whole emailed link instead of its 6-digit code.
      await tester.enterText(find.byKey(const ValueKey('reset-code-field')),
          'https://shell.test/#token=123456&type=recovery');
      await tester.tap(find.byKey(const ValueKey('verify-reset')));
      await tester.pumpAndSettle();

      // Same landing as the code: signed in, forced to choose a password.
      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
      expect(account.isCloudSignedIn, isTrue);
      expect(account.passwordResetPending, isTrue);
    });

    testWidgets('a flagged temp-password session auto-opens the change form',
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
                  'access_token': 'at-t',
                  'refresh_token': 'rt-t',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u7',
                    'email': 'temp@shell.test',
                    'user_metadata': {'must_change_password': true},
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            return http.Response('{}', 200);
          }
          return http.Response('unexpected', 404);
        }),
      );
      await pumpSettings(tester);

      await tester.enterText(
          find.byKey(const ValueKey('email-field')), 'temp@shell.test');
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('password-field')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('password-field')), 'temp-pass-1');
      // The email+password sign-in lives on the cloud button; email-signin
      // is the passwordless one.
      await tester.ensureVisible(find.byKey(const ValueKey('cloud-signin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cloud-signin')));
      await tester.pumpAndSettle();

      // The section is open without any link tap, and skips the current-
      // password field: this session just proved that password.
      expect(find.byKey(const ValueKey('new-password-field')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('current-password-field')), findsNothing);
      // The flag-driven form greets with the temporary-password sentence.
      expect(find.text(appLocale.strings.changePasswordHint), findsOneWidget);
      expect(find.text(appLocale.strings.notNow), findsOneWidget);
    });
  });

  test('the password strings are catalogued in both languages', () {
    const english = ShellStrings();
    expect(english.forgotPassword, 'Forgot password?');
    expect(english.newPasswordConfirmLabel, 'Repeat the new password');
    expect(english.resetSent('a@b.co'), contains('a@b.co'));

    const italian = ShellStrings.italian();
    expect(italian.forgotPassword, 'Password dimenticata?');
    expect(italian.changePassword, 'Cambia password');
    expect(italian.resetSent('a@b.co'), contains('a@b.co'));
  });

  group('settings provenance line', () {
    testWidgets('reflects origins live', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      // The line sits below the game sections: bring it into the lazily
      // built list's viewport.
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('pref-provenance')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();

      // All defaults: every clause reads "app default".
      expect(find.byKey(const ValueKey('pref-provenance')), findsOneWidget);
      final strings = appLocale.strings;
      expect(find.textContaining(strings.prefFromDefault), findsOneWidget);

      // A local edit while the screen is open appears immediately.
      await appTheme.applySynced(ThemeMode.light); // local value, no push loop
      await account.preferenceEdited(ShellPrefKey.theme, 'light');
      await tester.pump();

      expect(
          find.textContaining('${strings.prefTheme} ${strings.prefFromDevice}'),
          findsOneWidget);
      // The other two keys are untouched: still defaults.
      expect(
          find.textContaining(
              '${strings.prefPlayerName} ${strings.prefFromDefault}'),
          findsOneWidget);
    });
  });
}
