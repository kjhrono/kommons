import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:device_key/device_key.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'identity_account_card.dart' show decodeJwtClaims;
import 'shell_top_bar.dart' show ShellPlan;

// -----------------------------------------------------------------------------
// Per-app premium, safe offline.
//
// Online (a fresh access token): the server decides. The identity stack's
// token hook puts `kit_entitlements` and `kit_app_bans` in every token, so
// any device the player signs in on gets premium while connected.
//
// Offline: only the ONE device holding a server-signed license. The license
// names this device's hardware key (DeviceKey: Keystore / Secure Enclave,
// never exportable), so editing it breaks the Ed25519 signature and copying
// it to another phone fails the key check. It lasts 14 days and renews
// whenever the device is online. Moving it to another device: 3 per 30 days.
//
// Back online, the app reports what it used offline; the server compares it
// with the purchase (warn first, suspend this app's premium on a repeat).
//
// Server side: email_auth_kit/supabase/functions/license, migration
// 20261125000000_email_auth_kit_licenses.sql. See docs/SHELL_TOP_BAR.md.
// -----------------------------------------------------------------------------

/// One app's unlock for one account.
@immutable
class ShellEntitlement {
  const ShellEntitlement(
      {this.plan = ShellPlan.free, this.features = const {}});

  static const free = ShellEntitlement();

  final ShellPlan plan;

  /// Individually bought features. A premium plan with no list unlocks
  /// every feature.
  final Set<String> features;

  bool get isPremium => plan == ShellPlan.premium;
  bool get unlocksAnything => isPremium || features.isNotEmpty;

  /// Whether [feature] is unlocked.
  bool unlocks(String feature) =>
      features.contains(feature) || (isPremium && features.isEmpty);

  Map<String, dynamic> toJson() =>
      {'plan': plan.name, 'features': features.toList()..sort()};

