import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

/// The splash's direct-entry behavior: PLAY (and the combined variant)
/// show/hide the right buttons, fire [AppSplash.onDirect], and honor
/// caption overrides.
void main() {
  Widget host(Widget child) => MaterialApp(home: child);

  testWidgets('direct mode: a single PLAY button fires onDirect',
      (tester) async {
    var entered = false;
    await tester.pumpWidget(host(AppSplash(
      appName: 'Personal Tool',
      description: 'd',
      actions: SplashActions.direct,
      onDirect: () => entered = true,
    )));
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsNothing);
    expect(find.byKey(const ValueKey('splash-continue')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('splash-direct')));
    await tester.pump();
    expect(entered, isTrue);
  });

  testWidgets('directAndNewGame: PLAY leads, NEW GAME follows, each fires once',
      (tester) async {
    var entered = false;
    var started = false;
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      actions: SplashActions.directAndNewGame,
      onDirect: () => entered = true,
      onNewGame: () => started = true,
    )));
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-continue')), findsNothing);
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.text('NUOVA PARTITA'), findsNothing,
        reason: 'the default catalog is English');

    await tester.tap(find.byKey(const ValueKey('splash-direct')));
    await tester.pump();
    expect(entered, isTrue);

    await tester.tap(find.byKey(const ValueKey('splash-new-game')));
    await tester.pump();
    expect(started, isTrue);
  });

  testWidgets('directLabel overrides the caption; classic modes stay unchanged',
      (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      actions: SplashActions.directAndNewGame,
      onDirect: () {},
      onNewGame: () {},
      directLabel: 'ENTER',
    )));
    await tester.pump();

    expect(find.text('ENTER'), findsOneWidget);
    expect(find.text('PLAY'), findsNothing);
  });

  testWidgets('the default (both) mode never shows the direct button',
      (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
    )));
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-direct')), findsNothing);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
  });
}
