import 'package:flutter/material.dart';

import '../app_settings.dart' show account, appLocale;
import 'lobby_step.dart';

/// The shared NEW-GAME entry, the first screen of the shell's lobby flow.
/// It proposes the player's persisted name (editable — this is the last
/// natural moment to adjust it before sitting at a table) and offers the
/// two front doors: SINGLE-PLAYER hands [onSinglePlayer] straight to the
/// game — no seats, no numbers — while MULTI-PLAYER lands in
/// [SharedLobbyStep], the seat-and-invite lobby. Hosts wire both with one
/// callback each; a game without one of the modes passes a handler that
/// pops instead (the button is then simply not shown).
///
/// The name persists through `account.setPlayerName` on either door, so
/// the game and the settings screen both see the final choice — the entry
/// never stores a second copy of it.
class SharedLobbyEntry extends StatefulWidget {
  const SharedLobbyEntry({
    super.key,
    required this.onSinglePlayer,
    required this.onMultiPlayer,
  });

  /// Fired by SINGLE-PLAYER with the (possibly just-edited) name: the
  /// project wires its single-player screen here.
  final ValueChanged<String> onSinglePlayer;

  /// Fired by MULTI-PLAYER with the name: the host navigates to
  /// [SharedLobbyStep], whose roster then proposes the same persona.
  final ValueChanged<String> onMultiPlayer;

  @override
  State<SharedLobbyEntry> createState() => _SharedLobbyEntryState();
}

class _SharedLobbyEntryState extends State<SharedLobbyEntry> {
  late final TextEditingController _name =
      TextEditingController(text: account.playerName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Records the name exactly once per press and runs the mode's door.
  /// A blank field keeps the persisted name (or the shell default) — the
  /// proposal is a starting point, never an empty seat.
  Future<void> _go(bool single) async {
    final text = _name.text.trim();
    if (text.isNotEmpty && text != account.playerName) {
      await account.setPlayerName(text);
    }
    final name = account.playerName;
    if (!mounted) return;
    if (single) {
      widget.onSinglePlayer(name);
    } else {
      widget.onMultiPlayer(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    return SingleChildScrollView(
      child: Column(
        key: const ValueKey('shared-lobby-entry'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('shared-lobby-entry-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: strings.lobbyNameLabel,
              hintText: strings.lobbyNameHint,
              prefixIcon: const Icon(Icons.person_outline),
            ),
            // Enter deliberately does nothing: a mode button is the only
            // way through, so a stray keypress never picks a door.
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('shared-lobby-entry-single'),
            onPressed: () => _go(true),
            icon: const Icon(Icons.person),
            label: Text(strings.lobbySingle),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const ValueKey('shared-lobby-entry-multi'),
            onPressed: () => _go(false),
            icon: const Icon(Icons.groups),
            label: Text(strings.lobbyMulti),
          ),
        ],
      ),
    );
  }
}
