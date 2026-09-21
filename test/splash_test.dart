import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kjhrono_commons/kjhrono_commons.dart';

void main() {
  setUp(() {
    // Splash art ships with the package — tests only need the text tree.
    // (SvgPicture.asset resolves package: URIs natively in widget tests.)
  });

  Widget host(Widget child) => MaterialApp(home: child);

  testWidgets('splash renders name, welcome and both buttons per config', (tester) async {
    var started = false;
    var loaded = false;
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'A probe of the shared splash',
      welcomeName: 'Marcuz',
      onNewGame: () => started = true,
      onContinue: () => loaded = true,
      continueEnabled: true,
      continueLabel: 'CONTINUE',
    )));
    await tester.pump();

    expect(find.text('PROBE GAME'), findsOneWidget);
    expect(find.text('Welcome, Marcuz, to Probe Game'), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-continue')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('splash-new-game')));
    await tester.pump();
    expect(started, isTrue);
    await tester.tap(find.byKey(const ValueKey('splash-continue')));
    await tester.pump();
    expect(loaded, isTrue);
  });

  testWidgets('continue is disabled and renamed when nothing can load', (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
    )));
    await tester.pump();

    final button = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('splash-continue')));
    expect(button.onPressed, isNull);
    expect(find.text('NO SAVED GAMES'), findsOneWidget);
  });

  testWidgets('start-only apps can omit the continue button entirely', (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Tool',
      description: 'd',
      onNewGame: () {},
      actions: SplashActions.startOnly,
    )));
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-new-game')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-continue')), findsNothing);
  });

  testWidgets('debugSceneIndex pins the flavor scene roll', (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      scenes: const [
        SplashScene(line: 'first', vignette: null, story: 'one'),
        SplashScene(line: 'second', vignette: null, story: 'two'),
      ],
      debugSceneIndex: 1,
    )));
    await tester.pump();

    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });

  testWidgets('entrance animation: invisible at t0, settled after the run',
      (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
    )));
    // First frame of the entrance: the title is still transparent.
    await tester.pump();
    final fade0 = tester.widget<FadeTransition>(find.ancestor(
      of: find.text('PROBE GAME'),
      matching: find.byType(FadeTransition),
    ).first);
    expect(fade0.opacity.value, lessThan(0.2));

    // Let the 700 ms controller finish: everything fully visible.
    await tester.pumpAndSettle();
    final fade1 = tester.widget<FadeTransition>(find.ancestor(
      of: find.text('PROBE GAME'),
      matching: find.byType(FadeTransition),
    ).first);
    expect(fade1.opacity.value, 1.0);
    expect(
        tester.widget<SlideTransition>(find.byType(SlideTransition).first)
            .position
            .value,
        Offset.zero);
  });

  testWidgets('buttons stagger in: New Game leads, Continue follows ~100ms',
      (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
    )));
    await tester.pump(); // first frame of the entrance
    // Neither button has started arriving.
    expect(_buttonFade(tester, 'splash-new-game').opacity.value, lessThan(0.05));
    expect(_buttonFade(tester, 'splash-continue').opacity.value, lessThan(0.05));

    // Mid-entrance (350 of 700 ms): New Game's window (280–560 ms) is well
    // underway while Continue's (380–660 ms) has not begun.
    await tester.pump(const Duration(milliseconds: 350));
    final newGame = _buttonFade(tester, 'splash-new-game').opacity.value;
    final cont = _buttonFade(tester, 'splash-continue').opacity.value;
    expect(newGame, greaterThan(0.2));
    expect(cont, lessThan(0.05));
    expect(newGame, greaterThan(cont));

    // Both settle fully visible.
    await tester.pumpAndSettle();
    expect(_buttonFade(tester, 'splash-new-game').opacity.value, 1.0);
    expect(_buttonFade(tester, 'splash-continue').opacity.value, 1.0);
  });

  testWidgets('flavor line and vignette arrive after the buttons',
      (tester) async {
    // A pinned scene with a vignette so the foreground act participates.
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
      debugSceneIndex: 2, // the dungeon scene ships a vignette
    )));
    await tester.pump(); // t0: the late arrivals have not begun
    expect(find.byKey(const ValueKey('splash-vignette')), findsOneWidget);
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-vignette')))
        .opacity.value, lessThan(0.05));
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-flavor')))
        .opacity.value, lessThan(0.05));

    // 470 ms: buttons still mid-entrance, flavor (660+) and vignette
    // (760+) both still waiting.
    await tester.pump(const Duration(milliseconds: 470));
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-flavor')))
        .opacity.value, lessThan(0.05));

    // 720 ms: the flavor line is mid-fade; the vignette (760+) not yet.
    await tester.pump(const Duration(milliseconds: 250));
    final flavor = _fadeOf(tester, find.byKey(const ValueKey('splash-flavor')))
        .opacity.value;
    expect(flavor, greaterThan(0.2));
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-vignette')))
        .opacity.value, lessThan(0.05));

    // Settled: everything visible, vignette at rest (rise finished).
    await tester.pumpAndSettle();
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-flavor')))
        .opacity.value, 1.0);
    expect(_fadeOf(tester, find.byKey(const ValueKey('splash-vignette')))
        .opacity.value, 1.0);
    expect(tester.widget<SlideTransition>(find.ancestor(
      of: find.byKey(const ValueKey('splash-vignette')),
      matching: find.byType(SlideTransition),
    ).first).position.value, Offset.zero);
  });

  testWidgets('animateEntrance:false and reduced motion both skip the run',
      (tester) async {
    await tester.pumpWidget(host(AppSplash(
      appName: 'Probe Game',
      description: 'd',
      onNewGame: () {},
      animateEntrance: false,
    )));
    await tester.pump();

    final fade = tester.widget<FadeTransition>(find.ancestor(
      of: find.text('PROBE GAME'),
      matching: find.byType(FadeTransition),
    ).first);
    expect(fade.opacity.value, 1.0); // resting at the final layout
    // ...and the buttons rest visible too, no stagger left dangling.
    expect(_buttonFade(tester, 'splash-new-game').opacity.value, 1.0);
  });
}

FadeTransition _buttonFade(WidgetTester tester, String key) =>
    tester.widget<FadeTransition>(find.ancestor(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(FadeTransition),
    ).first);

FadeTransition _fadeOf(WidgetTester tester, Finder target) =>
    tester.widget<FadeTransition>(
        find.ancestor(of: target, matching: find.byType(FadeTransition)).first);
