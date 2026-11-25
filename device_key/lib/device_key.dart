import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A signing key that lives in the device's secure hardware and can never
/// be read out (Android Keystore / StrongBox, iOS Secure Enclave). Its
/// public key identifies this device: copy the app's data to another phone
/// and that phone answers with a different key.
///
/// Android and iOS only. Elsewhere (web, desktop) [publicKey] returns null.
class DeviceKey {
  const DeviceKey({this.alias = 'kommons.license'});

  /// Which key (one app can keep several).
  final String alias;

  static const _channel = MethodChannel('kommons/device_key');

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The public key as base64 X.509 SubjectPublicKeyInfo (EC P-256),
  /// creating the key on first use. Null where unsupported.
  Future<String?> publicKey() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('publicKey', {'alias': alias});
    } on MissingPluginException {
      return null;
    }
  }

  /// True when the private key sits in secure hardware (false on an iOS
  /// simulator or an Android device with a software-only Keystore).
  Future<bool> isHardwareBacked() async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('isHardwareBacked', {'alias': alias}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
