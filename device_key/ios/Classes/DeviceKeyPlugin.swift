import Flutter
import Security

/// An EC P-256 key generated INSIDE the Secure Enclave. The private key can
/// never leave it; only the public key (as SubjectPublicKeyInfo, the same
/// form Android returns) does. The simulator has no Secure Enclave: there
/// the key is a keychain key bound to this device, and isHardwareBacked
/// answers false.
public class DeviceKeyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "kommons/device_key", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DeviceKeyPlugin(), channel: channel)
  }

  // DER prefix that turns a raw X9.63 P-256 point into SubjectPublicKeyInfo.
  private static let spkiHeader: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ]

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let alias = args["alias"] as? String, !alias.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: "alias is required", details: nil))
      return
    }
    do {
      switch call.method {
      case "publicKey":
        let (key, _) = try privateKey(alias)
        guard let pub = SecKeyCopyPublicKey(key),
          let raw = SecKeyCopyExternalRepresentation(pub, nil) as Data?
        else {
          throw NSError(domain: "device_key", code: 1)
        }
        result((Data(DeviceKeyPlugin.spkiHeader) + raw).base64EncodedString())
      case "isHardwareBacked":
        let (_, enclave) = try privateKey(alias)
        result(enclave)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "keychain", message: "\(error)", details: nil))
    }
  }

  private func tag(_ alias: String) -> Data { "kommons.device_key.\(alias)".data(using: .utf8)! }

  /// The existing key, or a new one (Secure Enclave first).
  private func privateKey(_ alias: String) throws -> (SecKey, Bool) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag(alias),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
      kSecReturnAttributes as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let attrs = item as? [String: Any],
      let ref = attrs[kSecValueRef as String]
    {
      let token = attrs[kSecAttrTokenID as String] as? String
      return (ref as! SecKey, token == (kSecAttrTokenIDSecureEnclave as String))
    }
    if let key = try? create(alias, enclave: true) { return (key, true) }
    return (try create(alias, enclave: false), false)
  }

  private func create(_ alias: String, enclave: Bool) throws -> SecKey {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        enclave ? .privateKeyUsage : [], &error)
    else { throw error!.takeRetainedValue() as Error }
    var attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag(alias),
        kSecAttrAccessControl as String: access,
      ],
    ]
    if enclave { attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw error!.takeRetainedValue() as Error
    }
    return key
  }
}
