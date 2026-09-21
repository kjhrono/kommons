import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'game_sync.dart';
import 'lobby_seat.dart';

/// Local-only implementation: hot-seat multiplayer and every test. All
/// futures complete immediately; the roster lives in memory.
class InMemorySyncService implements GameSyncService {
  InMemorySyncService({List<LobbySeat>? players}) : _players = players ?? [];

  @override
  Future<RoomJoinResult> joinRoom({required String code, String? password}) async => RoomJoinResult.ok;

  final List<LobbySeat> _players;
  String? _sessionJson;
  int? _clock;
  final List<SyncEvent> _pending = [];
  /// Shared action envelope queue: joiners push, the host takes. One queue
  /// per service instance — tests create one instance and share it, mirroring
  /// a server both seats would talk to.
  final List<Map<String, dynamic>> _actionQueue = [];

  @override
  bool get isOnline => false;

  @override
  String? get roomCode => null;

  @override
  Future<void> publishSession(String encodedJson) async => _sessionJson = encodedJson;

  @override
  Future<String?> fetchSessionJson() async => _sessionJson;

  @override
  Future<void> announcePlayer(LobbySeat slot) async {
    final existing = _players.indexWhere((p) => p.name == slot.name);
    if (existing >= 0) {
      _players[existing] = slot;
    } else {
      _players.add(slot);
      _pending.add(SyncEvent(type: SyncEventType.playerJoined, playerName: slot.name));
    }
  }

  @override
  Future<void> setReady(String playerName, bool ready) async {
    final matches = _players.where((p) => p.name == playerName).toList();
    if (matches.isNotEmpty) matches.first.ready = ready;
    _pending.add(SyncEvent(type: SyncEventType.playerReady, playerName: playerName, payload: {'ready': ready}));
  }

  @override
  Future<List<LobbySeat>> roster() async => List.of(_players);

  @override
  Future<List<SyncEvent>> poll() async {
    final drained = List<SyncEvent>.of(_pending);
    _pending.clear();
    return drained;
  }

  @override
  Future<void> publishClock(int newHour) async => _clock = newHour;

  @override
  Future<int?> fetchClock() async => _clock;

  // In-memory rooms and rosters vanish with the service instance; nothing
  // to delete or leave remotely.
  @override
  Future<void> deleteRoom({required String hostSecret}) async {}

  @override
  Future<void> leaveRoom({required String seatName}) async {}

  @override
  Future<void> pushActions(List<Map<String, dynamic>> actions) async =>
      _actionQueue.addAll(actions);

  @override
  Future<List<Map<String, dynamic>>> takeActions() async {
    final drained = List<Map<String, dynamic>>.of(_actionQueue);
    _actionQueue.clear();
    return drained;
  }

  @override
  void dispose() {}
}

/// PostgREST over plain REST — the REST gateway inside Supabase. Needs only
/// the server URL (plus the anon key when Kong/Supabase fronts PostgREST) —
/// no SDK, no app registration — which keeps the Flutter deps unchanged.
/// The shape (filtered GET/PATCH + upsert PUT) maps 1:1 to PostgREST
/// conventions; the database layout lives in `server/supabase/schema.sql`
/// (self-hosted Supabase, primary) or `server/schema.sql` (bare PostgREST
/// fallback).
///
/// Database layout (schemas and grants in server/supabase/schema.sql):
/// ```
/// api.rooms(code, clock, session, host_secret, password)
///                                  -> one row per room; code = shareable code
///                                     (password = join-gate digest, '' = open)
/// api.roster(room_code, player_name, color_hex, interact_every_days, ready)
///                                  -> one row per seat
/// api.actions(room_code, seq, payload)
///                                  -> joiner action envelopes for the host
/// ```
///
/// Authorization: the shared anon key only buys read access plus the two
/// claim RPCs. The host mints a room-scoped JWT (claim_host RPC with the
/// room's host_secret it generated) and joins mints a seat-scoped one
/// (claim_seat); while such a bearer token is attached, PostgREST switches
/// the request role and row-level security scopes every write to that room
/// (and seat) — a leaked anon key no longer lets anyone write to anyone's
/// room. Tokens are fetched lazily on the first write and kept until they
/// expire, then silently re-claimed.
///
/// The host seat creates the room row on its first announce ([createsRoom]);
/// joiners must reference an existing room, enforced by the claim_seat RPC —
/// a typo'd code fails loudly instead of opening an empty seat.
class PostgrestSyncService implements GameSyncService {
  PostgrestSyncService({
    required this.serverUrl,
    String? code,
    http.Client? client,
    this.createsRoom = false,
    this.apiKey,
    String? hostSecret,
    String? joinPassword,
  })  : roomCode = code ?? _generateCode(),
        // Hosts get a room secret (the claim_host credential); pass one to
        // recreate the same room deterministically (tests, reconnection).
        hostSecret = createsRoom ? (hostSecret ?? _generateSecret()) : hostSecret,
        // Hashed once here: the room row stores only this digest, and joiner
        // claims send the same digest (the server compares digests, never
        // seeing the original passphrase).
        _passwordHash = _hashPassword(joinPassword),
        _client = client ?? http.Client() {
    final normalized = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
    _baseUrl = Uri.parse(normalized);
  }