  static ShellEntitlement fromJson(Object? json) {
    if (json is! Map) return free;
    final features = json['features'];
    return ShellEntitlement(
      plan: json['plan'] == 'premium' ? ShellPlan.premium : ShellPlan.free,
      features: features is List ? {for (final f in features) '$f'} : const {},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShellEntitlement &&
      other.plan == plan &&
      setEquals(other.features, features);

  @override
  int get hashCode => Object.hash(plan, Object.hashAllUnordered(features));
}

/// Where the current unlock comes from.
enum ShellEntitlementSource {
  /// Nothing unlocked.
  none,

  /// A fresh token from the server (any device, while connected).
  online,

  /// This device's signed offline license.
  offlineLicense,
}

/// The offline license as the settings card shows it.
@immutable
class ShellOfflineStatus {
  const ShellOfflineStatus({
    this.supported = false,
    this.heldHere = false,
    this.expiresAt,
    this.holderLabel,
    this.movesLeft,
    this.clockTampered = false,
  });

  /// Whether this device can hold an offline license at all (Android/iOS).
  final bool supported;

  /// This device holds a valid license.
  final bool heldHere;
  final DateTime? expiresAt;

  /// The device holding it, when it is another one (from the last status).
  final String? holderLabel;
  final int? movesLeft;

  /// The device clock went backwards: the license waits for a connection.
  final bool clockTampered;
}

/// What [ShellEntitlements.activateOffline] achieved.
enum ShellActivateResult {
  activated,
  moveLimit,
  notEntitled,
  suspended,
  unsupported,
  offline,
}

/// This app's premium for the signed-in account. Pass it to
/// [ShellTopBar.plan]; ask [unlocks] before opening a paid feature.
class ShellEntitlements extends ChangeNotifier
    implements ValueListenable<ShellPlan> {
  ShellEntitlements(
    this.appId, {
    required this.licensePublicKey,
    this.previousLicenseKeys = const [],
    this.deviceLabel,
    this.autoActivateFirstDevice = true,
    AccountController? controller,
    DeviceKey? deviceKey,
    http.Client? client,
    DateTime Function()? clock,
  })  : _account = controller ?? account,
        _deviceKey = deviceKey ?? const DeviceKey(),
        _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now {
    _account.addListener(_onAccount);
    _ready = _update();
  }

  /// The app's id on the server (e.g. 'katalogus').
  final String appId;

  /// The license public key (base64 raw Ed25519, from
  /// `tool/license_keygen.ts`). Safe to embed in the app.
  final String licensePublicKey;

  /// Public keys the server signed with before a key rotation. A license
  /// signed with one of them is treated as expired (renewed at the next
  /// connection), never as edited.
  final List<String> previousLicenseKeys;

  /// How this device is named to the player on other devices.
  final String? deviceLabel;

  /// When the account has premium and no device holds the offline license
  /// yet, take it automatically (the first device). Moves are never
  /// automatic.
  final bool autoActivateFirstDevice;

  final AccountController _account;
  final DeviceKey _deviceKey;
  final http.Client _client;
  final DateTime Function() _clock;

  /// Renew when the lease has less than this left.
  static const renewBefore = Duration(days: 7);

  /// Clock rollback tolerated before offline use is refused.
  static const clockSlack = Duration(minutes: 10);

  late Future<void> _ready;
  ShellEntitlement _entitlement = ShellEntitlement.free;
  ShellEntitlementSource _source = ShellEntitlementSource.none;
  ShellOfflineStatus _offline = const ShellOfflineStatus();
  String? _lastOnlineUser;
  bool _busy = false;

  /// Completes when the current evaluation is done.
  Future<void> get ready => _ready;

  ShellEntitlement get entitlement => _entitlement;
  ShellEntitlementSource get source => _source;
  ShellOfflineStatus get offline => _offline;

  @override
  ShellPlan get value => _entitlement.plan;

  bool unlocks(String feature) => _entitlement.unlocks(feature);

  void _onAccount() => _ready = _update();

  String _licenseKey(String userId) => 'prefs.license.$appId.$userId';
  String _usedKey(String userId) => 'prefs.license.$appId.$userId.usedOffline';
  String _tamperKey(String userId) => 'prefs.license.$appId.$userId.tamper';
  static const _clockKey = 'prefs.license.maxSeen';

  // ---------------------------------------------------------------------------
  // Evaluation
  // ---------------------------------------------------------------------------

  Future<void> _update() async {
    final userId = _account.currentUserId;
    if (userId == null || userId.isEmpty) {
      _set(ShellEntitlement.free, ShellEntitlementSource.none,
          const ShellOfflineStatus());
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final now = _clock();
    final clockOk = await _checkClock(prefs, now);
    final devicePub = await _deviceKey.publicKey();

    final token = _account.currentAccessToken;
    final claims =
        token == null ? const <String, dynamic>{} : decodeJwtClaims(token);
    final tokenExp = claims['exp'];
    final fresh = clockOk &&
        tokenExp is int &&
        tokenExp * 1000 > now.millisecondsSinceEpoch;
    final suspended = claims['kit_app_bans'] is Map &&
        (claims['kit_app_bans'] as Map).containsKey(appId);

    final license = await _validLicense(prefs, userId, devicePub, now, clockOk);
    final offline = ShellOfflineStatus(
      supported: devicePub != null,
      heldHere: license != null,
      expiresAt: license == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((license['exp'] as int) * 1000),
      holderLabel: _offline.holderLabel,
      movesLeft: _offline.movesLeft,
      clockTampered: !clockOk,
    );

    if (fresh) {
      final claimed = suspended
          ? ShellEntitlement.free
          : ShellEntitlement.fromJson(
              (claims['kit_entitlements'] as Map?)?[appId]);
      _set(
          claimed,
          claimed.unlocksAnything
              ? ShellEntitlementSource.online
              : ShellEntitlementSource.none,
          offline);
      if (_lastOnlineUser != userId) {
        _lastOnlineUser = userId;
        unawaited(_onlineDuties(userId, claimed, devicePub, license));
      }
      return;
    }
    _lastOnlineUser = null;
    if (license != null) {
      final unlocked = ShellEntitlement.fromJson(license);
      _set(unlocked, ShellEntitlementSource.offlineLicense, offline);
      // Remember what was used offline, for the audit at the next connection.
      await prefs.setString(_usedKey(userId), jsonEncode(unlocked.toJson()));
      return;
    }
    _set(ShellEntitlement.free, ShellEntitlementSource.none, offline);
  }

  /// False when the clock went backwards past [clockSlack] (a rollback to
  /// stretch a lease). Records the newest time seen otherwise.
  Future<bool> _checkClock(SharedPreferences prefs, DateTime now) async {
    final seen = prefs.getInt(_clockKey) ?? 0;
    final ms = now.millisecondsSinceEpoch;
    if (ms + clockSlack.inMilliseconds < seen) return false;
    if (ms > seen) await prefs.setInt(_clockKey, ms);
    return true;
  }

  /// The stored license's payload when it is signed by the server, for this
  /// account, app and device, and not expired. Else null.
  Future<Map<String, dynamic>?> _validLicense(SharedPreferences prefs,
      String userId, String? devicePub, DateTime now, bool clockOk) async {
    if (devicePub == null) return null;
    final token = prefs.getString(_licenseKey(userId));
    if (token == null) return null;
    if (!clockOk) {
      // Kept: it works again once the clock is right. Logged only.
      await _recordTamper(prefs, userId, ShellLicenseTamper.clock);
      return null;
    }
    final inspected = await inspectShellLicense(
        token, [licensePublicKey, ...previousLicenseKeys]);
    final payload = inspected.payload;
    final problem = inspected.problem ??
        (payload == null
            ? null
            : payload['dev'] != devicePub
                ? ShellLicenseTamper.otherDevice
                : payload['sub'] != userId
                    ? ShellLicenseTamper.otherAccount
                    : payload['app'] != appId
                        ? ShellLicenseTamper.corrupt
                        : null);
    if (problem != null) {
      // Useless here whatever the cause: drop it, report at the next
      // connection (only an edited license is a strike, server side).
      await prefs.remove(_licenseKey(userId));
      await _recordTamper(prefs, userId, problem);
      return null;
    }
    if (payload == null || inspected.retiredKey) return null;
    final exp = payload['exp'];
    if (exp is! int || exp * 1000 <= now.millisecondsSinceEpoch) return null;
    return payload;
  }

  Future<void> _recordTamper(
      SharedPreferences prefs, String userId, ShellLicenseTamper kind) async {
    final kinds = _readTamper(prefs, userId);
    if (kinds.add(kind.wire)) {
      await prefs.setString(_tamperKey(userId), jsonEncode(kinds.toList()));
    }
  }

  Set<String> _readTamper(SharedPreferences prefs, String userId) {
    try {
      final raw = jsonDecode(prefs.getString(_tamperKey(userId)) ?? '[]');
      return {for (final k in raw as List) '$k'};
    } catch (_) {
      return {};
    }
  }

  void _set(ShellEntitlement e, ShellEntitlementSource source,
      ShellOfflineStatus offline) {
    final changed = e != _entitlement || source != _source;
    _entitlement = e;
    _source = source;
    _offline = offline;
    if (changed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Talking to the license function
  // ---------------------------------------------------------------------------

  Future<({int status, Map<String, dynamic> body})?> _call(
      Map<String, dynamic> body) async {
    final server = await _account.currentAuthServer();
    final token = _account.currentAccessToken;
    if (server == null || token == null) return null;
    final base = server.url.endsWith('/')
        ? server.url.substring(0, server.url.length - 1)
        : server.url;
    try {
      final response = await _client.post(
        Uri.parse('$base/functions/v1/license'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
          if (server.apiKey != null) 'apikey': server.apiKey!,
        },
        body: jsonEncode({...body, 'app_id': appId}),
      );
      final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
      return (
        status: response.statusCode,
        body: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      );
    } catch (_) {
      return null; // offline
    }
  }

  /// Once per connection: report offline use, then renew or take the
  /// license.
  Future<void> _onlineDuties(String userId, ShellEntitlement claimed,
      String? devicePub, Map<String, dynamic>? license) async {
    if (_busy) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // A strike drops the license here: nothing to renew or take after it.
      if (await _reportOfflineUse(prefs, userId)) return;
      if (devicePub == null) return;
      if (!claimed.unlocksAnything) {
        // Refunded or suspended while this device held a license: the
        // renewal is refused and the license dropped before it can be
        // used offline again.
        if (license != null) await _renew(prefs, userId, devicePub);
        return;
      }
      final status = await _call({'action': 'status', 'device_key': devicePub});
      if (status != null && status.status == 200) {
        _offline = ShellOfflineStatus(
          supported: true,
          heldHere: _offline.heldHere,
          expiresAt: _offline.expiresAt,
          holderLabel: status.body['holder_is_you'] == true
              ? null
              : status.body['holder_label'] as String?,
          movesLeft: status.body['moves_left'] as int?,
        );
        notifyListeners();
      }
      final exp = license?['exp'];
      final dueForRenewal = exp is int &&
          DateTime.fromMillisecondsSinceEpoch(exp * 1000)
              .isBefore(_clock().add(renewBefore));
      if (license != null && dueForRenewal) {
        await _renew(prefs, userId, devicePub);
      } else if (license == null &&
          autoActivateFirstDevice &&
          status?.status == 200 &&
          status!.body['holder_label'] == null &&
          status.body['holder_is_you'] != true) {
        await activateOffline();
      }
    } finally {
      _busy = false;
    }
  }

  /// Reports what was used offline and anything found wrong with the
  /// stored license. True when the server told the app to drop its local
  /// unlock (and it was dropped).
  Future<bool> _reportOfflineUse(SharedPreferences prefs, String userId) async {
    final raw = prefs.getString(_usedKey(userId));
    final tamper = _readTamper(prefs, userId);
    if (raw == null && tamper.isEmpty) return false;
    final reply = await _call({
      'action': 'report',
      'used': raw == null
          ? {'plan': 'free', 'features': <String>[]}
          : jsonDecode(raw),
      if (tamper.isNotEmpty) 'tamper': tamper.toList()..sort(),
    });
    if (reply == null || reply.status != 200) return false; // retry next time
    await prefs.remove(_usedKey(userId));
    await prefs.remove(_tamperKey(userId));
    if (reply.body['revoke_local'] != true) return false;
    await prefs.remove(_licenseKey(userId));
    _ready = _update();
    return true;
  }

  Future<void> _renew(
      SharedPreferences prefs, String userId, String devicePub) async {
    final reply = await _call({'action': 'renew', 'device_key': devicePub});
    if (reply == null) return;
    if (reply.status == 200 && reply.body['license'] is String) {
      await prefs.setString(
          _licenseKey(userId), reply.body['license'] as String);
    } else if (reply.status == 409 ||
        reply.status == 410 ||
        reply.status == 403) {
      // Moved to another device, refunded, or suspended: drop it here.
      await prefs.remove(_licenseKey(userId));
    }
    _ready = _update();
  }

  /// Makes THIS device the account's offline device for the app (moving it
  /// from another device counts against the monthly limit).
  Future<ShellActivateResult> activateOffline() async {
    final userId = _account.currentUserId;
    final devicePub = await _deviceKey.publicKey();
    if (devicePub == null) return ShellActivateResult.unsupported;
    if (userId == null) return ShellActivateResult.notEntitled;
    final reply = await _call({
      'action': 'activate',
      'device_key': devicePub,
      'device_label': deviceLabel ?? defaultTargetPlatform.name,
      'platform': defaultTargetPlatform.name,
    });
    if (reply == null) return ShellActivateResult.offline;
    switch (reply.status) {
      case 200:
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            _licenseKey(userId), reply.body['license'] as String);
        _offline = ShellOfflineStatus(
            supported: true, movesLeft: reply.body['moves_left'] as int?);
        await (_ready = _update());
        return ShellActivateResult.activated;
      case 429:
        return ShellActivateResult.moveLimit;
      case 403:
        return reply.body['error'] == 'suspended'
            ? ShellActivateResult.suspended
            : ShellActivateResult.notEntitled;
      default:
        return ShellActivateResult.notEntitled;
    }
  }

  /// Renews the session (fresh claims after a purchase), then reports,
  /// renews or takes the license. Returns whether the server was reached.
  Future<bool> checkNow() async {
    final reached = await _account.refreshSessionNow();
    _lastOnlineUser = null;
    await (_ready = _update());
    return reached;
  }

  @override
  void dispose() {
    _account.removeListener(_onAccount);
    super.dispose();
  }
}

/// What can be wrong with a stored license. Only [edited] is evidence of
/// cheating (and the only kind the server strikes for); the others have
/// honest causes and are just logged.
enum ShellLicenseTamper {
  /// Well-formed, but the signature fails: someone changed it.
  edited('edited'),

  /// Signed for another phone: restored from a backup, or copied.
  otherDevice('other_device'),

  /// Signed for another account signed in on this phone.
  otherAccount('other_account'),

  /// The device clock went backwards.
  clock('clock'),

  /// Not a readable license (a broken write).
  corrupt('corrupt');

  const ShellLicenseTamper(this.wire);

  /// The name the license function expects.
  final String wire;
}

/// Inspects a stored license against the current key and any retired
/// ones ([publicKeysB64], current first): the payload when a key's
/// signature holds ([retiredKey] when only an old key's did), else what is
/// wrong with it.
Future<
    ({
      Map<String, dynamic>? payload,
      ShellLicenseTamper? problem,
      bool retiredKey
    })> inspectShellLicense(String token, List<String> publicKeysB64) async {
  const corrupt =
      (payload: null, problem: ShellLicenseTamper.corrupt, retiredKey: false);
  final parts = token.split('.');
  if (parts.length != 2) return corrupt;
  final Map<String, dynamic> payload;
  final List<int> signature;
  try {
    final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
    if (decoded is! Map<String, dynamic>) return corrupt;
    payload = decoded;
    signature = base64Url.decode(base64Url.normalize(parts[1]));
  } catch (_) {
    return corrupt;
  }
  // Only something shaped like our license can be "edited"; anything else
  // is a broken write.
  const fields = ['v', 'lid', 'sub', 'app', 'plan', 'dev', 'iat', 'exp'];
  if (!fields.every(payload.containsKey) || signature.length != 64) {
    return corrupt;
  }
  for (var i = 0; i < publicKeysB64.length; i++) {
    final ok = await Ed25519().verify(
      utf8.encode(parts[0]),
      signature: Signature(signature,
          publicKey: SimplePublicKey(base64.decode(publicKeysB64[i]),
              type: KeyPairType.ed25519)),
    );
    if (ok) return (payload: payload, problem: null, retiredKey: i > 0);
  }
  return (payload: null, problem: ShellLicenseTamper.edited, retiredKey: false);
}

/// The payload of a license signed with [publicKeyB64] (raw Ed25519,
/// base64), or null when the signature does not hold.
Future<Map<String, dynamic>?> verifyShellLicense(
    String token, String publicKeyB64) async {
  try {
    final inspected = await inspectShellLicense(token, [publicKeyB64]);
    return inspected.payload;
  } catch (_) {
    return null;
  }
}
