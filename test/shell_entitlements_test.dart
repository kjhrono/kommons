import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:device_key/device_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:mediasart_auth_client/mediasart_auth_client.dart' as kit;
import 'package:shared_preferences/shared_preferences.dart';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _jwt(Map<String, dynamic> claims) =>
    '${_b64(utf8.encode('{"alg":"none"}'))}.${_b64(utf8.encode(jsonEncode(claims)))}.sig';

/// Controlled time: tokens and leases are judged against it.
DateTime _now = DateTime.utc(2026, 11, 25, 12);
int get _epoch => _now.millisecondsSinceEpoch ~/ 1000;

kit.AuthSession _session(String userId,
        {Map<String, dynamic>? entitlements,
        Map<String, dynamic>? bans,
        int ttl = 3600}) =>
    kit.AuthSession(
      userId: userId,
      email: '$userId@example.test',
      accessToken: _jwt({
        'sub': userId,
        'exp': _epoch + ttl,
        'app_metadata': {
          'providers': ['email']
        },
        if (entitlements != null) 'kit_entitlements': entitlements,
        if (bans != null) 'kit_app_bans': bans,
      }),
      refreshToken: 'rt-$userId',
    );

const _premium = {
  'katalogus': {'plan': 'premium', 'features': <String>[]},
};

class _Host extends IdentityAccountHost {
  _Host(this.current);
  kit.AuthSession? current;
  final _changes = StreamController<Object?>.broadcast();
  @override
  late final kit.MediasartAuth auth = _Auth();
  @override
  String get oauthRedirectTo => 'app://auth';
  @override
  String get resetRedirectTo => 'https://app.test/reset';
  @override
  kit.AuthSession? get currentSession => current;
  @override
  Stream<Object?> get sessionChanges => _changes.stream;
  @override
  Future<void> adoptSession(kit.AuthSession session) async {
    current = session;
    _changes.add(null);
  }

  @override
  Future<void> signOut() async {
    current = null;
    _changes.add(null);
  }
}

class _Auth implements kit.MediasartAuth {
  @override
  String get supabaseUrl => 'https://identity.test';
  @override
  String get anonKey => 'anon';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Key extends DeviceKey {
  const _Key(this.pub);
  final String? pub;
  @override
  Future<String?> publicKey() async => pub;
}

const _phoneA =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEphoneAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _phoneB =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEphoneBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

/// The license function, in memory, signing with a real Ed25519 key.
class _LicenseServer {
  _LicenseServer(this.keyPair);
  final SimpleKeyPair keyPair;
  String? holder;
  bool entitled = true;
  bool revoked = false;
  bool limitMoves = false;
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> reportReply = {'outcome': 'ok', 'revoke_local': false};

  static Future<_LicenseServer> start() async =>
      _LicenseServer(await Ed25519().newKeyPair());

  Future<String> publicKey() async =>
      base64.encode((await keyPair.extractPublicKey()).bytes);

  Future<String> sign(Map<String, dynamic> payload) async {
    final body = _b64(utf8.encode(jsonEncode(payload)));
    final sig = await Ed25519().sign(utf8.encode(body), keyPair: keyPair);
    return '$body.${_b64(sig.bytes)}';
  }

  Future<String> license(String userId, String device,
          {String plan = 'premium', int days = 14}) =>
      sign({
        'v': 1,
        'lid': 'l1',
        'sub': userId,
        'app': 'katalogus',
        'plan': plan,
        'features': <String>[],
        'dev': device,
        'iat': _epoch,
        'exp': _epoch + days * 86400,
      });

