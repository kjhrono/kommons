import 'package:flutter/material.dart';

import 'package:kommons/kommons.dart';

import 'game.dart';
import 'lobby.dart';

void main() {
  runApp(const ProbeApp());
}

/// HERALD — the probe game: a second kjhrono consumer of the commons shell.
///
/// A herald walks the shared road ahead of every banner; this small game
/// does the same for the package, proving the road (splash, top bar,
/// settings, OAuth, lobby wizard) holds before the flagships march onto it.
/// Everything before "game starts" is the shared package — ShellApp owns
/// the MaterialApp wiring; this file adds only what makes HERALD a
/// distinct game: its seed color, description, flavor deck, and the two
/// destinations (lobby and settings). The package name stays `probe`
/// (folders, keys, imports) — HERALD is the game's face, probe is its job.
class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  static const _seed = Color(0xff7a5c2e); // amber-brown: HERALD's own color

  @override
  Widget build(BuildContext context) {
    return ShellApp(
      title: 'HERALD',
      seedColor: _seed,
      home: const ProbeHome(),
      // Invites: a join link (…#join=K7QX2) opened on any platform lands
      // in the shared lobby with the number already locked in.
      onJoinInvite: (invite) => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => ProbeLobby(initialCode: invite.code),
        ),
      ),
      // HERALD keeps its amber-brown palettes over the default seeded
      // theme: the builder seam is where a game's custom colors live.
      themeBuilder: (context, brightness) => ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
        scaffoldBackgroundColor: brightness == Brightness.dark
            ? const Color(0xff171310)
            : const Color(0xfff7f2ea),
        useMaterial3: true,
      ),
    );
  }
}

class ProbeHome extends StatelessWidget {
  const ProbeHome({super.key});

  /// The shell's two front doors, demonstrated side by side: PLAY enters
  /// the app directly (HERALD is playable solo), NEW GAME opens the shared
  /// lobby for a multiplayer table.

  /// The herald's beat: one line per stretch of the shared road, each acted
  /// out by a vignette the shell ships. A revisit rolls a fresh scene.
  static const _scenes = [
    SplashScene(
      line: 'Two banners share one road — and the road holds beneath them.',
      vignette: 'packages/kommons/assets/splash_caravan.svg',
      story: 'A caravan proving the shared road',
    ),
    SplashScene(
      line:
          'Word from the crypts beneath the pass: the dead keep their own clock.',
      vignette: 'packages/kommons/assets/splash_dungeon.svg',
      story: "A torch-lit gate over a crypt the herald must report on",
    ),
    SplashScene(
      line: 'The wild listens for the horn before any banner dares the ford.',
      vignette: 'packages/kommons/assets/splash_tame.svg',
      story: "A griffin answering the herald's horn",
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppSplash(
      appName: 'HERALD',
      description:
          'A herald walks the road ahead of the banners, and reports what the road will bear. This one carries the shared shell.',
      scenes: _scenes,
      actions: SplashActions.directAndNewGame,
      continueEnabled: false, // nothing to load yet — HERALD starts fresh
      onDirect: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProbeGameScreen(SharedLobbyHandoff(
            // A real game reads the persisted persona here; HERALD shows
            // the pattern: persisted name, a free banner color, offline.
            self: LobbySeat(
                name: account.playerName, colorHex: nextFreeBannerColorHex()),
            seats: const [],
            roomCode: null,
            online: false,
          )),
        ),
      ),
      onNewGame: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProbeLobby()),
      ),
      // Scan-to-join from the splash itself: a friend shows their QR, the
      // phone reads it, and the seat lobby opens with the number already
      // seated and locked — the chooser is skipped for invited players.
      onScanInvite: (code) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ProbeLobby(initialCode: code)),
      ),
      // The reference OAuth wiring: the Google/GitHub buttons go live
      // through the game server's hosted web flow.
      settingsBuilder: () => SettingsScreen(
        gameId: 'probe',
        oauthProviders: oauthPopupHandlers(),
      ),
    );
  }
}
