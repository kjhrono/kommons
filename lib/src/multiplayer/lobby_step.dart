import 'package:flutter/material.dart';

import '../app_settings.dart' show account, appLocale;
import 'banner_color_picker.dart';
import 'lobby_seat.dart';

/// Everything the host app needs to take over: this device's seat, the rest
/// of the table, the shared room code ([GameSyncService.roomCode] reads it
/// back), and whether the game starts online at all.
class SharedLobbyHandoff {
  const SharedLobbyHandoff({
    required this.self,
    required this.seats,
    required this.roomCode,
    required this.online,
  });

  /// The persona the local player will play as.
  final LobbySeat self;

  /// Every other seat at the table (never contains [self]); empty in solo.
  final List<LobbySeat> seats;

  /// The shared room's short code — null when [online] is false.
  final String? roomCode;

  /// False for solo/hot-seat games (no server in the loop).
  final bool online;
}

/// One entry of the roster editor: a [LobbySeat] chip plus its remove button.
class _SeatRow extends StatelessWidget {
  const _SeatRow({required this.seat, this.isSelf = false, this.onRemove});

  final LobbySeat seat;
  final bool isSelf;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
          child: Chip(
            key: ValueKey('shared-lobby-seat-${seat.name}'),
            avatar: CircleAvatar(
              backgroundColor: seat.color,
              child: Text(
                seat.name.isNotEmpty ? seat.name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            label: Text(seat.name),
          ),
        ),
        if (!isSelf && onRemove != null)
          IconButton(
            key: ValueKey('shared-lobby-remove-${seat.name}'),
            tooltip: strings.removeSeatTooltip,
            onPressed: onRemove,
            icon: const Icon(Icons.person_remove_outlined),
          ),
        if (isSelf)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(strings.youMarker,
                style: Theme.of(context).textTheme.bodySmall),          ),
      ]),
    );
  }
}

/// The shared, app-agnostic first screen of a hosted multiplayer game: a
/// seat for the local player, extra seats joined by entering the host's
/// game number, or an explicitly solo start. Exactly one callback —
/// [onHandoff] — carries everything the game needs into its NEW-GAME
/// section, where the shell's responsibility ends.
///
/// The roster lives in the widget's own state: add a seat, it appears under
/// the local player; remove it and the game number unlocks for the next
/// join. The widget deliberately knows nothing about the game itself —
/// colors come from the shared [nextFreeBannerColorHex] picker so the seats'
/// banners stay distinct.
class SharedLobbyStep extends StatefulWidget {
  const SharedLobbyStep({super.key, required this.onHandoff});

  /// Fired exactly once, when the player starts the game (solo, hot-seat,
  /// or online). The game's NEW-GAME section receives the handoff and
  /// creates its world.
  final ValueChanged<SharedLobbyHandoff> onHandoff;

  @override
  State<SharedLobbyStep> createState() => _SharedLobbyStepState();
}

class _SharedLobbyStepState extends State<SharedLobbyStep> {
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  final _guests = <LobbySeat>[];
  String? _codeError;
  bool _joining = false;

  /// The game number the seats joined with. Kept in state (not the field,
  /// which clears after a join) so the handoff still carries the code.
  String? _joinedCode;

  @override
  void dispose() {
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// This device's seat: the persisted player's name (falling back to the
  /// localized default) carrying the next free banner color.
  LobbySeat get _self => LobbySeat(
        name: account.playerName,
        colorHex: nextFreeBannerColorHex(taken: const {}),
      );

  List<LobbySeat> get _everyone => [_self, ..._guests];

  Future<void> _addSeat() async {
    final strings = appLocale.strings;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _codeError = strings.gameNumberMissing);
      _codeFocus.requestFocus();
      return;
    }
    setState(() {
      _codeError = null;
      _joining = true;
    });
    final taken = _everyone.map((s) => s.colorHex).toSet();
    final guest = LobbySeat(
      name: '${strings.guest} ${_guests.length + 2}',
      colorHex: nextFreeBannerColorHex(taken: taken),
    );
    // The join keeps its own focus on the form: either the seat is added
    // and the number locks (the game's actual invite flow talks to the
    // server when the game starts), or the error explains what to fix.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() {
      _joining = false;
      _joinedCode = code;
      _guests.add(guest);
      _codeController.clear();
    });
  }

  void _removeSeat(LobbySeat seat) => setState(() => _guests.remove(seat));

  void _startSolo() => widget.onHandoff(SharedLobbyHandoff(
        self: _self,
        seats: const [],
        roomCode: null,
        online: false,
      ));

  void _startOnline() {
    if (_guests.isEmpty) return;
    widget.onHandoff(SharedLobbyHandoff(
      self: _self,
      seats: List.unmodifiable(_guests),
      roomCode: _joinedCode,
      online: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    return Column(
      key: const ValueKey('shared-lobby-step'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(strings.seatsHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _SeatRow(seat: _self, isSelf: true),
        for (final guest in _guests)
          _SeatRow(seat: guest, onRemove: () => _removeSeat(guest)),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('shared-lobby-game-number'),
          controller: _codeController,
          focusNode: _codeFocus,
          enabled: _guests.isEmpty && !_joining,
          decoration: InputDecoration(
            labelText: strings.gameNumberLabel,
            hintText: strings.gameNumberHint,
            errorText: _codeError,
            prefixIcon: const Icon(Icons.numbers),
          ),
          onSubmitted: (_) => _addSeat(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            key: const ValueKey('shared-lobby-add-seat'),
            onPressed: (_guests.isEmpty && !_joining) ? _addSeat : null,
            icon: _joining
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.group_add),
            label: Text(strings.addSeat),
          ),
        ),
        const SizedBox(height: 16),
        Text(strings.hotSeatNote,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('shared-lobby-start-online'),
          onPressed: _guests.isEmpty ? null : _startOnline,
          icon: const Icon(Icons.sensors),
          label: Text(strings.joinGame),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('shared-lobby-start-solo'),
          onPressed: _startSolo,
          icon: const Icon(Icons.person),
          label: Text(strings.soloStart),
        ),
      ],
    );
  }
}