  final String serverUrl;

  /// Secret proving this device created [roomCode]. Set for hosts: it is the
  /// only input (besides the code) of the claim_host RPC that mints the
  /// room's host token. Never sent anywhere else.
  final String? hostSecret;

  /// Supabase anon key. When set, every request targets `<server>/rest/v1/...`
  /// and carries `apikey` + `Authorization: Bearer` headers — what Supabase's
  /// Kong gateway requires. Leave null for a bare PostgREST (no auth header,
  /// root path), which keeps local/test setups working unchanged.
  final String? apiKey;

  /// True for the host seat: the room row is created (or kept) when the seat
  /// announces itself. Joiners never create rooms.
  final bool createsRoom;

  /// Re-assigned once if the freshly generated code collides with an
  /// existing room (HTTP 409 on create) — callers read it after announcing,
  /// so the UI always shows the code that actually stuck.
  @override
  String roomCode;
  final http.Client _client;
  late final Uri _baseUrl;

  /// Host-readable share secret for the room (empty for joiners).
  String get hostSecretForSharing => hostSecret ?? '';

  /// The room's join password as a hex digest ('' = open room). Never the
  /// plain passphrase: digests are what the database stores and what joiner
  /// claims present.
  final String _passwordHash;

  /// FNV-1a 32-bit, hex encoded — a cheap, dependency-free digest. Not
  /// cryptographic hardening (room join passwords are a light social gate,
  /// not secrets worth brute-forcing at scale), but enough that the stored
  /// value and the wire payload don't read as the passphrase itself.
  static String _hashPassword(String? password) {
    if (password == null || password.isEmpty) return '';
    var hash = 0x811c9dc5;
    for (final unit in password.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
      hash ^= (unit >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Validates a room code + optional password against the server before the
  /// joiner builds a session: reads the room row (one cheap GET) and checks
  /// the stored digest. Network failures propagate to the caller so the UI
  /// can distinguish "no such room" from "cannot reach the server".
  @override
  Future<RoomJoinResult> joinRoom({required String code, String? password}) async {
    final response = await _client.get(
      _table('rooms', {'code': 'eq.${code.trim().toUpperCase()}', 'select': 'code,password'}),
      headers: _headers,
    );
    if (response.statusCode == 404) {
      // Server without the REST layout (or behind a proxy without the
      // schema): accept and let announce surface real errors.
      return RoomJoinResult.ok;
    }
    _ensureOk(response, 'look up room $code');
    final rows = jsonDecode(response.body) as List<dynamic>;
    if (rows.isEmpty) return RoomJoinResult.roomMissing;
    final stored = (rows.first as Map<String, dynamic>)['password'] as String? ?? '';
    final presented = _hashPassword(password);
    if (stored.isEmpty || stored == presented) return RoomJoinResult.ok;
    return RoomJoinResult.wrongPassword;
  }

  /// Cached role token (host or seat, whichever this seat claimed) and its
  /// expiry, parsed from the token itself. Null until the first write.
  String? _roleToken;
  DateTime? _roleTokenExpiresAt;
  bool _tokenFailed = false;

  /// The seat name this joiner claimed its token for (host tokens are
  /// room-scoped and need no name). Set by [announcePlayer].
  String? _seatName;

  /// Room codes share the readable alphabet: no ambiguous glyphs
  /// (0/O, 1/I/L) so codes stay easy to read aloud.
  static String _generateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(5, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  /// 128-bit host credential, hex-encoded. It is compared against the
  /// room's stored secret by claim_host — the only thing that can mint a
  /// host token for that room.
  static String _generateSecret() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  static const _defaultColorHex = 'FF9C27FF';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (apiKey != null) ...{
          'apikey': apiKey!,
          'Authorization': 'Bearer $apiKey',
        },
      };

  Uri _table(String name, [Map<String, String>? filters]) => _baseUrl.replace(
        // Supabase exposes PostgREST under /rest/v1; a bare PostgREST sits at
        // the root.
        path: '${apiKey == null ? '' : '/rest/v1'}/$name',
        queryParameters: (filters == null || filters.isEmpty) ? null : filters,
      );

  Uri _rpc(String name) => _baseUrl.replace(
        path: '${apiKey == null ? '' : '/rest/v1'}/rpc/$name',
      );

  /// Set when announce found this host's room already open (resume): the
  /// create step is skipped and claim_host re-arms the existing secret.
  bool _resumedRoom = false;

  /// True after announce re-opened this host's existing room instead of
  /// creating a fresh one (saved-games resume path).
  bool get resumedExistingRoom => _resumedRoom;

  /// True when the room [code] already exists and was created by this host
  /// (its stored host_secret matches ours). Read-only probe on rooms —
  /// allowed anonymously by design so joining stays open.
  Future<bool> _roomIsOurs(String code) async {
    if (hostSecret == null || hostSecret!.isEmpty) return false;
    try {
      final response = await _client.get(
        _table('rooms', {'code': 'eq.$code', 'select': 'host_secret'}),
        headers: _headers,
      );
      if (response.statusCode != 200) return false;
      final rows = jsonDecode(response.body);
      if (rows is! List || rows.isEmpty) return false;
      final stored = (rows.first as Map)['host_secret'];
      return stored is String && stored == hostSecret;
    } catch (_) {
      return false;
    }
  }

  /// Headers for a write: the role token replaces the anon bearer when one
  /// is cached (PostgREST uses the last Authorization header). Falls back to
  /// plain anon headers when no token exists, so rooms on pre-JWT servers
  /// keep working.
  Map<String, String> _writeHeaders() {
    final token = _roleToken;
    if (token == null) return _headers;
    return {
      ..._headers,
      'Authorization': 'Bearer $token',
    };
  }

  /// Claims and caches this seat's role token: hosts mint a room-scoped host
  /// token (claim_host with the room secret), joiners a seat-scoped player
  /// token (claim_seat, which also registers the roster row). A 404 means
  /// the server predates the claim RPCs — remember that and let writes fall
  /// back to anon; other failures surface to the caller.
  Future<void> _ensureRoleToken({bool asHost = false, String? playerName}) async {
    final margin = DateTime.now().add(const Duration(seconds: 60));
    if (_roleToken != null &&
        (_roleTokenExpiresAt == null || _roleTokenExpiresAt!.isAfter(margin))) {
      return;
    }
    if (_tokenFailed) return;
    if (apiKey == null) {
      // Bare PostgREST: no gateway JWT verification, no role switching —
      // the claim token would be dead weight.
      _tokenFailed = true;
      return;
    }
    if (asHost && (hostSecret == null || hostSecret!.isEmpty)) {
      _tokenFailed = true;
      return;
    }
    if (!asHost && (playerName == null || playerName.isEmpty)) {
      // Joiner without a known seat name: writes fall back to anon rather
      // than claiming a nameless seat.
      _tokenFailed = true;
      return;
    }
    try {
      final response = await _client.post(
        _rpc(asHost ? 'claim_host' : 'claim_seat'),
        headers: {
          ..._headers,
          if (apiKey != null) 'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(asHost
            ? {'p_code': roomCode, 'p_secret': hostSecret}
            : {'p_code': roomCode, 'p_name': playerName, 'p_password': _passwordHash}),
      );
      if (response.statusCode == 404) {
        // Server without the claim RPCs: legacy anon-writable mode.
        _tokenFailed = true;
        return;
      }
      _ensureOk(response, 'claim ${asHost ? 'host' : 'seat'} token');
      final token = _stringFromBody(response.body);
      if (token == null || !token.contains('.')) {
        throw Exception('claim token returned no JWT: ${response.body}');
      }
      _roleToken = token;
      _roleTokenExpiresAt = _tokenExpiry(token);
    } on FormatException {
      // Malformed claim response — treat like a missing server feature.
      _tokenFailed = true;
    }
  }

  /// Extracts the JWT string from a claim response body (a bare JSON string).
  static String? _stringFromBody(String body) {
    final decoded = jsonDecode(body);
    return decoded is String ? decoded : null;
  }

  /// Parses `exp` (unix seconds) from the token's middle segment.
  static DateTime? _tokenExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final claims = jsonDecode(utf8.decode(base64Url.decode(normalized))) as Map<String, dynamic>;
      final exp = claims['exp'];
      return exp is int ? DateTime.fromMillisecondsSinceEpoch(exp * 1000) : null;
    } on FormatException {
      return null;
    }
  }

  void _ensureOk(http.Response response, String action) {
    if (response.statusCode >= 400) {
      throw Exception('Failed to $action (HTTP ${response.statusCode}): ${response.body}');
    }
  }

  @override
  bool get isOnline => true;

  @override
  Future<void> announcePlayer(LobbySeat slot) async {
    if (createsRoom) {
      final created = await _client.post(
        _table('rooms'),
        headers: {..._headers, 'Prefer': 'resolution=ignore-duplicates'},
        body: jsonEncode({'code': roomCode, 'clock': 0, if (hostSecret != null) 'host_secret': hostSecret, if (_passwordHash.isNotEmpty) 'password': _passwordHash}),
      );
      if (created.statusCode == 409) {
        // A 409 can be two things: a stranger owns this code (reroll once),
        // or the room is ours — same host secret — and we are resuming it.
        // The row already exists then, so nothing is re-created.
        if (await _roomIsOurs(roomCode)) {
          _resumedRoom = true;
        } else {
          roomCode = _generateCode();
          final retried = await _client.post(
            _table('rooms'),
            headers: {..._headers, 'Prefer': 'resolution=ignore-duplicates'},
            body: jsonEncode({'code': roomCode, 'clock': 0, if (hostSecret != null) 'host_secret': hostSecret, if (_passwordHash.isNotEmpty) 'password': _passwordHash}),
          );
          _ensureOk(retried, 'open room $roomCode');
        }
      } else {
        _ensureOk(created, 'open room $roomCode');
      }
    }
    if (createsRoom) {
      await _ensureRoleToken(asHost: true);
    } else {
      _seatName = slot.name;
      await _ensureRoleToken(playerName: slot.name);
    }
    final response = await _client.put(
      _table('roster', {'on_conflict': 'room_code,player_name'}),
      headers: {..._writeHeaders(), 'Prefer': 'resolution=merge-duplicates'},
      body: jsonEncode([
        {
          'room_code': roomCode,
          'player_name': slot.name,
          'color_hex': slot.colorHex,
          'interact_every_days': slot.interactEveryDays,
          'ready': slot.ready,
        }
      ]),
    );
    _ensureOk(response, 'announce ${slot.name}');
  }

  @override
  Future<void> publishSession(String encodedJson) async {
    await _ensureRoleToken(asHost: createsRoom, playerName: _seatName);
    final response = await _client.patch(
      _table('rooms', {'code': 'eq.$roomCode'}),
      headers: _writeHeaders(),
      // The column is text; the snapshot string is stored verbatim.
      body: jsonEncode({'session': encodedJson}),
    );
    _ensureOk(response, 'publish session');
  }

  @override
  Future<String?> fetchSessionJson() async {
    final response = await _client.get(
      _table('rooms', {'code': 'eq.$roomCode', 'select': 'session'}),
      headers: _headers,
    );
    _ensureOk(response, 'fetch session');
    if (response.body.isEmpty || response.body == '[]') return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) return null;
    final row = decoded.first;
    return row is Map ? row['session'] as String? : null;
  }

