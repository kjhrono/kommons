import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'game_sync.dart';
import 'game_sync_service.dart';

/// One seat of a shared room, as the saved-games screen renders it.
class CloudSeat {
  const CloudSeat(
      {required this.name, required this.colorHex, required this.ready});

  final String name;
  final String colorHex;
  final bool ready;
}

/// One cloud-shared multiplayer game: a room on the game server that has at
/// least one seat in its roster. [isLocalHost] marks rooms this device
/// created (their host secret is stored here), which makes them fully
/// resumable with host powers; every other listed room is joinable.
class CloudRoom {
  const CloudRoom({
    required this.code,
    required this.clock,
    required this.hasSnapshot,
    required this.hasPassword,
    required this.seats,
    required this.isLocalHost,
    this.designatedHost = '',
  });

  final String code;
  final int clock;
  final bool hasSnapshot;
  final bool hasPassword;
  final List<CloudSeat> seats;
  final bool isLocalHost;

  /// Seat the current host promoted before departing ('' = none pending).
  /// That seat can claim host powers from the saved-games screen — the
  /// handover replaces delete/leave as the way a room changes hands.
  final String designatedHost;

  String? get hostName => seats.isNotEmpty ? seats.first.name : null;

  CloudSeat? seat(String name) =>
      seats.where((s) => s.name == name).firstOrNull;
}

/// Read model over the game server's `rooms` + `roster` tables: the same
/// PostgREST surface the sync service writes through, used read-only to
/// list the player's shared games. Reads are anonymous by design (the same
/// access joining uses), so this service needs only the game-server
/// connection the lobby already persists.
///
/// Host resumption is the one elevated capability: a room this device
/// created keeps its host secret under [hostSecretsPrefKey], and resuming
/// with it re-mints full host rights via claim_host — the same secret the
/// lobby already stores per-room.
class CloudRoomService {
  CloudRoomService({
    required String serverUrl,
    String? apiKey,
    http.Client? client,
    http.Client? sharedClient,
  })  : _apiKey = apiKey,
        _client = client ?? sharedClient ?? http.Client() {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    _baseUrl = Uri.parse(normalized);
  }

  static const hostSecretsPrefKey = 'prefs.online.hostSecrets';
  static const legacyHostSecretKey = 'prefs.online.hostSecret';
  static const legacyRoomCodeKey = 'prefs.online.roomCode';
  static const seatNamesPrefKey = 'prefs.online.seatNames';
  static const serverUrlPrefKey = 'prefs.online.serverUrl';

