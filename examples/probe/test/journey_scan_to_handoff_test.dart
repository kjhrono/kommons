import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:probe/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The full scan-to-lobby journey, driven through the real probe app:
/// the splash's scan door opens the (seam-faked) camera, a successful read
/// jumps straight into the seat lobby — entry chooser skipped — with the
/// scanned code seated and locked and the join confirmation visible.
/// This is the path an invited player walks; every earlier test covers
/// one link of the chain, this one walks the chain.
void main() {
  setUp(() async {
    // The shell controllers are process-wide singletons (shared with the
    // commons' own tests): reset and preload with in-memory prefs so the
    // account read and locale see a clean slate.
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
    appTheme.value = ThemeMode.dark;
    await account.load();
  });

  testWidgets('splash scan lands in a locked lobby, the code reaches the game',
      (tester) async {
    // The camera: a friend's QR reads as game number K7QX2.
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.joined('K7QX2');
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(const ProbeApp());
    await tester.pump(); // first frame of the splash entrance
    await tester.pumpAndSettle();

    // Splash: HERALD's scan door is on stage beside the other actions.
    expect(find.byKey(const ValueKey('splash-scan-invite')), findsOneWidget);
    expect(find.byKey(const ValueKey('probe-lobby-step')), findsNothing);

    // The scan succeeds — and the chooser is skipped entirely: the
    // invited player lands directly in the shared seat lobby.
    await tester.tap(find.byKey(const ValueKey('splash-scan-invite')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-lobby-step')), findsOneWidget);
    expect(find.byKey(const ValueKey('probe-lobby-entry')), findsNothing);

    // The jump is visible: the confirmation names the table.
    expect(
        find.text(appLocale.strings.inviteJoinedAs('Player', 'K7QX2')),
        findsOneWidget);

    // The locked lobby: the scanned code is seated — visible in the
    // field, locked without a hand-typed join — and the local seat shows
    // the persona. The invite section renders the forwardable link.
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-game-number')));
    expect(field.enabled, isFalse);
    expect(field.controller!.text, 'K7QX2');
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Player')), findsOneWidget);
    final link = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-invite-link')));
    expect(link.controller!.text, contains('#join=K7QX2'));
  });
}
