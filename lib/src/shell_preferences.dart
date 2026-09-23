// The codec and merge rules for the shell's cross-project preferences:
// the slice of GoTrue `user_metadata` that travels with the account, so
// a player signing into any game backed by the same auth server inherits
// their theme, language and player name.
//
// The metadata blob lives under one namespaced key so provider-written
// data and the game server's own metadata (e.g. `must_change_password`)
// never collide:
//
// ```json
// { "kommons": {
//     "theme": "dark",
//     "locale": "it",
//     "playerName": "Marcuz",
//     "updatedAt": { "theme": 1758500000, "locale": 1758500123 }
// } }
// ```
//
// The per-key `updatedAt` map makes the pull decision deterministic: a
// local value wins only when it is newer (or the cloud one is absent),
// so last-writer-wins holds per key, per device, without a shadowing
// older cloud state over a fresher local edit.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'shell_strings.dart';

/// The metadata key the shell's preferences live under.
const kShellPreferencesKey = 'kommons';

/// One synced preference read out of a metadata blob.
enum ShellPrefKey {
  /// Theme mode, persisted as `light` / `dark` (the same tokens the
  /// theme notifier writes to SharedPreferences).
  theme('theme'),

  /// Language, persisted as the [ShellLanguage.code] ('en', 'it', …).
  locale('locale'),

  /// Player name, a plain trimmed string.
  playerName('playerName');

  const ShellPrefKey(this.key);

  /// The key inside the `kommons` metadata object.
  final String key;
}

/// Reads the shell's preference slice out of a full user-metadata map
/// (the shape [AuthSession.userMetadata] and `fetchUser` return). Returns
/// an empty map when the blob is absent or malformed — never throws.
Map<String, dynamic> shellPreferencesFromMetadata(
    Map<String, dynamic> metadata) {
  final blob = metadata[kShellPreferencesKey];
  if (blob is Map<String, dynamic>) return blob;
  if (blob is Map) {
    // Defensive: JSON round-trips give Map<String, dynamic>, but a host
    // hand-rolled blob may arrive as Map<dynamic, dynamic>.
    return blob.map((key, value) => MapEntry('$key', value));
  }
  return const {};
}

/// Writes [preferences] back under the shell's namespace, merging into
/// [metadata] (other keys — provider data, `must_change_password`, … —
/// are preserved). Returns a fresh map; the input is not mutated.
Map<String, dynamic> shellPreferencesToMetadata(
    Map<String, dynamic> metadata, Map<String, dynamic> preferences) {
  return {
    ...metadata,
    kShellPreferencesKey: preferences,
  };
}

/// The value of one shell preference as carried in the metadata blob.
/// (theme: 'light'|'dark'; locale: ShellLanguage.code; playerName: string.)
String? shellPreferenceValue(
    Map<String, dynamic> preferences, ShellPrefKey key) {
  final value = preferences[key.key];
  return value is String ? value : null;
}

/// Where the current value of a shell preference came from — the provenance
/// the settings screen shows per key.
enum ShellPrefOrigin {
  /// Never chosen anywhere: the shell's default (or an unset language).
  device,

  /// Chosen on this device (a signed-out edit, or a local edit newer than
  /// the last cloud state this device saw).
  local,

  /// Pulled from the account — another device (or another game) decided it.
  cloud,
}

/// The persisted-origin key inside SharedPreferences (`prefs.account.prefOrigins`).
const shellPrefOriginsKey = 'prefs.account.prefOrigins';

/// Reads the persisted origin per key. Missing entries mean [ShellPrefOrigin.device]
/// — a value with no recorded story is a default by definition. Unknown
/// spellings (a downgraded app) also read as device, never a crash.
Map<ShellPrefKey, ShellPrefOrigin> shellPrefOriginsFromPrefs(
    SharedPreferences prefs) {
  final raw = prefs.getString(shellPrefOriginsKey);
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final out = <ShellPrefKey, ShellPrefOrigin>{};
    decoded.forEach((key, value) {
      final prefKey =
          ShellPrefKey.values.where((k) => k.key == '$key').firstOrNull;
      if (prefKey == null) return;
      out[prefKey] = value == 'cloud'
          ? ShellPrefOrigin.cloud
          : value == 'local'
              ? ShellPrefOrigin.local
              : ShellPrefOrigin.device;
    });
    return out;
  } catch (_) {
    return const {};
  }
}

/// Persists [origins] (a delta: only the entries to record). Entries mapped
/// to [ShellPrefOrigin.device] remove their record — the compact form keeps
/// the file to just the keys with a story. Grows the existing record, so
/// callers pass only what changed.
Future<void> writeShellPrefOrigins(
    SharedPreferences prefs, Map<ShellPrefKey, ShellPrefOrigin> origins) async {
  final current =
      Map<ShellPrefKey, ShellPrefOrigin>.from(shellPrefOriginsFromPrefs(prefs));
  origins.forEach((key, origin) {
    if (origin == ShellPrefOrigin.device) {
      current.remove(key);
    } else {
      current[key] = origin;
    }
  });
  if (current.isEmpty) {
    await prefs.remove(shellPrefOriginsKey);
    return;
  }
  await prefs.setString(
      shellPrefOriginsKey,
      jsonEncode({
        for (final entry in current.entries) entry.key.key: entry.value.name,
      }));
}

