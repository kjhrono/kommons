import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The splash's scan door: an optional button beside the splash actions
/// that opens the camera scanner (the same swappable seam the lobby uses)
/// and hands a parsed invite code to the host — who jumps straight into
/// the lobby with the number pre-seated. Covered: button visibility, the
/// three scan outcomes, and the probe's branch wiring is exercised
/// separately in the probe's own tests.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });

  Widget host(Widget child) => MaterialApp(home: child);

  AppSplash splash(
          {ValueChanged<String>? onScanInvite, VoidCallback? onNewGame}) =>
      AppSplash(
        appName: 'HERALD',
        description: 'test',
        actions: SplashActions.directAndNewGame,
        onDirect: () {},
        onNewGame: onNewGame,
        onScanInvite: onScanInvite,
      );

  testWidgets('no callback means no scan button (the old splash)',
      (tester) async {
    await tester.pumpWidget(host(splash(onNewGame: () {})));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('splash-scan-invite')), findsNothing);
    // The host's other actions are untouched.
    expect(find.byKey(const ValueKey('splash-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
  });

  testWidgets('a joined scan hands the code to the host', (tester) async {
    String? scanned;
    joinScanExecutor = ({required context, required scanLabel}) async {
      expect(scanLabel, 'Scan a friend’s QR');
      return const JoinScanResult.joined('K7QX2');
    };
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(host(splash(onScanInvite: (c) => scanned = c)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('splash-scan-invite')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('splash-scan-invite')));
    await tester.pumpAndSettle();

    expect(scanned, 'K7QX2');
  });

  testWidgets('dismissing the scanner stays quiet', (tester) async {
    var called = false;
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.dismissed();
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(host(splash(onScanInvite: (c) => called = true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('splash-scan-invite')));
    await tester.pumpAndSettle();

    expect(called, isFalse);
    // The splash itself is unharmed and still interactive.
    expect(find.byKey(const ValueKey('splash-scan-invite')), findsOneWidget);
  });

  testWidgets('a failed scan explains itself', (tester) async {
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.failed();
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(host(splash(onScanInvite: (_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('splash-scan-invite')));
    await tester.pumpAndSettle();

    expect(find.text('Camera unavailable — enter the number instead.'),
        findsOneWidget);
  });

  testWidgets('the scan button carries the last stagger slot', (tester) async {
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.dismissed();
    addTearDown(() => joinScanExecutor = scanJoinCodeWithCamera);

    await tester.pumpWidget(host(splash(
      onScanInvite: (c) {},
      onNewGame: () {},
    )));
    await tester.pumpAndSettle();

    // Both buttons exist and the row still holds them: the entrance
    // animation completed with the extra button in place.
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-scan-invite')), findsOneWidget);
  });
}
