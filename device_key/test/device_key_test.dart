import 'package:device_key/device_key.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kommons/device_key');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('asks the platform for the key by alias', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'publicKey' ? 'SPKI' : true;
    });
    const key = DeviceKey(alias: 'a');
    expect(await key.publicKey(), 'SPKI');
    expect(await key.isHardwareBacked(), isTrue);
    expect(calls.map((c) => c.arguments), everyElement({'alias': 'a'}));
  });

  test('unsupported platforms have no key', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await const DeviceKey().publicKey(), isNull);
    expect(await const DeviceKey().isHardwareBacked(), isFalse);
  });
}
