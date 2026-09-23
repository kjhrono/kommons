import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probe/main.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    // The shell controllers are process-wide singletons (shared with the
    // commons' own tests): reset and preload with in-memory prefs so the
    // account read and theme persistence see a clean slate.
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appTheme.value = ThemeMode.dark;
    await account.load();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProbeApp());
    await tester.pump(); // first frame of the splash entrance
    await tester.pumpAndSettle();
  }

  testWidgets('boots the shared splash as its own game', (tester) async {
    await pumpApp(tester);

    // The splash renders with HERALD's own identity. The flavor
    // deck has three scenes and the splash rolls one at random — assert
    // that one of them is on stage, not a specific one.
    expect(find.text('HERALD'), findsOneWidget);
    expect(find.text('Welcome, Player, to HERALD'), findsOneWidget);
    expect(
        find.textContaining(RegExp(
            'Two banners share one road|Word from the crypts|The wild listens for the horn')),
        findsOneWidget);
    // PLAY leads, NEW GAME follows; the Continue slot is a direct-mode
    // casualty — there is nothing to load yet, and the lobby owns multi.
    expect(find.byKey(const ValueKey('splash-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-continue')), findsNothing);
  });

  testWidgets('PLAY enters the game directly in solo mode', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('splash-direct')));
    await tester.pumpAndSettle();

    // Direct entry skips the lobby entirely: HERALD's game screen receives
    // the offline handoff for the persisted persona.
    expect(find.byKey(const ValueKey('herald-game-screen')), findsOneWidget);
    expect(find.text('Playing as: Player'), findsOneWidget);
    expect(find.text('Solo walk: one herald on the road.'), findsOneWidget);
  });

  testWidgets('NEW GAME opens the shared lobby step and hands off to the game',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('splash-new-game')));
    await tester.pumpAndSettle();

    // The shared lobby step: the local seat with the persisted name, the
    // game-number field for joinable seats, and the two starts.
    expect(find.byKey(const ValueKey('probe-lobby-step')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Player')), findsOneWidget);

    // A join by game number adds the seat and locks the field.
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), '7');
    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-lobby-seat-Guest 2')),
        findsOneWidget);

    // One callback: the shared handoff lands in HERALD's game screen.
    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('herald-game-screen')), findsOneWidget);
    expect(find.text('Playing as: Player'), findsOneWidget);
    expect(
        find.text('Online room 7 — 2 heralds at the table.'), findsOneWidget);
    expect(find.byKey(const ValueKey('herald-seat-Guest 2')), findsOneWidget);
  });

  testWidgets('the gear opens the shared settings screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    // The shared ACCOUNT card renders with the reference OAuth wiring —
    // both provider buttons go live (the tap itself is exercised in the
    // package's oauth_flow_test). The provider row sits below the fold
    // in the default 800×600 test surface — scroll it into view.
    expect(find.text('ACCOUNT'), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('oauth-google')),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    final google = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('oauth-google')));
    expect(google.onPressed, isNotNull);
  });
}
