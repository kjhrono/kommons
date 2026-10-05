import 'dart:convert';

import 'package:test/test.dart';

import 'package:mediasart_auth_client/mediasart_auth_client.dart';
import 'package:mediasart_auth_client/src/http.dart';

class _Res {
  final int status;
  final dynamic body;
  const _Res(this.status, this.body);
}

/// A Poster impl that throws before answering: the network seam.
class _ExplodingPoster implements PosterImpl {
  @override
  Future<PostResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    throw Exception('connection refused');
  }
}

/// Scripted Poster impl: answers from a queue, records every call.
class ScriptedPoster implements PosterImpl {
  final calls = <({String method, Uri url, Map<String, String> headers, String body})>[];
  final responses = <_Res>[];

  void expectNoMoreTraffic() => expect(responses, isEmpty,
      reason: 'scripted responses all consumed');

  @override
  Future<PostResponse> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    calls.add((method: method, url: url, headers: headers, body: body));
    if (responses.isEmpty) return const PostResponse(500, '{"error":"no_script"}');
    final r = responses.removeAt(0);
    return PostResponse(r.status, jsonEncode(r.body));
  }
}

void main() {
  const url = 'https://katalogus.mediasart.com';
  const key = 'anon-key';
  late ScriptedPoster poster;
  late MediasartAuth auth;

  setUp(() {
    poster = ScriptedPoster();
    Poster.impl = poster;
    auth = MediasartAuth(supabaseUrl: url, anonKey: key);
  });

  test('requestCode posts the request action with the anon key', () async {
    poster.responses.add(const _Res(200, {'sent': true}));

    await auth.requestCode('User@Example.com');

    final call = poster.calls.single;
    expect(call.url.path, contains('/functions/v1/email-verification'));
    expect(call.headers['apikey'], key);
    final body = jsonDecode(call.body) as Map<String, dynamic>;
    expect(body['action'], 'request');
    expect(body['email'], 'User@Example.com'); // passed through; server normalizes
  });

  test('verifyCode succeeds on 200', () async {
    poster.responses.add(const _Res(200, {'verified': true}));

    await auth.verifyCode('user@example.com', '123456');

    final body = jsonDecode(poster.calls.single.body) as Map<String, dynamic>;
    expect(body['action'], 'verify');
    expect(body['code'], '123456');
  });

  test('verifyCode maps invalid code with attempts left', () async {
    poster.responses.add(const _Res(400, {'error': 'code_invalid', 'attempts_left': 3}));

    await expectLater(
      auth.verifyCode('user@example.com', '000000'),
      throwsA(
        isA<AuthCodeException>()
            .having((e) => e.reason, 'reason', 'invalid')
            .having((e) => e.attemptsLeft, 'attemptsLeft', 3),
      ),
    );
  });

  test('error mapping: locked / expired / no_pending / rate_limited / unauthorized', () async {
    final cases = <(String, int, String)>[
      ('code_locked', 400, 'locked'),
      ('token_expired', 400, 'expired'),
      ('no_pending_reset', 400, 'no_pending'),
      ('rate_limited', 429, 'rate_limited'),
      ('user_mismatch', 403, 'unauthorized'),
    ];
    for (final (serverReason, status, clientReason) in cases) {
      poster.responses.clear();
      poster.responses.add(_Res(status, {'error': serverReason}));
      await expectLater(
        auth.verifyCode('user@example.com', '000000'),
        throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', clientReason)),
        reason: '$serverReason should map to $clientReason',
      );
    }
  });

  test('requestReset posts https redirect target', () async {
    poster.responses.add(const _Res(200, {'sent': true}));

    await auth.requestReset(
      email: 'user@example.com',
      redirectTo: 'https://katalogus.mediasart.com/reset',
    );

    final body = jsonDecode(poster.calls.single.body) as Map<String, dynamic>;
    expect(body['action'], 'request');
    expect(body['redirect_to'], 'https://katalogus.mediasart.com/reset');
  });

  test('completeReset (production path) forces mustChangePassword', () async {
    poster.responses.add(const _Res(200, {'temp_password_sent': true}));

    final result = await auth.completeReset(email: 'user@example.com', token: 'tok');

    expect(result.mustChangePassword, isTrue);
    expect(result.tempPasswordKnownToApp, isFalse);
    expect(result.session, isNull);
    expect(jsonDecode(poster.calls.single.body)['action'], 'confirm');
  });

  test('completeReset (assisted path) signs in with the fetched temp password', () async {
    poster.responses.addAll([
      const _Res(200, {'temp_password_sent': true}),
      const _Res(200, {
        'access_token': 'at',
        'refresh_token': 'rt',
        'user': {'id': 'u1', 'email': 'user@example.com'},
      }),
    ]);

    final result = await auth.completeReset(
      email: 'user@example.com',
      token: 'tok',
      fetchTempPassword: () async => 'temp-pass-12',
      pollInterval: const Duration(milliseconds: 1),
      timeout: const Duration(seconds: 2),
    );

    expect(result.tempPasswordKnownToApp, isTrue);
    expect(result.session?.accessToken, 'at');
    expect(result.session?.refreshToken, 'rt');
    expect(poster.calls[1].url.path, contains('/auth/v1/token'));
    expect(jsonDecode(poster.calls[1].body)['password'], 'temp-pass-12');
  });

  test('completeReset times out when the temp password never arrives', () async {
    poster.responses.add(const _Res(200, {'temp_password_sent': true}));

    await expectLater(
      auth.completeReset(
        email: 'user@example.com',
        token: 'tok',
        fetchTempPassword: () async => null,
        pollInterval: const Duration(milliseconds: 1),
        timeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', 'temp_password_timeout')),
    );
  });

  test('changePassword updates then refreshes the session', () async {
    poster.responses.addAll([
      const _Res(200, {}), // PUT /auth/v1/user
      const _Res(200, { // refresh grant
        'access_token': 'at2',
        'refresh_token': 'rt2',
        'user': {'id': 'u1', 'email': 'user@example.com'},
      }),
    ]);

    AuthSession? saved;
    await auth.changePassword(
      session: const AuthSession(
        userId: 'u1',
        email: 'user@example.com',
        accessToken: 'at',
        refreshToken: 'rt',
      ),
      newPassword: 'new-pass-99',
      onSessionUpdated: (s) => saved = s,
    );

    expect(saved?.accessToken, 'at2');
    expect(saved?.refreshToken, 'rt2');
    expect(poster.calls[0].method, 'PUT');
    expect(poster.calls[0].url.path, contains('/auth/v1/user'));
    expect(jsonDecode(poster.calls[0].body)['password'], 'new-pass-99');
    expect(poster.calls[1].url.path, contains('/token'));
    expect(jsonDecode(poster.calls[1].body)['refresh_token'], 'rt');
  });

  test('weak password surfaces as weak_password', () async {
    poster.responses.add(const _Res(422, {'msg': 'weak'}));

    await expectLater(
      auth.changePassword(
        session: const AuthSession(
          userId: 'u1', email: 'user@example.com', accessToken: 'at', refreshToken: 'rt',
        ),
        newPassword: 'short',
      ),
      throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', 'weak_password')),
    );
  });

  test('notifyPasswordChanged sends the bearer and user id', () async {
    poster.responses.add(const _Res(200, {'notified': true}));

    await auth.notifyPasswordChanged(
      session: const AuthSession(
        userId: 'u1',
        email: 'user@example.com',
        accessToken: 'at',
        refreshToken: 'rt',
      ),
    );

    expect(poster.calls.single.headers['authorization'], 'Bearer at');
    expect(jsonDecode(poster.calls.single.body)['user_id'], 'u1');
  });

  group('ban detection', () {
    // Real-shape JWT (unverified signature is fine — the client only
    // decodes claims AFTER the stack answered 200).
    String jwtWith(Map<String, dynamic> claims) {
      String b64(Map<String, dynamic> j) =>
          base64Url.encode(utf8.encode(jsonEncode(j)));
      return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64(claims)}.sig';
    }

    Map<String, dynamic> sessionBody(String jwt) => {
          'access_token': jwt,
          'refresh_token': 'rt',
          'user': {'id': 'u1', 'email': 'user@example.com'},
        };

    test('signIn returns the session for a claim-free token', () async {
      poster.responses
          .add(_Res(200, sessionBody(jwtWith({'sub': 'u1', 'role': 'authenticated'}))));

      final s = await auth.signIn(email: 'user@example.com', password: 'pw');

      expect(s.userId, 'u1');
      expect(poster.calls.single.url.path, contains('/auth/v1/token'));
      expect(jsonDecode(poster.calls.single.body)['email'], 'user@example.com');
    });

    test('signIn surfaces a NATIVE ban (auth plane) as AuthBannedException', () async {
      poster.responses.add(const _Res(400,
          {'error_code': 'user_banned', 'msg': 'User is banned'}));

      await expectLater(
        auth.signIn(email: 'user@example.com', password: 'pw'),
        throwsA(isA<AuthBannedException>()
            .having((e) => e.reason, 'reason', 'banned')
            .having((e) => e.bannedUntil, 'bannedUntil', isNull)),
      );
    });

    test('signIn surfaces a LIVE kit_banned_until claim (data plane)', () async {
      poster.responses.add(_Res(200, sessionBody(jwtWith({
        'sub': 'u1',
        'role': 'authenticated',
        'kit_banned_until': '2035-01-01T00:00:00Z',
      }))));

      await expectLater(
        auth.signIn(email: 'user@example.com', password: 'pw'),
        throwsA(isA<AuthBannedException>()
            .having((e) => e.bannedUntil, 'bannedUntil', '2035-01-01T00:00:00Z')),
      );
    });

    test('an EXPIRED kit_banned_until claim does not deny', () async {
      poster.responses.add(_Res(200, sessionBody(jwtWith({
        'sub': 'u1',
        'role': 'authenticated',
        'kit_banned_until': '2020-01-01T00:00:00Z',
      }))));

      final s = await auth.signIn(email: 'user@example.com', password: 'pw');
      expect(s.userId, 'u1');
    });

    test('plain invalid credentials stay AuthCodeException, not banned', () async {
      poster.responses.add(const _Res(400,
          {'error_code': 'invalid_credentials', 'msg': 'Invalid login credentials'}));

      await expectLater(
        auth.signIn(email: 'user@example.com', password: 'wrong'),
        throwsA(isA<AuthCodeException>()
            .having((e) => e.reason, 'reason', 'invalid_credentials')
            .having((e) => e is AuthBannedException, 'not a ban', isFalse)),
      );
    });

    test('refreshSession surfaces a native ban (the refresh token is dead)', () async {
      poster.responses.add(const _Res(400,
          {'error_code': 'user_banned', 'msg': 'User is banned'}));

      await expectLater(
        auth.refreshSession(
          session: const AuthSession(
            userId: 'u1', email: 'user@example.com', accessToken: 'at', refreshToken: 'rt',
          ),
        ),
        throwsA(isA<AuthBannedException>()),
      );
    });

    test('refreshSession checks the live claim on the rotated token', () async {
      poster.responses.add(_Res(200, sessionBody(jwtWith({
        'sub': 'u1',
        'role': 'authenticated',
        'kit_banned_until': '2035-01-01T00:00:00Z',
      }))));

      await expectLater(
        auth.refreshSession(
          session: const AuthSession(
            userId: 'u1', email: 'user@example.com', accessToken: 'at', refreshToken: 'rt',
          ),
        ),
        throwsA(isA<AuthBannedException>()
            .having((e) => e.bannedUntil, 'bannedUntil', '2035-01-01T00:00:00Z')),
      );
    });
  });

  group('google identity linking', () {
    const passwordSession = AuthSession(
      userId: 'u-password',
      email: 'member@example.com',
      accessToken: 'pw-at',
      refreshToken: 'pw-rt',
    );

    Future<bool> link() => auth.linkGoogleIdentity(
          passwordSession: passwordSession,
          googleUserId: '11111111-2222-3333-4444-555555555555',
          expectedEmail: 'member@example.com',
        );

    test('posts the RPC with the member JWT as bearer and the three args', () async {
      // A `returns boolean` RPC answers with the bare JSON boolean.
      poster.responses.add(const _Res(200, true));

      final linked = await link();

      expect(linked, isTrue);
      final call = poster.calls.single;
      expect(call.url.path, contains('/rest/v1/rpc/auth_kit_link_google_identity'));
      expect(call.headers['authorization'], 'Bearer pw-at');
      expect(call.headers['apikey'], key);
      final body = jsonDecode(call.body) as Map<String, dynamic>;
      expect(body['p_password_session'], 'pw-at');
      expect(body['p_google_user_id'], '11111111-2222-3333-4444-555555555555');
      expect(body['p_expected_email'], 'member@example.com');
    });

    test('false result means the idempotent replay (already linked)', () async {
      poster.responses.add(const _Res(200, false));

      expect(await link(), isFalse);
    });

    test('SQL refusals map to typed reasons', () async {
      final cases = <(String, String)>[ // (SQL message, client reason)
        ('invalid_session', 'unauthorized'),
        ('password_account_missing', 'unauthorized'),
        ('google_identity_missing', 'google_identity_missing'),
        ('google_email_missing', 'server'),
        ('email_mismatch', 'email_mismatch'),
        ('identity_owned_elsewhere', 'identity_conflict'),
      ];
      for (final (sqlMessage, reason) in cases) {
        poster.responses.clear();
        poster.responses.add(_Res(400, {'message': sqlMessage, 'code': 'P0001'}));
        await expectLater(
          link(),
          throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', reason)),
          reason: '$sqlMessage should map to $reason',
        );
      }
    });

    test('gateway refusals (stale JWT, missing grant) are unauthorized', () async {
      poster.responses
          .add(const _Res(401, {'message': 'JWT expired', 'code': 'PGRST301'}));
      await expectLater(
        link(),
        throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', 'unauthorized')),
      );

      poster.responses.clear();
      poster.responses.add(const _Res(404,
          {'message': 'function not found', 'code': 'PGRST202'}));
      await expectLater(
        link(),
        throwsA(isA<AuthCodeException>()
            .having((e) => e.reason, 'reason', 'server')
            .having((e) => e.detail, 'detail', 'missing_rpc')),
      );
    });

    test('network failure maps to the network reason', () async {
      Poster.impl = _ExplodingPoster();
      await expectLater(
        link(),
        throwsA(isA<AuthCodeException>().having((e) => e.reason, 'reason', 'network')),
      );
    });
  });
}