  http.Client get client => MockClient((request) async {
        expect(request.url.toString(),
            'https://identity.test/functions/v1/license');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls.add(body);
        final claims = jsonDecode(utf8.decode(base64Url.decode(
            base64Url.normalize(request.headers['authorization']!
                .split(' ')[1]
                .split('.')[1])))) as Map;
        final user = claims['sub'] as String;
        final device = body['device_key'] as String?;
        http.Response reply(int status, Object json) =>
            http.Response(jsonEncode(json), status);
        switch (body['action']) {
          case 'status':
            return reply(200, {
              'holder_label': holder == null ? null : 'Phone $holder',
              'holder_is_you': holder != null && holder == device,
              'moves_left': limitMoves ? 0 : 3,
            });
          case 'activate':
            if (!entitled) return reply(403, {'error': 'not_entitled'});
            if (limitMoves && holder != null && holder != device) {
              return reply(429, {'error': 'move_limit'});
            }
            holder = device;
            return reply(200, {
              'license': await license(user, device!),
              'moves_left': 2,
            });
          case 'renew':
            if (revoked) return reply(410, {'error': 'revoked'});
            if (holder != device) return reply(409, {'error': 'moved'});
            return reply(200, {'license': await license(user, device!)});
          case 'report':
            return reply(200, reportReply);
        }
        return reply(400, {'error': 'unknown_action'});
      });
}

Future<void> _settle(ShellEntitlements e) async {
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
    await e.ready;
  }
}

