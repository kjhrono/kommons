import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

import 'game.dart';

/// HERALD's NEW-GAME flow, showing the shell's two-stage lobby: the shared
/// entry ([SharedLobbyEntry]) proposes the player's name and offers the
/// two doors; MULTI-PLAYER lands in [SharedLobbyStep], the seat-and-invite
/// lobby; SINGLE-PLAYER skips straight to the game screen with a fresh
/// offline handoff. One screen each, one callback each — the shell's work
/// ends where the game's NEW-GAME section begins.
class ProbeLobby extends StatefulWidget {
  const ProbeLobby({super.key, this.initialCode});

  /// A game number arriving with the navigation — from an invite link the
  /// player opened ([ShellApp.onJoinInvite]) or a pasted one. Non-null
  /// skips the entry chooser: an invited player lands directly in the
  /// seat lobby with the number already committed.
  final String? initialCode;

  @override
  State<ProbeLobby> createState() => _ProbeLobbyState();
}

class _ProbeLobbyState extends State<ProbeLobby> {
  void _handoff(SharedLobbyHandoff handoff) {
    Navigator.of(context, rootNavigator: true)
        .pushReplacement(MaterialPageRoute(
      builder: (_) => ProbeGameScreen(handoff),
    ));
  }

  void _enterMulti(String name) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => _ProbeSeatLobby(initialCode: widget.initialCode),
    ));
  }

  void _enterSingle(String name) {
    _handoff(SharedLobbyHandoff(
      // The persona the entry proposed (and possibly just renamed).
      self: LobbySeat(name: name, colorHex: nextFreeBannerColorHex()),
      seats: const [],
      roomCode: null,
      online: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HERALD')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              SharedLobbyEntry(
                key: const ValueKey('probe-lobby-entry'),
                onSinglePlayer: _enterSingle,
                onMultiPlayer: _enterMulti,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The seat lobby stage — [SharedLobbyStep] with HERALD's handoff wired.
class _ProbeSeatLobby extends StatelessWidget {
  const _ProbeSeatLobby({this.initialCode});

  final String? initialCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HERALD')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              SharedLobbyStep(
                key: const ValueKey('probe-lobby-step'),
                onHandoff: (handoff) {
                  Navigator.of(context, rootNavigator: true)
                      .pushReplacement(MaterialPageRoute(
                    builder: (_) => ProbeGameScreen(handoff),
                  ));
                },
                initialCode: initialCode,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
