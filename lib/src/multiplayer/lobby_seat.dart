import 'package:flutter/material.dart';

/// A seat in a multiplayer lobby: the player's identity (name + banner
/// color), pacing and readiness. Game-agnostic — every kjhrono game's
/// lobby roster is a list of these.
class LobbySeat {
  LobbySeat({
    required this.name,
    this.colorHex = 'FF9C27FF',
    this.interactEveryDays = 1,
    this.ready = false,
    this.isAi = false,
    this.persona = '',
  });

  final String name;

  /// ARGB hex string (no leading 0x), e.g. FF9C27FF.
  String colorHex;

  /// Minimum days between this player's forced interactions: 1 = normal
  /// hot-seat pacing, higher values let slow players skip days without
  /// blocking the shared clock.
  int interactEveryDays;

  /// Whether this player has confirmed their actions for the current day.
  bool ready;

  /// True for simulated opponents (objectives mode races): they pick their
  /// contracts at world gen and complete them over time as the clock runs.
  bool isAi;

  /// The seat player's avatar setup as the game encodes it (opaque JSON,
  /// '' = none). Online joiners announce it so the host can spawn their
  /// hero exactly as they built it on their own device.
  String persona;

  Color get color => Color(
      int.parse(colorHex.length == 6 ? 'FF$colorHex' : colorHex, radix: 16));

  Map<String, dynamic> toMap() => {
        'name': name,
        'colorHex': colorHex,
        'interactEveryDays': interactEveryDays,
        'ready': ready,
        'isAi': isAi,
        if (persona.isNotEmpty) 'persona': persona,
      };

  static LobbySeat fromMap(Map<String, dynamic> data) => LobbySeat(
        name: data['name'] as String,
        colorHex: data['colorHex'] as String? ?? 'FF9C27FF',
        interactEveryDays: data['interactEveryDays'] as int? ?? 1,
        ready: data['ready'] as bool? ?? false,
        isAi: data['isAi'] as bool? ?? false,
        persona: data['persona'] as String? ?? '',
      );
}