/// Timestamps each current shell preference (epoch seconds). Absent keys
/// were never written; a malformed entry reads as 0 (always loses merges).
Map<String, int> shellPreferenceTimestamps(Map<String, dynamic> preferences) {
  final updated = preferences['updatedAt'];
  if (updated is! Map) return const {};
  final out = <String, int>{};
  updated.forEach((key, value) {
    if (value is int) out['$key'] = value;
  });
  return out;
}

/// Builds the metadata payload that pushes [changes] — key → value, or
/// null to remove the key — stamping them at [now] (epoch seconds) and
/// carrying forward the timestamps of untouched keys.
Map<String, dynamic> shellPreferencePatch(
    Map<String, dynamic> currentPreferences,
    Map<String, String?> changes,
    int now) {
  final stamps = shellPreferenceTimestamps(currentPreferences);
  final values = Map<String, dynamic>.from(currentPreferences);
  final newStamps = Map<String, int>.from(stamps);
  changes.forEach((key, value) {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    newStamps[key] = now;
  });
  values['updatedAt'] = newStamps;
  return values;
}

/// The pull decision for one key: apply [cloudValue] over the local
/// preference when the cloud edit is at least as new as the local one.
/// [localStamp] 0 (never edited locally, or unset) always accepts the
/// cloud value; an absent [cloudStamp] reads as 0 so a locally-stamped
/// key survives an older cloud blob that simply never tracked it.
bool shellPrefShouldApply(
    {required String? cloudValue,
    required int cloudStamp,
    required int localStamp}) {
  if (cloudValue == null) return false;
  if (localStamp == 0) return true;
  return cloudStamp >= localStamp;
}

/// Compares the cloud preference slice against the local notifier values,
/// returning (pull → apply locally, push → write to the server). Both may
/// be non-empty when the two devices edited *different* keys.
///   * pull — another device (or another game) changed a preference more
///     recently than this device's local edit;
///   * push — this device's local edits are newer and the cloud blob never
///     saw them.
/// The controller applies these against the live notifiers.
({
  Map<ShellPrefKey, String> pull,
  Map<ShellPrefKey, String?> push,
}) shellPreferencesReconcile({
  required Map<String, dynamic> cloudPreferences,
  required String? localTheme,
  required String? localLocale,
  required String? localPlayerName,
  required Map<String, int> localStamps,
}) {
  final cloudStamps = shellPreferenceTimestamps(cloudPreferences);
  final cloudValues = <ShellPrefKey, String?>{
    for (final key in ShellPrefKey.values)
      key: shellPreferenceValue(cloudPreferences, key),
  };
  final localValues = <ShellPrefKey, String?>{
    ShellPrefKey.theme: localTheme,
    ShellPrefKey.locale: localLocale,
    ShellPrefKey.playerName: localPlayerName,
  };

  final pull = <ShellPrefKey, String>{};
  final push = <ShellPrefKey, String?>{};
  for (final key in ShellPrefKey.values) {
    final cloud = cloudValues[key];
    final local = localValues[key];
    final cloudStamp = cloudStamps[key.key] ?? 0;
    final localStamp = localStamps[key.key] ?? 0;
    if (cloud != null &&
        shellPrefShouldApply(
            cloudValue: cloud,
            cloudStamp: cloudStamp,
            localStamp: localStamp)) {
      pull[key] = cloud;
    } else if (local != null && (cloud == null || localStamp > cloudStamp)) {
      // The cloud never saw this key, or this device's local edit is
      // strictly newer (an offline edit's stamp survives the sign-in):
      // this device's value is the only truth there is — seed it up (even
      // without a local stamp, e.g. the pre-sync playerName). An equal
      // stamp means the flush already delivered it: no PUT.
      push[key] = local;
    }
    // Equal stamps with equal values: nothing to do. A locally-stamped
    // key that lost the stamp comparison already pulled above.
  }
  return (pull: pull, push: push);
}

// ---------------------------------------------------------------------------
// Per-game settings: the `games` map beside the shell keys
// ---------------------------------------------------------------------------
//
// A host game can opt into the sync with its own namespaced map, stored
// beside the shell's keys so the two scopes never collide:
//
// ```json
// { "kommons": {
//     "theme": "dark",
//     "games": {
//         "kalcio": { "difficulty": "hard", "sound": true },
//         "updatedAt": { "kalcio": 1758500456 }
//     }
// } }
// ```
//
// The shell owns the `games` key itself (and `updatedAt` inside it); the
// host owns everything under its game id. The same per-key stamp rules as
// the shell preferences apply, one level down: a game map pulls when the
// cloud edit is at least as new as the local one, and pushes when this
// device's map is strictly newer (or the cloud lacks the game entirely).

/// The key inside the `kommons` metadata object holding the per-game maps.
const kShellGamesSettingsKey = 'games';

