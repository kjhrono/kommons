/// Transport-agnostic contracts for the multiplayer sync layer. Kept in the
/// model layer so [GameSession] can hold a reference without a dependency on
/// the service implementations (which pull in `http`).
library;

import 'lobby_seat.dart';

/// How other seats hear about this device's changes.
enum SyncEventType { sessionUpdate, playerJoined, playerReady }

/// Outcome of [GameSyncService.joinRoom].
enum RoomJoinResult { ok, roomMissing, wrongPassword }

class SyncEvent {
  SyncEvent({required this.type, this.playerName, this.payload = const {}});
  final SyncEventType type;
  final String? playerName;
  final Map<String, dynamic> payload;
}

/// An abstract lobby/sync layer. The session stays the single source of truth
/// on each device; implementations carry serialized snapshots and readiness
/// flags between seats.
abstract class GameSyncService {
  /// True when the implementation talks to a server (Supabase/PostgREST
  /// over Postgres) rather than local memory (hot-seat).
  bool get isOnline;

  /// A short human-shareable code identifying this game (null offline).
  String? get roomCode;

  /// Publish the current serialized session snapshot.
  Future<void> publishSession(String encodedJson);

  /// Fetch the newest session snapshot (null when none exists yet).
  Future<String?> fetchSessionJson();

  /// Announce this seat's persona; other devices render it in the roster.
  Future<void> announcePlayer(LobbySeat slot);

  /// Set a seat's ready flag on the shared board.
  Future<void> setReady(String playerName, bool ready);

  /// All seats currently known to the room (online) or on this device.
  Future<List<LobbySeat>> roster();

  /// Poll for changes since the last call (readiness, snapshots, joins).
  Future<List<SyncEvent>> poll();

  /// One device (the host) commits the advanced clock after every seat is
  /// ready; everyone else adopts the published hour on their next poll.
  Future<void> publishClock(int newHour);

  Future<int?> fetchClock();

  /// Deletes the hosted room on the server — its row plus (by cascade)
  /// its roster and queued actions. [hostSecret] must be the credential
  /// the hosting device stored when it created the room. Local sync has
  /// nothing to delete.
  Future<void> deleteRoom({required String hostSecret}) async {}

  /// Removes this seat's roster row, leaving the room intact for the
  /// remaining seats. Local sync has nothing to leave.
  Future<void> leaveRoom({required String seatName}) async {}

  /// Validate a room code + optional password before a joiner builds a
  /// session. The default outcome is always-valid: hot-seat (local) sync has
  /// no rooms to check; online implementations gate on the real room row.
  Future<RoomJoinResult> joinRoom(
      {required String code, String? password}) async {
    return RoomJoinResult.ok;
  }

  /// Queue action envelopes for the host (joiner side). Actions are small
  /// JSON maps shaped like [GameSession.applyRemoteAction] inputs; the host
  /// takes and applies them on its poll tick.
  Future<void> pushActions(List<Map<String, dynamic>> actions);

  /// Drain every action pushed since the last call (host side), oldest first.
  Future<List<Map<String, dynamic>>> takeActions();

  void dispose();
}