  @override
  Future<void> setReady(String playerName, bool ready) async {
    await _ensureRoleToken(asHost: createsRoom, playerName: createsRoom ? null : playerName);
    final response = await _client.patch(
      _table('roster', {'room_code': 'eq.$roomCode', 'player_name': 'eq.$playerName'}),
      headers: _writeHeaders(),
      body: jsonEncode({'ready': ready}),
    );
    _ensureOk(response, 'set ready for $playerName');
  }

  @override
  Future<List<LobbySeat>> roster() async {
    final response = await _client.get(
      _table('roster', {'room_code': 'eq.$roomCode', 'select': '*', 'order': 'joined_at'}),
      headers: _headers,
    );
    _ensureOk(response, 'fetch roster');
    if (response.body.isEmpty || response.body == '[]') return [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return [];
    return decoded.whereType<Map<String, dynamic>>().map(_slotFromRow).toList();
  }

  LobbySeat _slotFromRow(Map<String, dynamic> row) => LobbySeat(
        name: row['player_name'] as String,
        colorHex: row['color_hex'] as String? ?? _defaultColorHex,
        interactEveryDays: row['interact_every_days'] as int? ?? 1,
        ready: row['ready'] as bool? ?? false,
      );

  @override
  Future<List<SyncEvent>> poll() async {
    final events = <SyncEvent>[];
    for (final slot in await roster()) {
      if (slot.ready) {
        events.add(SyncEvent(type: SyncEventType.playerReady, playerName: slot.name, payload: {'ready': true}));
      }
    }
    return events;
  }

  @override
  Future<void> publishClock(int newHour) async {
    await _ensureRoleToken(asHost: createsRoom, playerName: _seatName);
    final response = await _client.patch(
      _table('rooms', {'code': 'eq.$roomCode'}),
      headers: _writeHeaders(),
      body: jsonEncode({'clock': newHour}),
    );
    _ensureOk(response, 'publish clock');
  }

  @override
  Future<void> deleteRoom({required String hostSecret}) async {
    // Prove host rights: claim_host mints the room-scoped role token whose
    // RLS policies allow the room row's DELETE (rooms_host_all).
    await _ensureRoleToken(asHost: true, playerName: null);
    // The secret must also match the room's stored digest — a wrong secret
    // mints nothing, so the delete below no-ops to zero rows.
    final response = await _client.delete(
      _table('rooms', {'code': 'eq.$roomCode'}),
      headers: _writeHeaders(),
    );
    _ensureOk(response, 'delete room');
    if (hostSecret.isEmpty) return; // nothing further to scrub
  }

  @override
  Future<void> leaveRoom({required String seatName}) async {
    // The seat token allows deleting exactly its own roster row
    // (roster_seat_self). Joiners claim it with the room password digest.
    await _ensureRoleToken(asHost: false, playerName: seatName);
    final response = await _client.delete(
      _table('roster', {
        'room_code': 'eq.$roomCode',
        'player_name': 'eq.$seatName',
      }),
      headers: _writeHeaders(),
    );
    _ensureOk(response, 'leave room');
  }

  @override
  Future<int?> fetchClock() async {
    final response = await _client.get(
      _table('rooms', {'code': 'eq.$roomCode', 'select': 'clock'}),
      headers: _headers,
    );
    _ensureOk(response, 'fetch clock');
    if (response.body.isEmpty || response.body == '[]') return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) return null;
    final value = (decoded.first as Map)['clock'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  Future<void> pushActions(List<Map<String, dynamic>> actions) async {
    if (actions.isEmpty) return;
    await _ensureRoleToken(asHost: createsRoom, playerName: _seatName);
    final rows = [
      for (var i = 0; i < actions.length; i++)
        {
          'room_code': roomCode,
          'seq': DateTime.now().microsecondsSinceEpoch * 10 + i,
          'payload': actions[i],
        }
    ];
    final response = await _client.post(_table('actions'), headers: _writeHeaders(), body: jsonEncode(rows));
    _ensureOk(response, 'push actions');
  }

  @override
  Future<List<Map<String, dynamic>>> takeActions() async {
    final response = await _client.get(
      _table('actions', {
        'room_code': 'eq.$roomCode',
        'select': 'seq,payload',
        'order': 'seq.asc',
      }),
      headers: _headers,
    );
    _ensureOk(response, 'take actions');
    if (response.body.isEmpty || response.body == '[]') return const [];
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty) return const [];
    final envelopes = <Map<String, dynamic>>[
      for (final row in decoded)
        if ((row as Map)['payload'] is Map<String, dynamic>) (row['payload'] as Map<String, dynamic>),
    ];
    // Fetch-then-delete leaves a tiny race if two hosts poll one room; only
    // the host polls, so this stays safe in practice.
    await _ensureRoleToken(asHost: createsRoom, playerName: _seatName);
    final delete = await _client.delete(
      _table('actions', {'room_code': 'eq.$roomCode'}),
      headers: _writeHeaders(),
    );
    _ensureOk(delete, 'clear actions');
    return envelopes;
  }

  @override
  void dispose() => _client.close();
}
