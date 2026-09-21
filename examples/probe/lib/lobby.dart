import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

import 'game.dart';

/// HERALD's lobby: the shared [SharedLobbyStep] does all the work — this
/// game's NEW-GAME section is a single handoff callback away. One screen,
/// one callback: seats by game number, or solo, and the shell is done.
class ProbeLobby extends StatefulWidget {
  const ProbeLobby({super.key});

  @override
  State<ProbeLobby> createState() => _ProbeLobbyState();
}

class _ProbeLobbyState extends State<ProbeLobby> {
  void _handoff(SharedLobbyHandoff handoff) {
    Navigator.of(context, rootNavigator: true).pushReplacement(MaterialPageRoute(
      builder: (_) => ProbeGameScreen(handoff),
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
              SharedLobbyStep(
                key: const ValueKey('probe-lobby-step'),
                onHandoff: _handoff,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
