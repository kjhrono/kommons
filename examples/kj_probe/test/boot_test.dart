import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kj_probe/main.dart';
import 'package:kommons/kjhrono_commons.dart';
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
    await tester.pumpWidget(const KjProbeApp());
    await tester.pump(); // first frame of the splash entrance
    await tester.pumpAndSettle();
  }

  testWidgets('boots the shared splash as its own game', (tester) async {
    await pumpApp(tester);

    // The splash renders with the probe's identity, not kapax's.
    expect(find.text('KJ PROBE'), findsOneWidget);
    expect(find.text('Welcome, Player, to KJ PROBE'), findsOneWidget);
    expect(
        find.text('Two banners sharing one shell — the commons at work.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.text('NO SAVED GAMES'), findsOneWidget);
  });

  testWidgets('NEW GAME opens the shared lobby wizard and configures seats',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('splash-new-game')));
    await tester.pumpAndSettle();

    // The shared wizard frame, hosting probe steps.
    expect(find.text('KJ PROBE'), findsOneWidget);
    expect(find.text('Step 1 of 3 — Seats'), findsOneWidget);
    expect(find.text('Probe One'), findsOneWidget);

    // Adding a seat exercises the shared LobbySeat model.
    await tester.tap(find.byKey(const ValueKey('probe-add-seat')));
    await tester.pump();
    expect(find.text('Probe 2'), findsOneWidget);

    // The wizard's own nav walks the steps.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 3 — Options'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 3 — Ready?'), findsOneWidget);
    expect(find.byKey(const ValueKey('probe-start')), findsOneWidget);
  });

  testWidgets('the gear opens the shared settings screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    // The shared ACCOUNT card renders with the Google seam disabled (the
    // probe registers no handlers). The provider row sits below the fold
    // in the default 800×600 test surface — scroll it into view.
    expect(find.text('ACCOUNT'), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('oauth-google')),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    final google = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('oauth-google')));
    expect(google.onPressed, isNull);
  });
}
