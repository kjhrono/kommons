import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

/// HERALD's NEW-GAME section — the moment the shared shell hands over.
/// The [SharedLobbyHandoff] carries the table (this device's seat, the
/// rest of the roster, the room code when online); from here a real game
/// would build its world. This reference just shows what arrived, which
/// is exactly what a probe is for.
class ProbeGameScreen extends StatelessWidget {
  const ProbeGameScreen(this.handoff, {super.key});

  /// What the shared lobby handed over.
  final SharedLobbyHandoff handoff;

  String get _modeLine {
    if (handoff.online) {
      return 'Online room ${handoff.roomCode} — '
          '${handoff.seats.length + 1} heralds at the table.';
    }
    if (handoff.seats.isEmpty) {
      return 'Solo walk: one herald on the road.';
    }
    return 'Hot-seat table — ${handoff.seats.length + 1} heralds share this device.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        key: const ValueKey('herald-game-screen'),
        title: const Text('HERALD'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text("The shell's work ends here — the game begins.",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('Playing as: ${handoff.self.name}',
                  key: const ValueKey('herald-self')),
              Text(_modeLine, key: const ValueKey('herald-mode')),
              const SizedBox(height: 12),
              for (final seat in handoff.seats)
                ListTile(
                  key: ValueKey('herald-seat-${seat.name}'),
                  leading: CircleAvatar(backgroundColor: seat.color, radius: 12),
                  title: Text(seat.name),
                ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                key: const ValueKey('herald-back-to-splash'),
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                icon: const Icon(Icons.arrow_back),
                label: const Text('BACK TO THE ROAD'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
