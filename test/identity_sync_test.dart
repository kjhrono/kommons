import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:mediasart_auth_client/mediasart_auth_client.dart' as kit;
import 'package:shared_preferences/shared_preferences.dart';

String _jwt(Map<String, dynamic> claims) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}

kit.AuthSession _session(
  String userId, {
  Map<String, dynamic> userMetadata = const {},
  Map<String, dynamic> appMetadata = const {
    'providers': ['google']
  },
}) =>
    kit.AuthSession(
      userId: userId,
      email: '$userId@example.test',
      accessToken: _jwt({
        'sub': userId,
        'user_metadata': userMetadata,
        'app_metadata': appMetadata,
      }),
      refreshToken: 'rt-$userId',
    );

class _Host extends IdentityAccountHost {
  _Host(this.current);

  kit.AuthSession? current;
  final _changes = StreamController<Object?>.broadcast();

  /// What the next refresh returns (a purchase landing server-side).
  kit.AuthSession? nextRefresh;

  @override
  late final kit.MediasartAuth auth = _Auth(this);

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
  _Auth(this.host);
  final _Host host;

  @override
  String get supabaseUrl => 'https://identity.test';
  @override
  String get anonKey => 'anon';

  @override
  Future<kit.AuthSession> refreshSession({
    required kit.AuthSession session,
    void Function(kit.AuthSession newSession)? onSessionUpdated,
  }) async {
    final next = host.nextRefresh;
    if (next == null) throw Exception('offline');
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A GoTrue `/user` endpoint holding [metadata], recording PUTs.
class _Server {
  _Server(this.metadata);
  Map<String, dynamic> metadata;
  final puts = <Map<String, dynamic>>[];

  AuthService get service => AuthService(
        serverUrl: 'https://identity.test',
        apiKey: 'anon',
        client: MockClient((request) async {
          expect(request.url.path, '/auth/v1/user');
          if (request.method == 'PUT') {
            final data = (jsonDecode(request.body) as Map)['data']
                as Map<String, dynamic>;
            puts.add(data);
            metadata = data;
            return http.Response('{}', 200);
          }
          return http.Response(
              jsonEncode({
                'id': 'u1',
                'email': 'u1@example.test',
                'user_metadata': metadata,
              }),
              200);
        }),
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appTheme.resetForTest();
    appLocale.resetForTest();
  });

  group('identity host preference sync', () {
    test('sign-in pulls the account name and avatar', () async {
      final server = _Server({
        'full_name': 'Marco Sartori',
        'avatar_url': 'https://lh3.example/p',
        'kommons': {
          'playerName': 'Marcuz',
          'avatar': 'preset:bolt',
          'updatedAt': {'playerName': 1900000000, 'avatar': 1900000000},
        },
      });
      account.identityAuthService = server.service;
      final host = _Host(_session('u1',
          userMetadata: {'avatar_url': 'https://lh3.example/p'}));

      account.attachIdentityHost(host);
      await account.debugFlushPendingPreferencePushes();

      expect(account.hasSyncedAccount, isTrue);
      expect(account.playerName, 'Marcuz');
      expect(account.avatar?.token, 'preset:bolt');
      expect(account.providerPhotoUrl, 'https://lh3.example/p');

      final identity = ShellIdentityHostIdentity(host);
      addTearDown(identity.dispose);
      expect(identity.value.name, 'Marcuz');
      expect(identity.value.avatar?.token, 'preset:bolt');
    });

    test('settings edits push to the identity account', () async {
      final server = _Server({
        'full_name': 'Marco Sartori',
        'other': 'kept',
      });
      account.identityAuthService = server.service;
      account.attachIdentityHost(_Host(_session('u1')));
      await account.debugFlushPendingPreferencePushes();
      server.puts.clear();

      await account.setPlayerName('Marco');
      await account.setAvatar(ShellAvatar.provider);
      await pumpEventQueue(); // the edits queue their push asynchronously
      await account.debugFlushPendingPreferencePushes();

      expect(server.puts, hasLength(1));
      final pushed = server.puts.single;
      expect(pushed['other'], 'kept'); // other metadata survives
      expect(pushed['kommons']['playerName'], 'Marco');
      expect(pushed['kommons']['avatar'], 'provider');
    });

    test('signed out of the identity host: edits stay local', () async {
      final server = _Server({});
      account.identityAuthService = server.service;
      final host = _Host(null);
      account.attachIdentityHost(host);

      await account.setPlayerName('Offline');
      await pumpEventQueue();
      await account.debugFlushPendingPreferencePushes();
      expect(account.hasSyncedAccount, isFalse);
      expect(server.puts, isEmpty);
    });
  });
}
