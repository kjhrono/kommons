import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

void _noop(int _) {}

void main() {
  group('LobbyWizard', () {
    const steps = [
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(title: 'Options', icon: Icons.tune),
      LobbyStepDescriptor(title: 'Ready?', icon: Icons.rocket_launch),
    ];

    Future<int> pumpAt(WidgetTester tester, int current,
        {ValueChanged<int>? onGoto}) async {
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: steps,
          current: current,
          onGoto: onGoto ?? (_) {},
          body: [Text('body of ${steps[current].title}')],
        ),
      ));
      return current;
    }

    testWidgets('renders the step header, body and nav', (tester) async {
      await pumpAt(tester, 1);
      expect(find.text('Step 2 of 3 — Options'), findsOneWidget);
      expect(find.text('body of Options'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      // Last-but-one step still shows Continue.
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('a done action takes Continue\'s place and keeps the gate',
        (tester) async {
      // An edit visit opened from a review screen goes back there, not to the
      // next setup step — on every step, including the last.
      var done = 0;
      var wentTo = -1;
      Widget wizard({bool ok = true, int current = 1}) => MaterialApp(
            home: LobbyWizard(
              steps: steps,
              current: current,
              onGoto: (i) => wentTo = i,
              body: const [Text('body')],
              canContinue: (_) => ok,
              onDone: () => done++,
              doneLabel: 'BACK TO REVIEW',
            ),
          );

      await tester.pumpWidget(wizard());
      await tester.pump();
      expect(find.text('Continue'), findsNothing);
      expect(find.text('BACK TO REVIEW'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget,
          reason: 'the walk home is still one step at a time');

      await tester.tap(find.text('BACK TO REVIEW'));
      expect(done, 1);

      // The host's gate still holds the primary action closed.
      await tester.pumpWidget(wizard(ok: false));
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('wizard-done')))
              .onPressed,
          isNull);

      // The last step has no Continue to begin with; the done action is the
      // only way on, so hosts do not have to hand-roll it in the body.
      await tester.pumpWidget(wizard(current: 2));
      await tester.pump();
      expect(find.text('BACK TO REVIEW'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);
      expect(wentTo, -1, reason: 'no step was skipped on the way out');
    });

    testWidgets('a bare wizard falls back to the shell title', (tester) async {
      await pumpAt(tester, 0);
      expect(find.text('NEW GAME'), findsOneWidget);
    });

    testWidgets('the subtitle takes its colour from the theme', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.light(),
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(
                title: 'World', icon: Icons.public, subtitle: 'Seed it.'),
          ],
          current: 0,
          onGoto: _noop,
          body: const [Text('body')],
        ),
      ));
      await tester.pump();

      // A fixed grey washed out on a light surface; the subtitle follows the
      // theme's secondary ink instead.
      final subtitle = tester.widget<Text>(find.text('Seed it.'));
      expect(subtitle.style?.color,
          ThemeData.light().colorScheme.onSurfaceVariant);
    });

    testWidgets('rail nodes are tappable and go anywhere', (tester) async {
      var navigated = -1;
      await pumpAt(tester, 2, onGoto: (i) => navigated = i);
      expect(navigated, -1);
      await tester.tap(find.byTooltip('Lobby'));
      expect(navigated, 0);
    });

    testWidgets('first step hides Back; last hides Continue', (tester) async {
      await pumpAt(tester, 0);
      expect(find.text('Back'), findsNothing);
      expect(find.text('Continue'), findsOneWidget);
      await pumpAt(tester, 2);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);
    });

    testWidgets('subtitle seam shows the per-step hint under the header',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(
                title: 'World',
                icon: Icons.public,
                subtitle: 'Seed, size and events.'),
            LobbyStepDescriptor(title: 'Recap', icon: Icons.rocket_launch),
          ],
          current: 0,
          onGoto: (_) {},
          body: const [Text('body')],
        ),
      ));
      await tester.pump();

      expect(find.text('Seed, size and events.'), findsOneWidget);
      // A descriptor without a subtitle renders no hint line — the caller
      // owns navigation (the wizard is stateless), so step to 'Recap'.
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(
                title: 'World',
                icon: Icons.public,
                subtitle: 'Seed, size and events.'),
            LobbyStepDescriptor(title: 'Recap', icon: Icons.rocket_launch),
          ],
          current: 1,
          onGoto: (_) {},
          body: const [Text('body')],
        ),
      ));
      await tester.pump();
      expect(find.text('Seed, size and events.'), findsNothing);
    });

    testWidgets('canContinue gates Continue per step and updates on rebuild',
        (tester) async {
      Widget gate(bool ok) => MaterialApp(
            home: LobbyWizard(
              steps: const [
                LobbyStepDescriptor(title: 'Name', icon: Icons.person),
                LobbyStepDescriptor(title: 'Ready?', icon: Icons.rocket_launch),
              ],
              current: 0,
              onGoto: (_) {},
              body: const [Text('body')],
              canContinue: (_) => ok,
            ),
          );

      // Blocked: the gate says the step is incomplete.
      await tester.pumpWidget(gate(false));
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Continue'))
              .onPressed,
          isNull);

      // The host completes the step: a rebuild re-evaluates the gate.
      await tester.pumpWidget(gate(true));
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Continue'))
              .onPressed,
          isNotNull);

      // The gate is per-step: the last step hides Continue entirely, so the
      // gate never matters there (hosts put their own START button in body).
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(title: 'Name', icon: Icons.person),
            LobbyStepDescriptor(title: 'Ready?', icon: Icons.rocket_launch),
          ],
          current: 1,
          onGoto: (_) {},
          body: const [Text('body')],
          canContinue: (_) => false,
        ),
      ));
      await tester.pump();
      expect(find.text('Continue'), findsNothing);
    });

    testWidgets(
        'rail navigation stays free while the gate holds the primary path',
        (tester) async {
      // Even with the gate closed, jumping back to an earlier step via the
      // rail remains possible — the gate steers Continue, not the map.
      var wentTo = -1;
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(title: 'A', icon: Icons.looks_one),
            LobbyStepDescriptor(title: 'B', icon: Icons.looks_two),
            LobbyStepDescriptor(title: 'C', icon: Icons.looks_3),
          ],
          current: 1,
          onGoto: (i) => wentTo = i,
          body: const [Text('body')],
          canContinue: (_) => false,
        ),
      ));
      await tester.pump();

      expect(find.text('Continue'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Continue'))
              .onPressed,
          isNull);
      await tester.tap(find.byTooltip('A'));
      expect(wentTo, 0);
    });

    testWidgets('banner seam renders above the rail on every step',
        (tester) async {
      Widget withBanner(int current) => MaterialApp(
            home: LobbyWizard(
              steps: const [
                LobbyStepDescriptor(title: 'A', icon: Icons.looks_one),
                LobbyStepDescriptor(title: 'B', icon: Icons.looks_two),
              ],
              current: current,
              onGoto: (_) {},
              body: const [Text('body')],
              banner: const Text('PENDING NOTICE'),
            ),
          );

      await tester.pumpWidget(withBanner(0));
      await tester.pump();
      expect(find.text('PENDING NOTICE'), findsOneWidget);
      // Above the rail: the notice precedes the step header in reading order.
      expect(tester.getTopLeft(find.text('PENDING NOTICE')).dy,
          lessThan(tester.getTopLeft(find.text('Step 1 of 2 — A')).dy));

      // Still there on another step.
      await tester.pumpWidget(withBanner(1));
      await tester.pump();
      expect(find.text('PENDING NOTICE'), findsOneWidget);

      // Null banner renders nothing.
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(title: 'A', icon: Icons.looks_one),
          ],
          current: 0,
          onGoto: (_) {},
          body: const [Text('body')],
        ),
      ));
      await tester.pump();
      expect(find.text('PENDING NOTICE'), findsNothing);
    });

    testWidgets("appBarActions seam hosts the app's top-bar controls",
        (tester) async {
      var gearTapped = false;
      await tester.pumpWidget(MaterialApp(
        home: LobbyWizard(
          steps: const [
            LobbyStepDescriptor(title: 'Only', icon: Icons.public),
          ],
          current: 0,
          onGoto: (_) {},
          body: const [Text('body')],
          appBarActions: [
            IconButton(
              key: const ValueKey('probe-gear'),
              onPressed: () => gearTapped = true,
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('probe-gear')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('probe-gear')));
      expect(gearTapped, isTrue);
    });
  });

  group('LobbyWizard step summaries', () {
    // Four of the six steps carry a chosen value; two have none, which must
    // not turn into an empty-looking gap or a ragged rail.
    const steps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person, summary: 'Elf'),
      LobbyStepDescriptor(
          title: 'Options', icon: Icons.tune, summary: 'Sandbox'),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(
          title: 'Ready?', icon: Icons.rocket_launch, summary: 'Medium'),
      LobbyStepDescriptor(title: 'World', icon: Icons.public),
      LobbyStepDescriptor(
          title: 'Database', icon: Icons.edit_note, summary: '24 names'),
    ];

    Widget wizard({
      int current = 1,
      List<LobbyStepDescriptor> stepList = steps,
      ValueChanged<int>? onGoto,
      double textScale = 1,
      Size size = const Size(900, 720),
    }) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: LobbyWizard(
            steps: stepList,
            current: current,
            onGoto: onGoto ?? (_) {},
            body: const [Text('body')],
          ),
        );

    Future<void> pump(WidgetTester tester, Widget app, {Size? size}) async {
      tester.view.physicalSize = size ?? const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app);
      await tester.pump();
    }

    testWidgets('the chosen value rides under its own step name',
        (tester) async {
      await pump(tester, wizard());

      expect(find.text('Elf'), findsOneWidget);
      expect(find.text('Sandbox'), findsOneWidget);
      // Inside the node: below the name, above the node's bottom edge.
      final name =
          tester.getRect(find.byKey(const ValueKey('wizard-step-label-0')));
      final value =
          tester.getRect(find.byKey(const ValueKey('wizard-step-summary-0')));
      final node =
          tester.getRect(find.byKey(const ValueKey('wizard-rail-node-0')));
      expect(value.top, greaterThan(name.bottom - 2));
      expect(value.bottom, lessThanOrEqualTo(node.bottom));
      // The chip line is the fallback, so it stays out of the way here.
      expect(find.byKey(const ValueKey('wizard-summary-0')), findsNothing);
      expect(find.text('Step 2 of 6 — Options'), findsOneWidget);
    });

    testWidgets('a step without a value leaves an even, empty slot',
        (tester) async {
      await pump(tester, wizard());

      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('wizard-step-summary-2')))
              .data,
          '',
          reason: 'no value, no borrowed text');
      final heights = {
        for (var i = 0; i < steps.length; i++)
          tester.getRect(find.byKey(ValueKey('wizard-rail-node-$i'))).height
      };
      expect(heights, hasLength(1),
          reason: 'every node keeps the same band, with or without a value');
    });

    testWidgets('an icon-only rail carries the values as chips',
        (tester) async {
      var wentTo = -1;
      await pump(tester, wizard(onGoto: (i) => wentTo = i, current: 0),
          size: const Size(320, 640));

      // 320dp: the names are gone, so the values come back as one chip line.
      expect(find.byKey(const ValueKey('wizard-step-label-0')), findsNothing);
      expect(find.byKey(const ValueKey('wizard-step-summary-0')), findsNothing);
      expect(find.byKey(const ValueKey('wizard-summary-0')), findsOneWidget);
      expect(find.text('Elf'), findsOneWidget);
      expect(find.text('Sandbox'), findsOneWidget);
      // Only the steps that have a value get a chip.
      expect(find.byKey(const ValueKey('wizard-summary-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('wizard-summary-2')), findsNothing);

      final chip = tester
          .widget<Semantics>(find.byKey(const ValueKey('wizard-summary-0')));
      expect(chip.properties.label, 'Elf — Avatar');
      expect(chip.properties.button, isTrue);
      expect(chip.properties.onTap, isNotNull);
      expect(find.byTooltip('Edit Avatar'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('wizard-summary-1')));
      expect(wentTo, 1, reason: 'the Sandbox chip opens its own step');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chips stay one line when text is huge', (tester) async {
      await pump(tester, wizard(textScale: 1.8, current: 0),
          size: const Size(360, 720));

      final tops = [
        for (var i = 0; i < steps.length; i++)
          if (find.byKey(ValueKey('wizard-summary-$i')).evaluate().isNotEmpty)
            tester.getRect(find.byKey(ValueKey('wizard-summary-$i'))).top
      ];
      expect(tops, isNotEmpty);
      expect(tops.toSet(), hasLength(1),
          reason: 'the values scroll sideways, they do not wrap');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a node announces its step and its value together',
        (tester) async {
      await pump(tester, wizard());

      final node = tester
          .widget<Semantics>(find.byKey(const ValueKey('wizard-rail-node-3')))
          .properties;
      expect(node.label, 'Step 4 of 6 — Ready?, Medium');
      expect(node.selected, isFalse);
    });

    /// A live wizard whose rail navigation really moves the step, so a value
    /// tap can be followed through the rebuild a host would do.
    Widget live(
      ValueNotifier<int> step, {
      required List<int> wentTo,
      required List<int> revealed,
      int initial = 1,
      double textScale = 1,
      Size size = const Size(900, 720),
    }) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: ValueListenableBuilder<int>(
            valueListenable: step,
            builder: (context, current, _) => LobbyWizard(
              steps: steps,
              current: current,
              onGoto: (i) {
                wentTo.add(i);
                step.value = i;
              },
              onRevealControl: revealed.add,
              body: [Text('body of $current')],
            ),
          ),
        );

    testWidgets('a value tap opens its step and then its control',
        (tester) async {
      final step = ValueNotifier<int>(1);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(tester, live(step, wentTo: wentTo, revealed: revealed));

      // The value under 'Ready?': 'Medium'.
      await tester.tap(find.byKey(const ValueKey('wizard-step-summary-3')));
      await tester.pumpAndSettle();

      expect(wentTo, [3], reason: 'the value still opens its step');
      expect(revealed, [3],
          reason: 'the host is asked for the control that value came from');
      expect(step.value, 3);
      expect(find.text('body of 3'), findsOneWidget);
    });

    testWidgets('the step name still opens only the step', (tester) async {
      final step = ValueNotifier<int>(1);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(tester, live(step, wentTo: wentTo, revealed: revealed));

      await tester.tap(find.byTooltip('Avatar'));
      await tester.pumpAndSettle();

      expect(wentTo, [0]);
      expect(revealed, isEmpty,
          reason: 'the name is plain navigation, not a control shortcut');
    });

    testWidgets('tapping the current step\'s value reveals without navigating',
        (tester) async {
      final step = ValueNotifier<int>(1);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(tester, live(step, wentTo: wentTo, revealed: revealed));

      await tester.tap(find.byKey(const ValueKey('wizard-step-summary-1')));
      await tester.pumpAndSettle();

      expect(wentTo, isEmpty, reason: 'already there: no step change');
      expect(revealed, [1], reason: 'the control is still revealed');
    });

    testWidgets('an icon-only rail\'s chips reveal the control too',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(
          tester, live(step, wentTo: wentTo, revealed: revealed, initial: 0),
          size: const Size(320, 640));

      // 320dp keeps the two leading values (this step and the next); the
      // rest sit behind the count pill, so the visible chip is chip 1.
      await tester.tap(find.byKey(const ValueKey('wizard-summary-1')));
      await tester.pumpAndSettle();

      expect(wentTo, [1]);
      expect(revealed, [1]);
    });

    testWidgets('a very narrow rail shows two values and counts the rest',
        (tester) async {
      // 320dp: the chip line would need two screens of scrolling, so it keeps
      // the step you are on and the next one that has a value.
      await pump(tester, wizard(current: 0, size: const Size(320, 640)),
          size: const Size(320, 640));

      expect(find.byKey(const ValueKey('wizard-summary-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('wizard-summary-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('wizard-summary-3')), findsNothing);
      expect(find.byKey(const ValueKey('wizard-summary-5')), findsNothing);
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: find.byKey(const ValueKey('wizard-summary-more')),
                  matching: find.byType(Text)))
              .data,
          '+2',
          reason: 'the two values the line is not showing are counted');

      // Later on the rail the pair moves with the player: the step in hand
      // (Ready?) and the one after it (Database).
      await tester.pumpWidget(wizard(current: 3));
      await tester.pump();

      expect(find.byKey(const ValueKey('wizard-summary-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('wizard-summary-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('wizard-summary-0')), findsNothing);
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: find.byKey(const ValueKey('wizard-summary-more')),
                  matching: find.byType(Text)))
              .data,
          '+2');
    });

    testWidgets('the count pill lists every value and keeps the shortcut',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(
          tester, live(step, wentTo: wentTo, revealed: revealed, initial: 0),
          size: const Size(320, 640));

      // Two chips fit the line; the other two values are behind the count.
      expect(find.byKey(const ValueKey('wizard-summary-3')), findsNothing);
      final pill = tester
          .widget<Semantics>(find.byKey(const ValueKey('wizard-summary-more')));
      expect(pill.properties.button, isTrue);
      expect(pill.properties.label, 'Show every chosen value',
          reason: 'the pill names its action, not the hidden values again');

      await tester.tap(find.byKey(const ValueKey('wizard-summary-more')));
      await tester.pumpAndSettle();

      expect(find.text('CHOSEN VALUES'), findsOneWidget);
      for (final i in [0, 1, 3, 5]) {
        expect(find.byKey(ValueKey('wizard-values-$i')), findsOneWidget,
            reason: 'step $i is listed even where its chip was hidden');
      }
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('wizard-values-5')),
              matching: find.text('24 names')),
          findsOneWidget,
          reason: 'a hidden value is readable in the sheet');

      // A row is the same shortcut as the chip it stands in for: it opens the
      // step and asks the host to reveal the control behind the value.
      await tester.tap(find.byKey(const ValueKey('wizard-values-5')));
      await tester.pumpAndSettle();

      expect(find.text('CHOSEN VALUES'), findsNothing,
          reason: 'the sheet closes behind the jump');
      expect(step.value, 5);
      expect(wentTo, [5]);
      expect(revealed, [5]);
    });

    testWidgets('dismissing the value sheet changes nothing', (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      final wentTo = <int>[];
      final revealed = <int>[];
      await pump(
          tester, live(step, wentTo: wentTo, revealed: revealed, initial: 0),
          size: const Size(320, 640));

      await tester.tap(find.byKey(const ValueKey('wizard-summary-more')));
      await tester.pumpAndSettle();
      // The barrier above the sheet: the rail stays as it was.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('CHOSEN VALUES'), findsNothing);
      expect(step.value, 0);
      expect(wentTo, isEmpty);
      expect(revealed, isEmpty);
    });

    testWidgets('the value sheet holds on a small phone at 2× text',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await pump(tester,
          live(step, wentTo: [], revealed: [], initial: 0, textScale: 2),
          size: const Size(320, 640));

      // At 2× the chips grow and push the count off the line; the line scrolls
      // sideways, so bring the pill in before tapping it.
      await tester
          .ensureVisible(find.byKey(const ValueKey('wizard-summary-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wizard-summary-more')));
      await tester.pumpAndSettle();

      expect(find.text('CHOSEN VALUES'), findsOneWidget);
      // The tall rows spill past the compact sheet: it scrolls rather than
      // clipping, so the last value stays reachable.
      await tester.drag(find.byType(ListView), const Offset(0, -260));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wizard-values-5')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a collapsed chip line still speaks every value',
        (tester) async {
      await pump(tester, wizard(current: 3, size: const Size(320, 640)),
          size: const Size(320, 640));

      // The two values the line dropped are still part of the rail's
      // screen-reader sentences: nothing is lost to the reader, only to the
      // pixels.
      String label(int i) => tester
          .widget<Semantics>(find.byKey(ValueKey('wizard-rail-node-$i')))
          .properties
          .label!;
      expect(label(0), contains('Elf'));
      expect(label(1), contains('Sandbox'));
      expect(label(3), contains('Medium'));
      expect(label(5), contains('24 names'));

      // And the count is a visual reminder only: it is not read out a second
      // time beside the values it stands for.
      expect(find.bySemanticsLabel(RegExp(r'\+2')), findsNothing);
    });

    testWidgets('a 360dp rail at large text keeps the whole chip line',
        (tester) async {
      // The collapse is for the very narrow rail, not for every icon-only
      // one: big text on a normal phone still shows every chosen value.
      await pump(tester,
          wizard(current: 0, textScale: 1.6, size: const Size(360, 720)),
          size: const Size(360, 720));

      for (final i in [0, 1, 3, 5]) {
        expect(find.byKey(ValueKey('wizard-summary-$i')), findsOneWidget,
            reason: 'value $i keeps its chip');
      }
      expect(find.byKey(const ValueKey('wizard-summary-more')), findsNothing);
    });

    testWidgets('no summaries leaves the rail exactly as it was',
        (tester) async {
      await pump(
          tester,
          wizard(stepList: const [
            LobbyStepDescriptor(title: 'Avatar', icon: Icons.person),
            LobbyStepDescriptor(title: 'Options', icon: Icons.tune),
          ]));

      expect(find.byKey(const ValueKey('wizard-step-summary-0')), findsNothing);
      expect(find.byKey(const ValueKey('wizard-summary-0')), findsNothing);
      expect(find.text('Step 2 of 2 — Options'), findsOneWidget);
    });
  });

  group('LobbyWizard rail sizing and accessibility', () {
    const sixSteps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person),
      LobbyStepDescriptor(title: 'Start', icon: Icons.alt_route),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(title: 'Game options', icon: Icons.sports_esports),
      LobbyStepDescriptor(title: 'World options', icon: Icons.public),
      LobbyStepDescriptor(title: 'Database', icon: Icons.edit_note),
    ];

    Widget wizard({
      int current = 0,
      List<LobbyStepDescriptor> steps = sixSteps,
      ValueChanged<int>? onGoto,
      double textScale = 1,
      bool Function(int)? canContinue,
    }) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: LobbyWizard(
            steps: steps,
            current: current,
            onGoto: onGoto ?? (_) {},
            body: const [Text('body')],
            canContinue: canContinue,
          ),
        );

    Future<void> pumpAtSize(WidgetTester tester, Size size,
        {Widget? app}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app ?? wizard());
      await tester.pump();
    }

    Finder node(int i) => find.byKey(ValueKey('wizard-rail-node-$i'));

    testWidgets('six steps fit a phone, each with a finger-sized target',
        (tester) async {
      await pumpAtSize(tester, const Size(360, 720));

      for (var i = 0; i < sixSteps.length; i++) {
        final rect = tester.getRect(node(i));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360),
            reason: 'step $i must be on screen without scrolling a phone rail');
        expect(rect.width, greaterThanOrEqualTo(44),
            reason: 'step $i keeps a comfortable touch width');
        expect(rect.height, greaterThanOrEqualTo(48),
            reason: 'step $i keeps a comfortable touch height');
      }
    });

    testWidgets(
        'a 360dp phone keeps its step names; a 320dp one goes icon-only',
        (tester) async {
      // The common phone width: six names fit legibly beside the nodes.
      await pumpAtSize(tester, const Size(360, 720));
      expect(find.byKey(const ValueKey('wizard-step-label-0')), findsOneWidget);
      expect(find.text('Database'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // One- and two-word steps reserve the same label block, so the rail
      // stays an even band rather than a ragged one.
      final heights = [
        for (var i = 0; i < sixSteps.length; i++) tester.getRect(node(i)).height
      ];
      expect(heights.toSet(), hasLength(1),
          reason: 'every labelled node keeps the same height');

      // The narrowest phones cannot hold a legible name under six nodes: the
      // rail trades the labels for finger-sized targets rather than clip
      // them, and the header + tooltips keep every step named.
      await pumpAtSize(tester, const Size(320, 640), app: wizard());
      expect(find.byKey(const ValueKey('wizard-step-label-0')), findsNothing);
      expect(find.text('Step 1 of 6 — Avatar'), findsOneWidget);
      for (final step in sixSteps) {
        expect(find.byTooltip(step.title), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text goes icon-only rather than clipping a label',
        (tester) async {
      await pumpAtSize(tester, const Size(900, 720),
          app: wizard(textScale: 1.8));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('wizard-step-label-0')), findsNothing,
          reason: 'labels would need more room than the node has');
      expect(tester.widget<Semantics>(node(0)).properties.label,
          'Step 1 of 6 — Avatar',
          reason: 'the name survives for screen readers at any text size');
    });

    testWidgets('each node announces its step, state and tap action',
        (tester) async {
      var wentTo = -1;
      // A gate says the first step is cleared; without one the rail would ask
      // whether it was visited, and this wizard opens with only step 1 known.
      await pumpAtSize(tester, const Size(900, 720),
          app: wizard(
              current: 1, onGoto: (i) => wentTo = i, canContinue: (_) => true));

      final current = tester.widget<Semantics>(node(1)).properties;
      expect(current.label, 'Step 2 of 6 — Start');
      expect(current.button, isTrue);
      expect(current.selected, isTrue);
      expect(current.onTap, isNotNull);

      final done = tester.widget<Semantics>(node(0)).properties;
      expect(done.selected, isFalse);
      expect(done.label, 'Step 1 of 6 — Avatar');
      // Completed steps wear a check; the active node keeps its own glyph.
      expect(find.descendant(of: node(0), matching: find.byIcon(Icons.check)),
          findsOneWidget);
      expect(
          find.descendant(of: node(1), matching: find.byIcon(Icons.alt_route)),
          findsOneWidget);

      await tester.tap(node(0));
      expect(wentTo, 0, reason: 'the node stays reachable by pointer');
    });

    testWidgets('the keyboard focus draws its own ring on its own node',
        (tester) async {
      await pumpAtSize(tester, const Size(900, 720), app: wizard(current: 2));
      expect(
          find.byKey(const ValueKey('wizard-rail-focus-ring-2')), findsNothing,
          reason: 'nothing is focused yet');

      // Tab: the bar's contrast toggle, then the first rail node.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(find.byKey(const ValueKey('wizard-rail-focus-ring-0')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('wizard-rail-focus-ring-2')), findsNothing,
          reason: 'the current step is not focused, so it wears no ring');
      expect(find.text('Step 3 of 6 — Lobby'), findsOneWidget,
          reason: 'focus alone never navigates');

      // The ring is drawn outside the disc, so it cannot cover the current
      // step's fill, and it uses the theme's accent rather than its primary.
      final ring = find.byKey(const ValueKey('wizard-rail-focus-ring-0'));
      final ringRect = tester.getRect(ring);
      final discRect = tester.getRect(
          find.descendant(of: node(0), matching: find.byType(Container)).first);
      expect(ringRect.contains(discRect.center), isTrue);
      expect(ringRect.width, greaterThan(discRect.width));
      expect(ringRect.top, lessThan(discRect.top));
      final scheme = Theme.of(tester.element(find.text('body'))).colorScheme;
      expect((tester.widget<CustomPaint>(ring).painter as dynamic).color,
          scheme.tertiary,
          reason: 'focus ink is the theme\'s, not the current step\'s');

      // It follows the keyboard cursor, not the wizard's current step.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
          find.byKey(const ValueKey('wizard-rail-focus-ring-0')), findsNothing);
      expect(find.byKey(const ValueKey('wizard-rail-focus-ring-1')),
          findsOneWidget);
      expect(find.text('Step 3 of 6 — Lobby'), findsOneWidget);
    });

    testWidgets('in contrast mode focus is dashed and the current step rings',
        (tester) async {
      appContrast.enabled = true;
      addTearDown(appContrast.resetForTest);
      await pumpAtSize(tester, const Size(900, 720), app: wizard(current: 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab); // contrast toggle
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab); // node 0
      await tester.pump();

      final ring = find.byKey(const ValueKey('wizard-rail-focus-ring-0'));
      expect(ring, findsOneWidget);
      // The current node still rings its own disc in contrast mode, but it is
      // not focused: the two marks never collapse into one.
      expect(
          find.byKey(const ValueKey('wizard-rail-focus-ring-1')), findsNothing);
      final painter = tester.widget<CustomPaint>(ring).painter;
      final scheme = Theme.of(tester.element(find.text('body'))).colorScheme;
      expect((painter as dynamic).color, scheme.onSurface,
          reason: 'full ink, since contrast mode keeps no hues');
      expect((painter as dynamic).width, 2.0);

      // Focus on the current node too: both marks sit on it at once.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(const ValueKey('wizard-rail-focus-ring-1')),
          findsOneWidget);
    });

    testWidgets('jumping ahead does not check a step whose gate never passed',
        (tester) async {
      // The rail is free navigation, so the player can be on step 5 with 2 and
      // 4 still unfinished. Their markers must say so: only the steps whose
      // gate answered yes wear a check.
      await pumpAtSize(tester, const Size(900, 720),
          app: wizard(current: 4, canContinue: (i) => i.isEven));

      Finder mark(int i, IconData icon) =>
          find.descendant(of: node(i), matching: find.byIcon(icon));

      expect(mark(0, Icons.check), findsOneWidget);
      expect(mark(2, Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(2),
          reason: 'steps 1 and 3 are behind the player, not done');
      expect(mark(1, Icons.alt_route), findsOneWidget);
      expect(mark(3, Icons.sports_esports), findsOneWidget);
    });

    testWidgets('the rule into a step is lit by that step being cleared',
        (tester) async {
      await pumpAtSize(tester, const Size(900, 720),
          app: wizard(current: 4, canContinue: (i) => i.isEven));

      Color rule(int i) => tester
          .widget<Container>(find.descendant(
              of: find.byKey(ValueKey('wizard-rail-connector-$i')),
              matching: find.byType(Container)))
          .color!;
      final scheme = Theme.of(tester.element(find.text('body'))).colorScheme;

      expect(rule(1), scheme.primary.withValues(alpha: 0.5),
          reason: 'step 0 is done, so the road after it reads cleared');
      expect(rule(2), scheme.onSurface.withValues(alpha: 0.12),
          reason: 'step 1 never passed its gate: the segment stays dim');
    });

    testWidgets('without a gate only the steps actually visited are checked',
        (tester) async {
      await pumpAtSize(tester, const Size(900, 720), app: wizard(current: 0));

      // Walk to Start, then jump straight to World options over the two steps
      // in between: the host supplied no gate, so visits are the only evidence
      // of progress the wizard has.
      await tester.pumpWidget(wizard(current: 1));
      await tester.pump();
      await tester.pumpWidget(wizard(current: 4));
      await tester.pump();

      Finder mark(int i) =>
          find.descendant(of: node(i), matching: find.byIcon(Icons.check));

      expect(mark(0), findsOneWidget, reason: 'Avatar was visited');
      expect(mark(1), findsOneWidget, reason: 'Start was walked through');
      expect(find.byIcon(Icons.check), findsNWidgets(2),
          reason: 'Lobby and Game options were jumped over, never visited');
      expect(
          find.descendant(
              of: node(2), matching: find.byIcon(Icons.groups_outlined)),
          findsOneWidget,
          reason: 'an unvisited step keeps its own glyph instead of a check');
    });

    testWidgets('a gate that opens later turns its marker into a check',
        (tester) async {
      final open = ValueNotifier<bool>(false);
      addTearDown(open.dispose);
      Widget gated() => ValueListenableBuilder<bool>(
            valueListenable: open,
            builder: (context, passed, _) =>
                wizard(current: 3, canContinue: (i) => i != 1 || passed),
          );

      await pumpAtSize(tester, const Size(900, 720), app: gated());
      expect(find.descendant(of: node(1), matching: find.byIcon(Icons.check)),
          findsNothing,
          reason: 'the step is still unfinished');

      open.value = true;
      await tester.pump();
      expect(find.descendant(of: node(1), matching: find.byIcon(Icons.check)),
          findsOneWidget,
          reason: 'once the host opens the gate the step reads as done');
    });

    testWidgets('a rail too narrow to fit scrolls the active node into view',
        (tester) async {
      final many = List<LobbyStepDescriptor>.generate(
          10, (i) => LobbyStepDescriptor(title: 'Step $i', icon: Icons.circle));

      await pumpAtSize(tester, const Size(300, 640),
          app: wizard(steps: many, current: 9));
      await tester.pumpAndSettle();

      var active = tester.getRect(node(9));
      expect(active.left, greaterThanOrEqualTo(0));
      expect(active.right, lessThanOrEqualTo(300),
          reason: 'the step being edited is never parked off screen');

      // Stepping back home reveals the other end again.
      await tester.pumpWidget(wizard(steps: many, current: 0));
      await tester.pumpAndSettle();
      active = tester.getRect(node(0));
      expect(active.left, greaterThanOrEqualTo(0));
      expect(active.right, lessThanOrEqualTo(300));
    });
  });

  group('LobbyWizard layout resilience', () {
    const sixSteps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person),
      LobbyStepDescriptor(title: 'Start', icon: Icons.alt_route),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(title: 'Game options', icon: Icons.sports_esports),
      LobbyStepDescriptor(title: 'World options', icon: Icons.public),
      LobbyStepDescriptor(title: 'Database', icon: Icons.edit_note),
    ];

    Widget wizard({
      int current = 0,
      List<Widget>? body,
      double textScale = 1,
    }) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: LobbyWizard(
            steps: sixSteps,
            current: current,
            onGoto: _noop,
            body: body ?? const [Text('body')],
          ),
        );

    testWidgets('the nav row adapts instead of overflowing', (tester) async {
      // 320dp at 2× text is where the old Row burst by ~150dp — and Italian
      // ('Indietro', 'Continua') is wider than English even at 1×.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wizard(current: 1, textScale: 2));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'Back and Continue must not clip the padding');

      // Out of room for a row: each action takes the full step width so the
      // pair stays reachable instead of hugging the left edge.
      final backButton = tester.getRect(find.byType(OutlinedButton));
      final nextButton = tester.getRect(find.byType(FilledButton));
      for (final rect in [backButton, nextButton]) {
        expect(rect.left, 24);
        expect(rect.right, 296, reason: '320 - the step\'s 24dp padding');
      }
      expect(nextButton.top, greaterThan(backButton.bottom),
          reason: 'Continue sits under Back when the line cannot hold both');

      // A 375dp phone still fits the English row: same line, opposite ends.
      tester.view.physicalSize = const Size(375, 640);
      await tester.pumpWidget(wizard(current: 1));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final narrowBack = tester.getRect(find.text('Back'));
      final narrowNext = tester.getRect(find.text('Continue'));
      expect(narrowNext.top, narrowBack.top,
          reason: 'a row that fits keeps both actions on one line');

      // Where they fit they keep their edges: one line, Back left and
      // Continue pushed to the far right of the step's column.
      tester.view.physicalSize = const Size(900, 640);
      await tester.pumpWidget(wizard(current: 1));
      await tester.pump();
      final wideBack = tester.getRect(find.text('Back'));
      final wideNext = tester.getRect(find.text('Continue'));
      expect(wideNext.top, wideBack.top, reason: 'same line when it fits');
      expect(wideNext.left - wideBack.right, greaterThan(100),
          reason: 'the two buttons sit at opposite ends');
    });

    testWidgets('large text stacks the pair instead of a ragged second line',
        (tester) async {
      // A 375dp phone holds the English pair at 1×, but not at 2×: both
      // labels grow, so the Wrap would drop the primary onto its own line,
      // left-aligned under Back. The scale-aware threshold stretches both
      // instead, keeping the primary full-width and easy to hit.
      tester.view.physicalSize = const Size(375, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wizard(current: 1, textScale: 2));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final back = tester.getRect(find.byType(OutlinedButton));
      final next = tester.getRect(find.byType(FilledButton));
      expect(back.left, 24);
      expect(back.right, 351);
      expect(next.left, 24);
      expect(next.right, 351);
      expect(next.top, greaterThan(back.bottom),
          reason: 'stacked, so Continue sits under Back');
    });

    testWidgets('180dp at 4× text wraps every label instead of clipping',
        (tester) async {
      // Narrower than any phone and far past the largest system text size:
      // the labels have to wrap inside their buttons and the buttons have to
      // stay inside the step's padding. Nothing may overflow.
      tester.view.physicalSize = const Size(180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wizard(current: 1, textScale: 4));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final back = tester.getRect(find.byType(OutlinedButton));
      final next = tester.getRect(find.byType(FilledButton));
      for (final rect in [back, next]) {
        expect(rect.left, 24);
        expect(rect.right, 156, reason: '180 - the step\'s 24dp padding');
      }
      final label = tester.getRect(find.text('Continue'));
      expect(label.left, greaterThanOrEqualTo(next.left));
      expect(label.right, lessThanOrEqualTo(next.right),
          reason: 'the label wraps inside the button, never past its edge');
      expect(next.height, greaterThan(back.height),
          reason: 'the longer label earned an extra line');
    });

    testWidgets('a lone Continue keeps its width on a wide screen at 3×',
        (tester) async {
      // The scaled threshold only pairs up two actions. One action on a
      // tablet stays a normal button on the trailing edge instead of
      // stretching across the whole step.
      tester.view.physicalSize = const Size(900, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wizard(current: 0, textScale: 3));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final next = tester.getRect(find.byType(FilledButton));
      expect(next.width, lessThan(500));
      // The wizard caps its column at 760dp and centres it: 70 + 760 - 24.
      expect(next.right, 806, reason: 'still on the trailing edge');
    });

    testWidgets('a long done label survives 3× text on a tiny phone',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(3)),
          child: child!,
        ),
        home: LobbyWizard(
          steps: sixSteps,
          current: 1,
          onGoto: _noop,
          body: const [Text('body')],
          onDone: () {},
          doneLabel: 'ZURÜCK ZUR ÜBERSICHT',
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'translated labels wrap instead of clipping');

      final done = tester.getRect(find.byType(FilledButton));
      expect(done.left, 24);
      expect(done.right, 296);
      expect(done.height, greaterThan(48),
          reason: 'the label wraps rather than shrinking below 3×');
    });

    testWidgets('a new step opens at its own top', (tester) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final long = [for (var i = 0; i < 40; i++) Text('row $i')];
      await tester.pumpWidget(wizard(current: 1, body: long));
      await tester.pump();

      ScrollableState bodyScrollable() =>
          tester.state<ScrollableState>(find.descendant(
              of: find.byKey(const ValueKey('wizard-body')),
              matching: find.byType(Scrollable)));

      await tester.drag(find.text('row 3'), const Offset(0, -300));
      await tester.pump();
      expect(bodyScrollable().position.pixels, greaterThan(100),
          reason: 'the long step really scrolled');

      // Same widgets, next step: the offset belongs to the step that set it,
      // so the header of the new step is on screen instead of a stray form.
      await tester.pumpWidget(wizard(current: 2, body: long));
      await tester.pump();
      expect(bodyScrollable().position.pixels, 0);
      final header = tester.getRect(find.text('Step 3 of 6 — Lobby'));
      expect(header.top, greaterThanOrEqualTo(0));
      expect(header.top, lessThan(400));
    });
  });

  group('LobbyWizard keyboard and D-pad rail', () {
    const sixSteps = [
      LobbyStepDescriptor(title: 'Avatar', icon: Icons.person),
      LobbyStepDescriptor(title: 'Start', icon: Icons.alt_route),
      LobbyStepDescriptor(title: 'Lobby', icon: Icons.groups_outlined),
      LobbyStepDescriptor(title: 'Game options', icon: Icons.sports_esports),
      LobbyStepDescriptor(title: 'World options', icon: Icons.public),
      LobbyStepDescriptor(title: 'Database', icon: Icons.edit_note),
    ];

    /// A live wizard: onGoto actually moves the step, the way a host's
    /// setState would, so the rail can be walked with real key presses.
    Widget harness(ValueNotifier<int> step) => MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: step,
            builder: (context, current, _) => LobbyWizard(
              steps: sixSteps,
              current: current,
              onGoto: (i) => step.value = i,
              body: [Text('body of step $current')],
            ),
          ),
        );

    InkWell nodeInk(WidgetTester tester, int i) => tester.widget<InkWell>(find
        .descendant(
            of: find.byKey(ValueKey('wizard-rail-node-$i')),
            matching: find.byType(InkWell))
        .first);

    bool focused(WidgetTester tester, int i) =>
        nodeInk(tester, i).focusNode!.hasFocus;

    testWidgets('Tab lands on the rail and arrows walk the steps with focus',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await tester.pumpWidget(harness(step));
      await tester.pump();

      // The rail is reachable without a pointer; landing on it moves nothing.
      // The bar's contrast toggle is the first stop (setup is readable before
      // anything else), so the rail is one Tab further in.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(const ValueKey('contrast-toggle')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(tester, 0), isTrue,
          reason: 'Tab arrives at the rail, not past it');
      expect(step.value, 0);

      // Right/Left walk the rail; Down/Up are the D-pad's own arrows and do
      // the same, so a handset without a touch screen still gets everywhere.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(step.value, 1);
      expect(focused(tester, 1), isTrue,
          reason: 'the focus ring follows the step it moved to');
      expect(find.text('Step 2 of 6 — Start'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(step.value, 2);
      expect(focused(tester, 2), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(step.value, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(step.value, 0);

      // Home and End jump to either end of the setup.
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(step.value, 5);
      expect(focused(tester, 5), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(step.value, 0);
    });

    testWidgets('the ends do not wrap, so an arrow can leave the rail',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await tester.pumpWidget(harness(step));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(step.value, 0, reason: 'Left on the first step does nothing');

      step.value = 5;
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(step.value, 5, reason: 'Right on the last step does nothing');
    });

    testWidgets(
        'Tab still visits every node, and Enter activates the focused one',
        (tester) async {
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await tester.pumpWidget(harness(step));
      await tester.pump();

      await tester
          .sendKeyEvent(LogicalKeyboardKey.tab); // bar's contrast toggle
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(tester, 0), isTrue);

      // Arrows are not the only path: Tab reaches the other nodes too, and a
      // keyboard activation goes through the node's own tap target.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(tester, 1), isTrue);
      expect(step.value, 0, reason: 'focus alone never changes the step');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(step.value, 1);
    });
    testWidgets('arrows in the step body are the body\'s, not the rail\'s',
        (tester) async {
      // The key handler lives on the rail, so typing (or cursor movement) in a
      // text field below it must never jump the setup to another step.
      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: step,
          builder: (context, current, _) => LobbyWizard(
            steps: sixSteps,
            current: current,
            onGoto: (i) => step.value = i,
            body: const [TextField()],
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.end,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }
      expect(step.value, 0);
    });

    testWidgets('a narrow rail scrolls to keep the keyboard-moved node in view',
        (tester) async {
      tester.view.physicalSize = const Size(300, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final step = ValueNotifier<int>(0);
      addTearDown(step.dispose);
      await tester.pumpWidget(harness(step));
      await tester.pump();

      await tester
          .sendKeyEvent(LogicalKeyboardKey.tab); // bar's contrast toggle
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (var i = 1; i < sixSteps.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        // Each press is one step of a live host rebuild; without the frame
        // the rail would still be showing the step the last key left.
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(step.value, 5);
      final active =
          tester.getRect(find.byKey(const ValueKey('wizard-rail-node-5')));
      expect(active.left, greaterThanOrEqualTo(0));
      expect(active.right, lessThanOrEqualTo(300),
          reason: 'the node the keys walked to is on screen');
    });
  });

  group('LobbySeat', () {
    test('roundtrips through its map with defaults for old saves', () {
      final seat = LobbySeat(
          name: 'Mara',
          colorHex: 'FF4CAF50',
          interactEveryDays: 2,
          ready: true);
      final restored = LobbySeat.fromMap(seat.toMap());
      expect(restored.name, 'Mara');
      expect(restored.colorHex, 'FF4CAF50');
      expect(restored.interactEveryDays, 2);
      expect(restored.ready, isTrue);
      expect(restored.isAi, isFalse);
      expect(restored.color, const Color(0xFF4CAF50));
    });
  });
}
