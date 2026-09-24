import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'lobby_seat.dart';

/// The persisted lobby roster: the committed game number and every seat
/// beside the host (an empty seat name = an open slot), stored under a
/// per-game key. This is what makes "prepare the table in advance" work —
/// the host adds and claims seats today, and after an app restart the
/// same roster is waiting in the lobby.
///
/// Two deliberate limits:
///
///  * *Preparation only.* Persistence is a draft of the table, not a live
///    session record — starting the game (the handoff) clears it, because
///    from that point the game's own save/cloud state owns the table.
///  * *Solo never persists.* START SOLO wipes the roster instead of
///    reoffering it: a solo table has no seats worth re-preparing, and
///    the local seat is rebuilt from the account every time anyway.
class PersistedRoster {
  const PersistedRoster({this.roomCode, required this.seats});

  /// The committed game number, if the prepared table had one.
  final String? roomCode;

  /// The guest seats in roster order (self excluded — the local seat is
  /// rebuilt from the persisted account on load).
  final List<LobbySeat> seats;

  bool get isEmpty => seats.isEmpty;
}

/// Reads the roster persisted for [gameId], or null when none is stored.
/// A malformed body (corrupt JSON, wrong shapes) is discarded rather than
/// trusted — the lobby just starts empty, never crashes.
Future<PersistedRoster?> loadPersistedRoster(String gameId) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_key(gameId));
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final code = decoded['roomCode'];
    final seats = (decoded['seats'] as List<dynamic>? ?? [])
        .map((entry) =>
            LobbySeat.fromMap((entry as Map).cast<String, dynamic>()))
        .toList();
    return PersistedRoster(
      roomCode: code is String && code.isNotEmpty ? code : null,
      seats: seats,
    );
  } catch (_) {
    await prefs.remove(_key(gameId));
    return null;
  }
}

/// Stores the roster for [gameId], replacing whatever was there.
Future<void> persistRoster(String gameId, PersistedRoster roster) async {
  final prefs = await SharedPreferences.getInstance();
  if (roster.isEmpty) {
    await prefs.remove(_key(gameId));
    return;
  }
  await prefs.setString(
    _key(gameId),
    jsonEncode({
      if (roster.roomCode != null) 'roomCode': roster.roomCode,
      'seats': [for (final seat in roster.seats) seat.toMap()],
    }),
  );
}

/// Forgets the roster persisted for [gameId].
Future<void> clearPersistedRoster(String gameId) =>
    SharedPreferences.getInstance().then((prefs) => prefs.remove(_key(gameId)));

String _key(String gameId) => 'prefs.lobby.$gameId.roster';