/// The stamps key *inside* the `games` map (reserved — hosts must not use
/// it as a game id). Maps game id → epoch-seconds stamp.
const kShellGamesStampsKey = 'updatedAt';

/// Reads the per-game slice (`kommons.games`) out of a full user-metadata
/// map: game id → its settings map. Absent or malformed entries never
/// throw; entries that are not maps are dropped. The reserved stamps key
/// is included as-is — readers must skip it (the helpers here do).
Map<String, dynamic> shellGameSettingsFromMetadata(
    Map<String, dynamic> metadata) {
  final blob = metadata[kShellPreferencesKey];
  if (blob is! Map) return const {};
  final games = blob[kShellGamesSettingsKey];
  if (games is! Map) return const {};
  return games.map((key, value) => MapEntry('$key', value));
}

/// Reads one game's settings map (empty when the game has none).
Map<String, dynamic> shellGameSettings(
        Map<String, dynamic> metadata, String gameId) =>
    shellGameSettingsFromMetadata(metadata)[gameId] ?? const {};

/// The per-game stamps (`kommons.games.updatedAt`), game id → epoch seconds.
Map<String, int> shellGameSettingsStamps(Map<String, dynamic> metadata) {
  final stamps = shellGameSettingsFromMetadata(metadata)[kShellGamesStampsKey];
  if (stamps is! Map) return const {};
  final out = <String, int>{};
  stamps.forEach((key, value) {
    if (value is int) out['$key'] = value;
  });
  return out;
}

/// Builds a full-metadata payload that merges [gamePatch] — game id → its
/// complete settings map, or null to remove the game's entry — into the
/// `kommons.games` map of [metadata], stamping touched games at [now]
/// (epoch seconds) and carrying untouched ones forward untouched. Other
/// metadata (shell keys, provider data, …) is preserved. Returns a fresh
/// map; the input is not mutated.
Map<String, dynamic> shellGameSettingsToMetadata(Map<String, dynamic> metadata,
    Map<String, Map<String, dynamic>?> gamePatch, int now) {
  final blob = metadata[kShellPreferencesKey] is Map
      ? Map<String, dynamic>.from((metadata[kShellPreferencesKey] as Map)
          .map((key, value) => MapEntry('$key', value)))
      : <String, dynamic>{};
  final games = blob[kShellGamesSettingsKey] is Map
      ? Map<String, dynamic>.from((blob[kShellGamesSettingsKey] as Map)
          .map((key, value) => MapEntry('$key', value)))
      : <String, dynamic>{};
  final stamps = Map<String, int>.from(shellGameSettingsStamps({
    kShellPreferencesKey: {kShellGamesSettingsKey: games},
  }));
  gamePatch.forEach((gameId, settings) {
    if (settings == null) {
      games.remove(gameId);
      stamps.remove(gameId);
    } else {
      games[gameId] = settings;
      stamps[gameId] = now;
    }
  });
  if (stamps.isNotEmpty) games[kShellGamesStampsKey] = stamps;
  blob[kShellGamesSettingsKey] = games;
  return {...metadata, kShellPreferencesKey: blob};
}

/// The per-game reconcile — the shell reconcile one level down. Compares
/// the cloud `kommons.games` maps against this device's saved maps:
///   * pull — the cloud's map for a game is at least as new as the local
///     edit (a local stamp of 0 always accepts);
///   * push — this device's map is strictly newer, or the cloud has no
///     entry for the game at all.
/// Both may be non-empty when different devices (or different games)
/// edited different maps. The reserved stamps key never reconciles.
({
  Map<String, Map<String, dynamic>> pull,
  Map<String, Map<String, dynamic>?> push,
}) shellGameSettingsReconcile({
  required Map<String, dynamic> cloudMetadata,
  required Map<String, Map<String, dynamic>> localGames,
  required Map<String, int> localStamps,
}) {
  final cloudGames = shellGameSettingsFromMetadata(cloudMetadata);
  final cloudStamps = shellGameSettingsStamps(cloudMetadata);
  final pull = <String, Map<String, dynamic>>{};
  final push = <String, Map<String, dynamic>?>{};
  final gameIds = {...cloudGames.keys, ...localGames.keys}
      .where((id) => id != kShellGamesStampsKey)
      .toSet();
  for (final gameId in gameIds) {
    final cloud = cloudGames[gameId];
    final local = localGames[gameId];
    final cloudStamp = cloudStamps[gameId] ?? 0;
    final localStamp = localStamps[gameId] ?? 0;
    // A pull whose map already matches local storage is a no-op: equal
    // stamps after a delivered push re-confirm, they do not re-write.
    if (cloud != null &&
        (localStamp == 0 || cloudStamp >= localStamp) &&
        !_jsonEquals(cloud, local)) {
      pull[gameId] = cloud;
    } else if (local != null && (cloud == null || localStamp > cloudStamp)) {
      push[gameId] = local;
    }
  }
  return (pull: pull, push: push);
}

/// Deep equality over JSON-shaped values (maps, lists, scalars).
bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
