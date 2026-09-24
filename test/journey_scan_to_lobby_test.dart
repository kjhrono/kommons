import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The package-level mirror of the probe's journey, with the probe's game
/// code stripped out: a ShellApp host whose splash scan door reads a
/// friend's QR (executor faked) and lands the player straight in a
/// Scaffold-wrapped `SharedLobbyStep` — the wiring COMMONS.md prescribes,
/// nothing more. If this passes, the journey works for every game that
/// adopts the shell; the probe's own test only re-proves it with HERALD's
/// identity on top.
void main() {
  setUp(() async {
    // The shell controllers are process-wide singletons (shared with the
    // other package tests): reset and preload with in-memory prefs.
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
    appTheme.value = ThemeMode.dark;
    await account.load();
  });

  testWidgets('ShellApp → splash scan → locked lobby with the code seated',
      (tester) async {
    // The camera: a friend's QR reads as game number K7QX2.
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.joined('K7QX2');
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(const _JourneyApp());
    await tester.pump(); // first frame of the splash entrance
    await tester.pumpAndSettle();

    // The splash carries the scan door; no lobby exists yet.
    expect(find.byKey(const ValueKey('splash-scan-invite')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-lobby-step')), findsNothing);

    // The scan succeeds — the host callback runs, the lobby lands with
    // the scanned code already committed (no chooser in this journey).
    await tester.tap(find.byKey(const ValueKey('splash-scan-invite')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-lobby-step')), findsOneWidget);

    // The jump is visible: the arrival confirmation names table + persona.
    expect(find.text(appLocale.strings.inviteJoinedAs('Player', 'K7QX2')),
        findsOneWidget);

    // The locked lobby: the code is seated — visible in the field, locked
    // without a hand-typed join — and the local seat shows the persona.
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-game-number')));
    expect(field.enabled, isFalse);
    expect(field.controller!.text, 'K7QX2');
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Player')), findsOneWidget);

    // The invite section renders the forwardable link.
    final link = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-invite-link')));
    expect(link.controller!.text, contains('#join=K7QX2'));
  });
}

/// The minimal host of the journey: ShellApp + splash + the documented
/// scan callback. This is the entire "game" the journey needs.
class _JourneyApp extends StatelessWidget {
  const _JourneyApp();

  @override
  Widget build(BuildContext context) {
    return ShellApp(
      title: 'Journey',
      seedColor: Colors.teal,
      home: const _JourneySplash(),
    );
  }
}

class _JourneySplash extends StatelessWidget {
  const _JourneySplash();

  @override
  Widget build(BuildContext context) {
    return AppSplash(
      appName: 'Journey',
      description: 'the package-level scan journey',
      actions: SplashActions.directAndNewGame,
      onDirect: () {},
      onScanInvite: (code) => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('NEW GAME')),
            body: SharedLobbyStep(onHandoff: (_) {}, initialCode: code),
          ),
        ),
      ),
    );
  }
}
