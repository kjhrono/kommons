import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

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
