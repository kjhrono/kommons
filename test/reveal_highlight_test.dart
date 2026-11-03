import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ring a shortcut jump leaves on its destination: colour rule, paint,
/// geometry, timing and the reduce-motion variant.
void main() {
  const fill = Color(0xFF102030);
  const boundaryKey = ValueKey('reveal-boundary');
  const targetKey = ValueKey('reveal-target');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appContrast.resetForTest();
  });
  tearDown(appContrast.resetForTest);

  ThemeData theme() => ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff4f6f52), brightness: Brightness.dark),
        useMaterial3: true,
      );

  /// The widget under test: a flat 200×80 block so a painted pixel is easy to
  /// tell from an untouched one.
  Widget harness(GlobalKey<RevealHighlightState> key,
          {bool reduceMotion = false}) =>
      MaterialApp(
        theme: theme(),
        builder: (context, child) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: RevealHighlight(
                key: key,
                duration: const Duration(milliseconds: 600),
                child: const SizedBox(
                  key: targetKey,
                  width: 200,
                  height: 80,
                  child: ColoredBox(color: fill),
                ),
              ),
            ),
          ),
        ),
      );

  /// The ring's painter, scoped to our widget: other Material internals in the
  /// tree carry foreground painters of their own.
  Finder ring() => find.descendant(
      of: find.byType(RevealHighlight),
      matching: find.byWidgetPredicate((widget) =>
          widget is CustomPaint && widget.foregroundPainter != null));

  /// Raw RGBA of the rendered boundary, read on the engine's own thread (a
  /// widget test's fake clock never completes `toImage` on its own).
  Future<_Pixels> capture(WidgetTester tester) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
    final pixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final result = _Pixels(data!.buffer.asUint8List(), image.width);
      image.dispose();
      return result;
    });
    return pixels!;
  }

  Color? ringPixel(_Pixels pixels) {
    // Scan the top edge for the strongest departure from the flat fill: the
    // stroke is blurred, so no single pixel is exactly the ring colour.
    Color? best;
    var bestDistance = 0.0;
    for (var y = 0; y < 6; y++) {
      final pixel = pixels.at(100, y);
      final distance = _distance(pixel, fill);
      if (distance > bestDistance) {
        bestDistance = distance;
        best = pixel;
      }
    }
    return bestDistance < 3 ? null : best;
  }

  testWidgets('the ring is tertiary, or the strongest ink in high contrast',
      (tester) async {
    Color? seen;
    Widget probe() => MaterialApp(
          theme: theme(),
          home: Builder(builder: (context) {
            seen = RevealHighlight.ringColorOf(context);
            return const SizedBox.shrink();
          }),
        );

    await tester.pumpWidget(probe());
    expect(seen, theme().colorScheme.tertiary,
        reason: 'the control you asked for, never the current-step primary');

    appContrast.enabled = true;
    await tester.pumpWidget(probe());
    expect(seen, theme().colorScheme.onSurface,
        reason: 'contrast mode draws structure in the scheme\'s strongest ink');
  });

  testWidgets('play paints a ring without moving or resizing the control',
      (tester) async {
    final key = GlobalKey<RevealHighlightState>();
    await tester.pumpWidget(harness(key));
    final before = tester.getRect(find.byKey(targetKey));
    expect(ring(), findsNothing, reason: 'nothing is drawn until the jump');

    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(ring(), findsOneWidget);

    expect(tester.getRect(find.byKey(targetKey)), before,
        reason: 'a foreground painter never changes the child');
    expect(tester.getSize(find.byKey(key)), before.size,
        reason: 'the wrapper is exactly the control\'s size');

    // It is actually painted, not merely configured: the edge carries the
    // ring's colour and the middle is still the flat fill.
    final pixels = await capture(tester);
    final edge = ringPixel(pixels);
    expect(edge, isNotNull, reason: 'a visible ring sits on the control edge');
    expect(_distance(edge!, fill), greaterThan(40),
        reason: 'the edge sits well away from the flat fill');
    expect(pixels.at(100, 40), fill, reason: 'the control itself is untouched');

    // Gone once the run is over: the ring is a moment, not a decoration.
    await tester.pump(const Duration(milliseconds: 700));
    expect(ring(), findsNothing);
  });

  testWidgets('a second play restarts the ring', (tester) async {
    final key = GlobalKey<RevealHighlightState>();
    await tester.pumpWidget(harness(key));
    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(ring(), findsOneWidget);

    // A second jump starts over: 200 ms later the first run would already be
    // over (500 + 200 > 600), yet the ring is still there.
    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(ring(), findsOneWidget,
        reason: 'the restart refilled the ring instead of finishing it');

    await tester.pump(const Duration(milliseconds: 800));
    expect(ring(), findsNothing);
  });

  testWidgets('reduce motion swaps the flash for a short static highlight',
      (tester) async {
    final key = GlobalKey<RevealHighlightState>();
    await tester.pumpWidget(harness(key, reduceMotion: true));
    key.currentState!.play();
    await tester.pump();
    // At the very start of the run the animated ring is still nearly
    // transparent (12% of the duration goes to the fade in); with motion
    // disabled the highlight is already at full strength, because the ring is
    // information, not flourish.
    await tester.pump(const Duration(milliseconds: 10));
    expect(ring(), findsOneWidget);
    final edge = ringPixel(await capture(tester));
    expect(edge, isNotNull);
    final ink = theme().colorScheme.tertiary;
    // A faded ring at this instant would sit a stone's throw from the fill;
    // a full-strength one is unmistakably the ink.
    expect(_distance(edge!, fill), greaterThan(120),
        reason: 'the highlight is full strength from the first frame');
    expect(_distance(edge, ink), lessThan(60));
    expect(key.currentState!.isPlaying, isTrue);

    // Half-way through the hold it is still the same ring: the highlight is
    // static, not a fade stretched over the run.
    await tester.pump(const Duration(milliseconds: 240));
    expect(ring(), findsOneWidget, reason: 'the highlight holds still');
    final midway = ringPixel(await capture(tester));
    expect(midway, isNotNull);
    expect(_distance(midway!, edge), lessThan(6),
        reason: 'nothing fades or moves while it is up');

    // Gone well before the 600 ms the animated ring would have taken: the
    // flash is replaced by a short highlight, not stretched to its duration.
    await tester.pump(const Duration(milliseconds: 200));
    expect(ring(), findsNothing,
        reason: 'the short hold ends, it does not run the flash\'s 1.2 s');
    expect(key.currentState!.isPlaying, isFalse);
  });

  testWidgets('reduce motion restarts the highlight on a second play',
      (tester) async {
    final key = GlobalKey<RevealHighlightState>();
    await tester.pumpWidget(harness(key, reduceMotion: true));
    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(ring(), findsOneWidget);

    // A second jump restarts the hold: 300 ms later the first one would have
    // ended, yet the ring is still there.
    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(ring(), findsOneWidget, reason: 'the second play refilled the hold');

    await tester.pump(const Duration(milliseconds: 150));
    expect(ring(), findsNothing);
  });

  testWidgets('turning reduce motion on cuts a flash already running',
      (tester) async {
    final key = GlobalKey<RevealHighlightState>();
    var reduceMotion = false;
    late StateSetter rebuild;
    // The switch sits above the app, so flipping it rebuilds the MediaQuery the
    // way a platform setting change does — the ring's state survives.
    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return MaterialApp(
        theme: theme(),
        builder: (context, child) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: RevealHighlight(
              key: key,
              duration: const Duration(milliseconds: 600),
              child: const SizedBox(
                key: targetKey,
                width: 200,
                height: 80,
                child: ColoredBox(color: fill),
              ),
            ),
          ),
        ),
      );
    }));

    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(ring(), findsOneWidget);

    // The platform setting flips while the flash is mid-run: the next reveal
    // is still, and the half-finished fade must not resurface once the short
    // hold ends (a stopped controller would leave it frozen at its value).
    rebuild(() => reduceMotion = true);
    await tester.pump();
    key.currentState!.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(ring(), findsNothing,
        reason: 'the cut flash leaves nothing behind the still highlight');
    expect(key.currentState!.isPlaying, isFalse);
  });
}

/// A capture's raw RGBA, with the row stride it needs.
class _Pixels {
  _Pixels(this.bytes, this.width);

  final Uint8List bytes;
  final int width;

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
  }
}

double _distance(Color a, Color b) {
  // Straight RGB distance is enough to tell "the ring" from "the fill": the
  // two are far apart in every channel.
  final dr = (a.r - b.r) * 255;
  final dg = (a.g - b.g) * 255;
  final db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}
