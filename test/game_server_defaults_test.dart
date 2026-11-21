import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The built-in server: players never type an address or key for it, and a
/// key saved for some older machine can never lock them out of it.
void main() {
  tearDown(() {
    GameServerDefaults.url = '';
    GameServerDefaults.anonKey = '';
  });

  test('without defaults or a saved server there is no connection', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await effectiveServerConnection(), isNull);
    expect(await CloudRoomService.serverConfigured(), isFalse);
  });

  test('the built-in server is used when nothing is saved', () async {
    SharedPreferences.setMockInitialValues({});
    GameServerDefaults.url = 'https://game.example.org';
    GameServerDefaults.anonKey = 'built-in-key';
    final connection = await effectiveServerConnection();
    expect(connection?.url, 'https://game.example.org');
    expect(connection?.anonKey, 'built-in-key');
    expect(await CloudRoomService.serverConfigured(), isTrue);
    expect(await storedGameServerUrl(), 'https://game.example.org');
  });

  test('a stale saved key never overrides the built-in server key', () async {
    SharedPreferences.setMockInitialValues({
      'prefs.online.serverUrl': 'https://game.example.org/',
      'prefs.online.anonKey': 'key-for-a-retired-machine',
    });
    GameServerDefaults.url = 'https://game.example.org';
    GameServerDefaults.anonKey = 'built-in-key';
    expect((await effectiveServerConnection())?.anonKey, 'built-in-key');
  });

  test('another saved server keeps its own key', () async {
    SharedPreferences.setMockInitialValues({
      'prefs.online.serverUrl': 'https://other.example.org',
      'prefs.online.anonKey': 'other-key',
    });
    GameServerDefaults.url = 'https://game.example.org';
    GameServerDefaults.anonKey = 'built-in-key';
    final connection = await effectiveServerConnection();
    expect(connection?.url, 'https://other.example.org');
    expect(connection?.anonKey, 'other-key');
  });

  test('the standard resolver hands cloud features the same connection',
      () async {
    SharedPreferences.setMockInitialValues({});
    GameServerDefaults.url = 'https://game.example.org';
    GameServerDefaults.anonKey = 'built-in-key';
    final connection = await readStandardServerConnection();
    expect(connection?.url, 'https://game.example.org');
    expect(connection?.apiKey, 'built-in-key');
  });
}