  final String? _apiKey;
  final http.Client _client;
  late final Uri _baseUrl;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_apiKey != null) ...{
          'apikey': _apiKey!,
          'Authorization': 'Bearer $_apiKey',
        },
      };

  Uri _table(String name, [Map<String, String>? filters]) => _baseUrl.replace(
        path: '${_apiKey == null ? '' : '/rest/v1'}/$name',
        queryParameters: (filters == null || filters.isEmpty) ? null : filters,
      );

  /// Records a host secret for a room code (called when the lobby opens a
  /// room) so the saved-games screen can list and resume it with host
  /// powers. Also keeps the legacy single-room key in sync.
  Future<void> recordHostSecret(String code, String secret) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _hostSecrets(prefs);
    map[code] = secret;
    await prefs.setString(hostSecretsPrefKey, jsonEncode(map));
    await prefs.setString(legacyHostSecretKey, secret);
  }

  Future<Map<String, String>> _hostSecrets(SharedPreferences prefs) async {
    final raw = prefs.getString(hostSecretsPrefKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map((k, v) => MapEntry(k, v is String ? v : ''));
    } on FormatException {
      return {};
    }
  }

  /// The stored host secret for a room, or null when this device never
  /// hosted it. Falls back to the legacy single-room pair (secret + code
  /// stored by the lobby before per-room maps existed).
  Future<String?> hostSecretFor(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _hostSecrets(prefs);
    if (map[code]?.isNotEmpty ?? false) return map[code];
    final legacy = prefs.getString(legacyHostSecretKey);
    final legacyCode = prefs.getString(legacyRoomCodeKey);
    if (legacy != null && legacy.isNotEmpty && legacyCode == code) {
      return legacy;
    }
    return null;
  }

  /// Records the seat name this device joined a room with — resumes must
  /// re-announce the same seat, or a second row appears in the roster.
  Future<void> recordSeatName(String code, String name) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _seatNames(prefs);
    map[code] = name;
    await prefs.setString(seatNamesPrefKey, jsonEncode(map));
  }

  Future<Map<String, String>> _seatNames(SharedPreferences prefs) async {
    final raw = prefs.getString(seatNamesPrefKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map((k, v) => MapEntry(k, v is String ? v : ''));
    } on FormatException {
      return {};
    }
  }

  /// The seat name previously used in [code], when recorded.
  Future<String?> seatNameFor(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _seatNames(prefs);
    final name = map[code];
    return (name != null && name.isNotEmpty) ? name : null;
  }

  /// The seat names this device has joined rooms under, keyed by room code
  /// (empty strings omitted). Read-only view for callers that need to match
  /// several rooms at once, like the lobby's pending-handover list.
  Future<Map<String, String>> seatNamesByRoom() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _seatNames(prefs);
    return {
      for (final entry in map.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
  }

  /// True when the game-server connection the lobby persists exists —
  /// without it there is nothing to list.
  static Future<bool> serverConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(serverUrlPrefKey) ?? '').isNotEmpty;
  }

  /// Builds a service from the connection the lobby persists. Null when the
  /// player never configured a game server on this device. Tests override
  /// [forTestFactory] to inject a MockClient-backed instance.
  static Future<CloudRoomService?> fromStoredConnection() async {
    if (forTestFactory != null) return forTestFactory!();
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(serverUrlPrefKey) ?? '';
    if (url.isEmpty) return null;
    final key = prefs.getString('prefs.online.anonKey');
    return CloudRoomService(
        serverUrl: url, apiKey: (key == null || key.isEmpty) ? null : key);
  }

  /// Test seam replacing [fromStoredConnection] entirely.
  @visibleForTesting
  static CloudRoomService? Function()? forTestFactory;

  /// The room's stored world snapshot, or null when the host has not
  /// published one yet (the world has not started).
  Future<String?> snapshotOf(CloudRoom room) async {
    final response = await _client.get(
      _table('rooms', {'code': 'eq.${room.code}', 'select': 'session'}),
      headers: _headers,
    );
    if (response.statusCode != 200) return null;
    final rows = jsonDecode(response.body);
    if (rows is! List || rows.isEmpty) return null;
    final value = (rows.first as Map)['session'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Lists every room with at least one roster seat. Rooms this device
  /// hosts are marked via their stored secret; [playerName] marks the
  /// local seat (the lobby keys seats by name).
  Future<List<CloudRoom>> listRooms(String playerName) async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = await _hostSecrets(prefs);
    final seatNames = await _seatNames(prefs);
    // The legacy key (single-room era) still unlocks its own room.
    final legacy = prefs.getString(legacyHostSecretKey);

    // One round-trip: the roster rides along as an embedded resource (it
    // has a foreign key to rooms). PostgREST always answers with the
    // `roster` key when the select asks for it, so servers or mocks that
    // do not serve the embed fall back to the legacy second GET below —
    // the listing works against either shape.
    final roomsResponse = await _client.get(
      _table('rooms', {
        'select': 'code,clock,session,password,host_secret,designated_host,roster(room_code,player_name,color_hex,ready)',
        'order': 'updated_at.desc',
        'roster.order': 'joined_at',
      }),
      headers: _headers,
    );
    if (roomsResponse.statusCode != 200) {
      throw Exception(
          'Could not list rooms (HTTP ${roomsResponse.statusCode})');
    }

    final rooms =
        (jsonDecode(roomsResponse.body) as List).cast<Map<String, dynamic>>();
    final embedded = rooms.every((room) => room.containsKey('roster'));
    final seatsByRoom = <String, List<CloudSeat>>{};
    if (embedded) {
      for (final room in rooms) {
        final code = room['code'] as String?;
        if (code == null) continue;
        seatsByRoom[code] = [
          for (final row in ((room['roster'] as List?) ?? const []))
            if (row is Map<String, dynamic> && row['player_name'] is String)
              CloudSeat(
                name: row['player_name'] as String,
                colorHex: row['color_hex'] is String
                    ? row['color_hex'] as String
                    : 'FF9C27FF',
                ready: row['ready'] == true,
              ),
        ];
      }
    } else {
      final rosterResponse = await _client.get(
        _table('roster', {
          'select': 'room_code,player_name,color_hex,ready',
          'order': 'joined_at'
        }),
        headers: _headers,
      );
      if (rosterResponse.statusCode != 200) {
        throw Exception(
            'Could not list players (HTTP ${rosterResponse.statusCode})');
      }
      for (final row in (jsonDecode(rosterResponse.body) as List)
          .cast<Map<String, dynamic>>()) {
        final code = row['room_code'] as String?;
        final name = row['player_name'] as String?;
        if (code == null || name == null) continue;
        (seatsByRoom[code] ??= []).add(CloudSeat(
          name: name,
          colorHex: row['color_hex'] is String
              ? row['color_hex'] as String
              : 'FF9C27FF',
          ready: row['ready'] == true,
        ));
      }
    }

    final listed = <CloudRoom>[];
    for (final room in rooms) {
      final code = room['code'] as String?;
      final seats = seatsByRoom[code];
      if (code == null || seats == null || seats.isEmpty) continue;
      final secret = secrets[code] ?? legacy ?? '';
      final isLocalHost = secret.isNotEmpty && secret == room['host_secret'];
      // A saved-games list, not a server browser: show rooms the player
      // sits in (under the account name or the seat name this device
      // joined with — resume accepts either), plus rooms this device
      // hosts (host powers regardless of the seat name it used).
      // Strangers' rooms stay in the join flow.
      final seatName = seatNames[code];
      final mine = seats.any((s) =>
          s.name == playerName || (seatName != null && s.name == seatName));
      if (!mine && !isLocalHost) continue;
      listed.add(CloudRoom(
        code: code,
        clock: room['clock'] is int ? room['clock'] as int : 0,
        hasSnapshot: (room['session'] as String?)?.isNotEmpty ?? false,
        hasPassword: ((room['password'] as String?) ?? '').isNotEmpty,
        seats: seats,
        isLocalHost: isLocalHost,
        designatedHost: (room['designated_host'] as String?) ?? '',
      ));
    }
    return listed;
  }

  /// Builds the sync service that re-opens a room with host powers
  /// (existing room: [PostgrestSyncService.announcePlayer] recognizes its
  /// own room by secret and skips the create). This service's HTTP client
  /// is forwarded so tests mock one client for everything.
  GameSyncService hostResumeService(CloudRoom room,
      {required String hostSecret}) {
    return PostgrestSyncService(
      serverUrl: _baseUrl.toString(),
      apiKey: _apiKey,
      createsRoom: true,
      code: room.code,
      hostSecret: hostSecret,
      client: _client,
    );
  }

  /// Builds the sync service that re-opens a room as a seat.
  GameSyncService joinerResumeService(CloudRoom room, {String? password}) {
    return PostgrestSyncService(
      serverUrl: _baseUrl.toString(),
      apiKey: _apiKey,
      code: room.code,
      joinPassword: password,
      client: _client,
    );
  }

  /// Host side of the handover: stamps [seatName] as the room's next host.
  /// The promoted seat claims powers itself from its own device; the secret
  /// never travels. Returns the sync service used for the call so callers
  /// can dispose it.
  Future<void> designateHost(CloudRoom room,
      {required String hostSecret, required String seatName}) async {
    final response = await _client.post(
      _rpc('designate_host'),
      headers: _headers,
      body: jsonEncode(
          {'p_code': room.code, 'p_secret': hostSecret, 'p_name': seatName}),
    );
    _ensureOk(response, 'designate the next host');
  }

  /// Host-side undo for a pending handover: withdraws the designation before
  /// the promoted seat claims it. The room returns to its ordinary state —
  /// nobody's powers change, nothing was ever transferred. Fails on the
  /// server when nothing is pending (the claim already happened) — callers
  /// should surface that as "too late" rather than retrying.
  Future<void> cancelHostDesignation(CloudRoom room,
      {required String hostSecret}) async {
    final response = await _client.post(
      _rpc('cancel_host_designation'),
      headers: _headers,
      body: jsonEncode({'p_code': room.code, 'p_secret': hostSecret}),
    );
    _ensureOk(response, 'cancel the pending handover');
  }

  /// Promoted-seat side of the handover: proves this device's recorded seat
  /// [seatName] holds the room's pending designation and mints its host
  /// token. The server consumes the designation and rotates the host secret
  /// atomically — the returned secret is the room's new host credential and
  /// is stored locally like a freshly created room's. Null when the server
  /// predates the RPC (404): legacy rooms hand over by re-hosting instead.
  Future<String?> claimHostPromotion(CloudRoom room,
      {required String seatName}) async {
    final response = await _client.post(
      _rpc('claim_host_promotion'),
      headers: _headers,
      body: jsonEncode({'p_code': room.code, 'p_name': seatName}),
    );
    if (response.statusCode == 404) return null;
    _ensureOk(response, 'claim the host promotion');
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic>
        ? decoded['host_secret'] as String?
        : null;
  }

  Uri _rpc(String name) => _baseUrl.replace(
        path: '${_apiKey == null ? '' : '/rest/v1'}/rpc/$name',
      );

  void _ensureOk(http.Response response, String action) {
    if (response.statusCode >= 400) {
      throw Exception(
          'Failed to $action (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  /// Forgets a deleted room's local records: its host secret (so a future
  /// room can never accidentally inherit the claim) and its seat name.
  Future<void> forgetHostedRoom(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _hostSecrets(prefs);
    map.remove(code);
    await prefs.setString(hostSecretsPrefKey, jsonEncode(map));
    final legacy = prefs.getString(legacyHostSecretKey);
    final legacyCode = prefs.getString(legacyRoomCodeKey);
    if (legacy != null && legacyCode == code) {
      await prefs.remove(legacyHostSecretKey);
      await prefs.remove(legacyRoomCodeKey);
    }
  }

  /// Forgets this device's seat record in a room it left, so a later rejoin
  /// starts fresh instead of resuming a ghost seat.
  Future<void> forgetSeatIn(String code) async {
    final map = await _seatNames(await SharedPreferences.getInstance());
    map.remove(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(seatNamesPrefKey, jsonEncode(map));
  }
}
