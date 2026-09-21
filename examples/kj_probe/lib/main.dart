import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

import 'lobby.dart';

void main() {
  runApp(const KjProbeApp());
}

/// The probe game: a second kjhrono consumer of the commons shell.
///
/// Everything before "game starts" is the shared package — the splash (art,
/// welcome, entrance animation, buttons), the top bar, the settings screen
/// with the account/auth card, the persisted day/night theme, and the lobby
/// wizard. This file adds only what makes it a distinct game: its name,
/// seed color, description, flavor deck, and the two destinations (lobby
/// and settings).
class KjProbeApp extends StatelessWidget {
  const KjProbeApp({super.key});

  static const _seed = Color(0xff7a5c2e); // amber-brown: visibly not kapax

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appTheme,
      builder: (context, _) {
        final dark = ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xff171310),
          useMaterial3: true,
        );
        final light = ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xfff7f2ea),
          useMaterial3: true,
        );
        return MaterialApp(
          title: 'KJ Probe',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
          themeMode: appTheme.value,
          home: const ProbeHome(),
        );
      },
    );
  }
}

class ProbeHome extends StatelessWidget {
  const ProbeHome({super.key});

  static const _scenes = [
    SplashScene(
      line: 'Two banners sharing one shell — the commons at work.',
      vignette: 'packages/kommons/assets/splash_caravan.svg',
      story: 'A caravan proving the shared road',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppSplash(
      appName: 'KJ PROBE',
      description: 'A reuse probe for the kommons shell',
      scenes: _scenes,
      continueEnabled: false, // nothing to load yet — the probe starts fresh
      onNewGame: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProbeLobby()),
      ),
      settingsBuilder: () => const SettingsScreen(gameId: 'kj_probe'),
    );
  }
}
