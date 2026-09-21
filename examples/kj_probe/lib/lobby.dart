import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

/// The probe's new-game wizard on the shared LobbyWizard: three steps
/// (seats → options → ready), zero scaffolding code of its own.
class ProbeLobby extends StatefulWidget {
  const ProbeLobby({super.key});

  @override
  State<ProbeLobby> createState() => _ProbeLobbyState();
}

enum _Step { seats, options, ready }

class _ProbeLobbyState extends State<ProbeLobby> {
  _Step _step = _Step.seats;
  final _seats = <LobbySeat>[LobbySeat(name: 'Probe One', colorHex: bannerColorHex(Colors.teal))];

  void _goto(_Step s) => setState(() => _step = s);

  static const _descriptors = [
    LobbyStepDescriptor(title: 'Seats', icon: Icons.groups_outlined,
        subtitle: 'Who marches under this banner.'),
    LobbyStepDescriptor(title: 'Options', icon: Icons.tune,
        subtitle: 'Probe-specific game options live here.'),
    LobbyStepDescriptor(title: 'Ready?', icon: Icons.rocket_launch,
        subtitle: 'One last look before the probe starts.'),
  ];

  @override
  Widget build(BuildContext context) {
    return LobbyWizard(
      title: 'KJ PROBE',
      steps: _descriptors,
      current: _step.index,
      onGoto: (i) => _goto(_Step.values[i]),
      body: switch (_step) {
        _Step.seats => _seatsBody(),
        _Step.options => const [Text('Probe options would go here.')],
        _Step.ready => [
            const Text('Seats configured:'),
            for (final seat in _seats) Text('• ${seat.name}'),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('probe-start'),
              onPressed: () {},
              icon: const Icon(Icons.rocket_launch),
              label: const Text('START PROBE'),
            ),
          ],
      },
    );
  }

  List<Widget> _seatsBody() => [
        const Text('PLAYERS',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        for (final seat in _seats)
          ListTile(
            key: ValueKey('probe-seat-${seat.name}'),
            leading: CircleAvatar(backgroundColor: seat.color, radius: 12),
            title: Text(seat.name),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('probe-add-seat'),
          onPressed: () => setState(() => _seats.add(LobbySeat(
              name: 'Probe ${_seats.length + 1}',
              colorHex: bannerColorHex(Colors.primaries[_seats.length * 3])))),
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Add seat'),
        ),
      ];
}