void main() {
  late _LicenseServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
    _now = DateTime.utc(2026, 11, 25, 12);
    server = await _LicenseServer.start();
  });

  Future<ShellEntitlements> entitlements(
      {String? device = _phoneA,
      String appId = 'katalogus',
      bool auto = true}) async {
    final e = ShellEntitlements(
      appId,
      licensePublicKey: await server.publicKey(),
      deviceKey: _Key(device),
      client: server.client,
      clock: () => _now,
      autoActivateFirstDevice: auto,
    );
    addTearDown(e.dispose);
    await _settle(e);
    return e;
  }

  /// Signs in on [host] and lets the app connect.
  _Host signIn(kit.AuthSession session) {
    final host = _Host(session);
    // The preference sync's metadata calls: answered, not under test here.
    account.identityAuthService = AuthService(
        serverUrl: 'https://identity.test',
        client: MockClient((_) async => http.Response('{}', 200)));
    account.attachIdentityHost(host);
    return host;
  }

  /// The device loses its connection: the token expires.
  void goOffline() => _now = _now.add(const Duration(hours: 2));

  test('online: premium per app, from the token', () async {
    signIn(_session('u1', entitlements: _premium));
    final katalogus = await entitlements(auto: false);
    final other = await entitlements(appId: 'kalcio', auto: false);
    expect(katalogus.value, ShellPlan.premium);
    expect(katalogus.source, ShellEntitlementSource.online);
    expect(katalogus.unlocks('anything'), isTrue);
    expect(other.value, ShellPlan.free);
  });

  test('online on a second device works too (no license needed)', () async {
    server.holder = _phoneA;
    signIn(_session('u1', entitlements: _premium));
    final e = await entitlements(device: _phoneB);
    expect(e.value, ShellPlan.premium);
    expect(e.offline.heldHere, isFalse);
    expect(e.offline.holderLabel, 'Phone $_phoneA');
    // Another device holds it: never taken automatically.
    expect(server.calls.where((c) => c['action'] == 'activate'), isEmpty);
  });

  test('a suspension in the token locks premium', () async {
    signIn(_session('u1', entitlements: _premium, bans: {
      'katalogus': {'level': 'suspended'}
    }));
    expect((await entitlements()).value, ShellPlan.free);
  });

  test('first device takes the license, then works offline', () async {
    signIn(_session('u1', entitlements: _premium));
    final e = await entitlements();
    expect(server.holder, _phoneA);
    expect(e.offline.heldHere, isTrue);

    goOffline();
    account.notifyListeners();
    await _settle(e);
    expect(e.value, ShellPlan.premium);
    expect(e.source, ShellEntitlementSource.offlineLicense);
  });

  group('offline license defences', () {
    Future<void> storeLicense(String token) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('prefs.license.katalogus.u1', token);
    }

    test('a license copied to another phone does nothing', () async {
      await storeLicense(await server.license('u1', _phoneA));
      signIn(_session('u1', ttl: -1)); // offline
      final e = await entitlements(device: _phoneB);
      expect(e.value, ShellPlan.free);
    });

    test('an edited license does nothing', () async {
      final token = await server.license('u1', _phoneA, plan: 'free');
      final parts = token.split('.');
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map;
      payload['plan'] = 'premium';
      await storeLicense(
          '${_b64(utf8.encode(jsonEncode(payload)))}.${parts[1]}');
      signIn(_session('u1', ttl: -1));
      expect((await entitlements()).value, ShellPlan.free);
    });

    test('a license for another account does nothing', () async {
      await storeLicense(await server.license('u2', _phoneA));
      signIn(_session('u1', ttl: -1));
      expect((await entitlements()).value, ShellPlan.free);
    });

    test('an expired lease does nothing', () async {
      await storeLicense(await server.license('u1', _phoneA, days: -1));
      signIn(_session('u1', ttl: -1));
      expect((await entitlements()).value, ShellPlan.free);
    });

    test('turning the clock back does nothing', () async {
      await storeLicense(await server.license('u1', _phoneA));
      signIn(_session('u1', ttl: -1));
      final e = await entitlements();
      expect(e.value, ShellPlan.premium);

      _now = _now.subtract(const Duration(days: 3));
      account.notifyListeners();
      await _settle(e);
      expect(e.value, ShellPlan.free);
      expect(e.offline.clockTampered, isTrue);
    });

    test('no device key (web, desktop): online only', () async {
      await storeLicense(await server.license('u1', _phoneA));
      signIn(_session('u1', ttl: -1));
      final e = await entitlements(device: null);
      expect(e.value, ShellPlan.free);
      expect(e.offline.supported, isFalse);
    });
  });

  test('back online: offline use is reported; revoke_local drops it', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'prefs.license.katalogus.u1', await server.license('u1', _phoneA));
    server.holder = _phoneA;
    final host = signIn(_session('u1', ttl: -1));
    final e = await entitlements();
    expect(e.source, ShellEntitlementSource.offlineLicense);

    server.reportReply = {'outcome': 'warned', 'revoke_local': true};
    await host.adoptSession(_session('u1')); // connected, no purchase
    await _settle(e);

    final report = server.calls.firstWhere((c) => c['action'] == 'report');
    expect(report['used'], {'plan': 'premium', 'features': <String>[]});
    expect(prefs.getString('prefs.license.katalogus.u1'), isNull);
    goOffline();
    account.notifyListeners();
    await _settle(e);
    expect(e.value, ShellPlan.free);
  });

  test('refunded: the next connection drops the license', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'prefs.license.katalogus.u1', await server.license('u1', _phoneA));
    server
      ..holder = _phoneA
      ..revoked = true;
    signIn(_session('u1')); // online, token no longer lists the purchase
    final e = await entitlements();
    expect(e.value, ShellPlan.free);
    expect(prefs.getString('prefs.license.katalogus.u1'), isNull);
  });

  test('moving to this device: allowed, then limited', () async {
    server.holder = _phoneA;
    signIn(_session('u1', entitlements: _premium));
    final e = await entitlements(device: _phoneB);
    expect(await e.activateOffline(), ShellActivateResult.activated);
    expect(server.holder, _phoneB);
    expect(e.offline.heldHere, isTrue);

    server
      ..holder = _phoneA
      ..limitMoves = true;
    expect(await e.activateOffline(), ShellActivateResult.moveLimit);
  });

  testWidgets('settings card offers to move premium here', (tester) async {
    server.holder = _phoneA;
    signIn(_session('u1', entitlements: _premium));
    late ShellEntitlements e;
    await tester.runAsync(() async => e = await entitlements(device: _phoneB));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PremiumOfflineCard(entitlements: e))));
    expect(find.text('PREMIUM'), findsOneWidget);
    expect(find.textContaining('Offline premium is on'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('premium-offline-activate')), findsOneWidget);
  });

  test('verifies a license signed by the server function (format pin)',
      () async {
    // Signed by email_auth_kit's _shared/license.ts with a throwaway key.
    const pub = 'XYCTw/0nvyrW6AicB8GaI8TbH7C8laKkCpaZD5UyPvQ=';
    const license =
        'eyJ2IjoxLCJsaWQiOiJmaXh0dXJlIiwic3ViIjoidTEiLCJhcHAiOiJrYXRhbG9ndXMiLCJwbGFuIjoicHJlbWl1bSIsImZlYXR1cmVzIjpbImV4cG9ydCJdLCJkZXYiOiJERVYiLCJpYXQiOjE3NjQwMDAwMDAsImV4cCI6NDEwMjQ0NDgwMH0'
        '.52ffeM3WHRBuG-VrdY3gkUHyhU1alvL6SgpupCeNzlnZCpzdxww_3YA8RnzRgA_NGzJF9pAzNGbkwhgqr1IwDQ';
    final payload = await verifyShellLicense(license, pub);
    expect(payload?['app'], 'katalogus');
    expect(payload?['features'], ['export']);
    expect(await verifyShellLicense(license, await server.publicKey()), isNull);
  });

  group('tamper reporting', () {
    Future<SharedPreferences> stored(String token) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('prefs.license.katalogus.u1', token);
      return prefs;
    }

    Future<String> edited() async {
      final parts =
          (await server.license('u1', _phoneA, plan: 'free')).split('.');
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map;
      payload['plan'] = 'premium';
      return '${_b64(utf8.encode(jsonEncode(payload)))}.${parts[1]}';
    }

    /// Offline with [token] stored, then connects; returns the report sent.
    Future<Map<String, dynamic>?> offlineThenOnline(String token,
        {String device = _phoneA}) async {
      final prefs = await stored(token);
      final host = signIn(_session('u1', ttl: -1));
      final e = await entitlements(device: device, auto: false);
      expect(e.value, ShellPlan.free);
      expect(prefs.getString('prefs.license.katalogus.u1'), isNull,
          reason: 'a useless license is dropped');
      await host.adoptSession(_session('u1'));
      await _settle(e);
      final reports = server.calls.where((c) => c['action'] == 'report');
      return reports.isEmpty ? null : reports.single;
    }

    test('an edited license is reported as edited', () async {
      server.reportReply = {'outcome': 'warned', 'revoke_local': true};
      final report = await offlineThenOnline(await edited());
      expect(report?['tamper'], ['edited']);
      expect(report?['used'], {'plan': 'free', 'features': <String>[]});
    });

    test('a license from another phone is reported as other_device', () async {
      final report = await offlineThenOnline(
          await server.license('u1', _phoneA),
          device: _phoneB);
      expect(report?['tamper'], ['other_device']);
    });

    test('a license for another account is other_account', () async {
      expect(
          (await offlineThenOnline(
              await server.license('u2', _phoneA)))?['tamper'],
          ['other_account']);
    });

    test('garbage is corrupt, not edited', () async {
      expect(
          (await offlineThenOnline('not-a-license'))?['tamper'], ['corrupt']);
    });

    test('a license from a retired server key is not tampering', () async {
      final old = await _LicenseServer.start();
      final prefs = await stored(await old.license('u1', _phoneA));
      signIn(_session('u1', ttl: -1));
      final e = ShellEntitlements('katalogus',
          licensePublicKey: await server.publicKey(),
          previousLicenseKeys: [await old.publicKey()],
          deviceKey: const _Key(_phoneA),
          client: server.client,
          clock: () => _now,
          autoActivateFirstDevice: false);
      addTearDown(e.dispose);
      await _settle(e);
      expect(e.value, ShellPlan.free); // waits for renewal
      expect(prefs.getString('prefs.license.katalogus.u1.tamper'), isNull);
      expect(prefs.getString('prefs.license.katalogus.u1'), isNotNull);
    });

    test('offline, the finding waits in the queue', () async {
      final prefs = await stored(await edited());
      signIn(_session('u1', ttl: -1));
      await entitlements(auto: false);
      expect(
          prefs.getString('prefs.license.katalogus.u1.tamper'), '["edited"]');
    });
  });
}
