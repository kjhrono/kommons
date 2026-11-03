import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The high-contrast mode: the persisted preference, the theme it produces,
/// and the shape cues the setup rail adds so the wizard never depends on hue
/// alone.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appContrast.resetForTest();
  });

  tearDown(appContrast.resetForTest);

  group('preference', () {
    test('toggles, persists and restores', () async {
      expect(appContrast.enabled, isFalse);

      appContrast.toggle();
      await pumpEventQueue();
      expect(appContrast.enabled, isTrue);
      expect(
          (await SharedPreferences.getInstance())
              .getBool('prefs.app.highContrast'),
          isTrue);

      // A fresh launch reads it back before the first frame.
      appContrast.resetForTest();
      await appContrast.load();
      expect(appContrast.enabled, isTrue);

      appContrast.enabled = false;
      await pumpEventQueue();
      appContrast.resetForTest();
      await appContrast.load();
      expect(appContrast.enabled, isFalse);
    });
  });

  group('theme', () {
    test('raises surfaces, ink and edges without losing the palette', () {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff4f6f52), brightness: Brightness.dark),
        useMaterial3: true,
      );
      final contrast = highContrastTheme(base);

      expect(contrast.scaffoldBackgroundColor, Colors.black);
      expect(contrast.colorScheme.onSurface, Colors.white);
      expect(contrast.colorScheme.outline, Colors.white);
      expect(contrast.dividerTheme.thickness, 2);
      expect(contrast.appBarTheme.foregroundColor, Colors.white);
      // Still the host's green, not a generic palette.
      expect(contrast.colorScheme.primary, isNot(base.colorScheme.primary),
          reason: 'the scheme is rebuilt at maximum contrast');
      expect(HSVColor.fromColor(contrast.colorScheme.primary).hue,
          closeTo(HSVColor.fromColor(base.colorScheme.primary).hue, 20));
    });

    test('light mode pairs black ink with white surfaces', () {
      final contrast = highContrastTheme(ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff4f6f52),
              brightness: Brightness.light)));

      expect(contrast.scaffoldBackgroundColor, Colors.white);
      expect(contrast.colorScheme.onSurface, Colors.black);
      expect(contrast.textTheme.bodyMedium?.color, Colors.black);
    });

    test('a card is drawn by its outline, not only its fill', () {
      final contrast = highContrastTheme(ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff4f6f52),
              brightness: Brightness.dark)));
      final shape = contrast.cardTheme.shape as RoundedRectangleBorder;
      expect(shape.side.width, 2);
      expect(shape.side.color, Colors.white);
    });
  });

  group('setup rail cues', () {
    const steps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person, summary: 'Elf'),
      LobbyStepDescriptor(
          title: 'Start', icon: Icons.alt_route, summary: 'Solo'),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(
          title: 'Game options',
          icon: Icons.sports_esports,
          summary: 'Sandbox'),
    ];

    Widget wizard() => MaterialApp(
          home: LobbyWizard(
            steps: steps,
            current: 1,
            onGoto: (_) {},
            body: const [Text('body')],
            // Step 0 is cleared by its host gate; without one the rail would
            // only check it if this wizard had visited it.
            canContinue: (_) => true,
          ),
        );

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wizard());
      await tester.pump();
    }

    testWidgets('normal mode draws icons and no rule under the label',
        (tester) async {
      await pump(tester);

      // The current step wears its own glyph; the pending one after it too.
      expect(find.byIcon(Icons.alt_route), findsOneWidget);
      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
      expect(find.text('2'), findsNothing);
      final label = tester
          .widget<Text>(find.byKey(const ValueKey('wizard-step-label-1')));
      expect(label.style?.decoration, isNull);
    });

    testWidgets(
        'contrast mode numbers the steps and underlines the current one',
        (tester) async {
      appContrast.enabled = true;
      await pump(tester);

      // Numbers, not icons: order reads without hue. (The completed first
      // step keeps its check instead of a number.)
      expect(find.text('1'), findsNothing);
      for (var i = 2; i <= steps.length; i++) {
        expect(find.text('$i'), findsOneWidget,
            reason: 'step $i is numbered in contrast mode');
      }
      expect(find.byIcon(Icons.alt_route), findsNothing);
      expect(find.byIcon(Icons.groups_outlined), findsNothing);

      final current = tester
          .widget<Text>(find.byKey(const ValueKey('wizard-step-label-1')));
      expect(current.style?.decoration, TextDecoration.underline);
      expect(current.style?.fontWeight, FontWeight.w600);

      // The step before it is done, so it keeps its check instead of a number.
      expect(find.byIcon(Icons.check), findsOneWidget);

      // Values strengthen too: full ink, heavier weight.
      final value = tester
          .widget<Text>(find.byKey(const ValueKey('wizard-step-summary-1')));
      expect(value.style?.fontWeight, FontWeight.w700);
      expect(value.style?.color,
          Theme.of(tester.element(find.text('body'))).colorScheme.onSurface);
    });

    testWidgets('turning it off restores the icon rail', (tester) async {
      appContrast.enabled = true;
      await pump(tester);
      expect(find.text('2'), findsOneWidget);

      appContrast.enabled = false;
      await tester.pump();

      expect(find.text('2'), findsNothing);
      expect(find.byIcon(Icons.alt_route), findsOneWidget);
    });
  });

  group('setup flow', () {
    const steps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person, summary: 'Elf'),
      LobbyStepDescriptor(title: 'Start', icon: Icons.alt_route),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
    ];

    Widget wizard({List<Widget>? actions}) => MaterialApp(
          home: LobbyWizard(
            steps: steps,
            current: 1,
            onGoto: (_) {},
            body: const [Text('body')],
            appBarActions: actions,
          ),
        );

    testWidgets('the wizard carries its own toggle, so setup is readable',
        (tester) async {
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wizard());
      await tester.pump();

      expect(find.byKey(const ValueKey('contrast-toggle')), findsOneWidget,
          reason: 'setup must not require finding Settings first');
      expect(find.byIcon(Icons.alt_route), findsOneWidget);

      // Flipping it from inside the flow repaints the rail by itself — the
      // host does not have to rebuild for the shape cues to appear.
      await tester.tap(find.byKey(const ValueKey('contrast-toggle')));
      await tester.pumpAndSettle();

      expect(appContrast.enabled, isTrue);
      expect(find.text('2'), findsOneWidget,
          reason: 'the rail switches to numbers without relying on hue');
      expect(find.byIcon(Icons.alt_route), findsNothing);
      expect(find.byIcon(Icons.contrast), findsOneWidget);
    });

    testWidgets('a host-placed toggle is not duplicated', (tester) async {
      await tester.pumpWidget(wizard(actions: const [
        HighContrastToggleButton(),
        IconButton(
          key: ValueKey('probe-gear'),
          onPressed: null,
          icon: Icon(Icons.settings),
        ),
      ]));
      await tester.pump();

      expect(find.byKey(const ValueKey('contrast-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('probe-gear')), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('settings offers the mode as a labelled switch',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(gameId: 'probe'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('contrast-tile')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();

      SwitchListTile tile() => tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('contrast-tile')));
      expect(tile().value, isFalse);
      expect(find.text('High-contrast mode'), findsOneWidget);
      expect(find.textContaining('Thicker outlines'), findsOneWidget,
          reason: 'the card says what the mode changes, not just its name');

      await tester.tap(find.byKey(const ValueKey('contrast-tile')));
      await tester.pumpAndSettle();

      expect(appContrast.enabled, isTrue);
      expect(tile().value, isTrue);
    });
  });

  group('toggle button', () {
    testWidgets('flips the preference and changes glyph, not just tint',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            appBar: AppBar(actions: const [HighContrastToggleButton()])),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.contrast_outlined), findsOneWidget);
      expect(find.byTooltip('High-contrast mode'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contrast-toggle')));
      await tester.pumpAndSettle();

      expect(appContrast.enabled, isTrue);
      expect(find.byIcon(Icons.contrast), findsOneWidget,
          reason: 'the solid glyph distinguishes on from off by shape');
      expect(find.byIcon(Icons.contrast_outlined), findsNothing);
      expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('contrast-toggle')))
              .isSelected,
          isTrue);
    });
  });
}
