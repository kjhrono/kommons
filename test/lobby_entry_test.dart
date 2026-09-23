import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared lobby entry: the proposed player name plus the two front
/// doors (single- and multi-player), and the reshaped seat lobby behind
/// the multi door — open seats claimed by tap, never named up front.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });

  group('SharedLobbyEntry', () {
    Widget host({
      void Function(String)? onSingle,
      void Function(String)? onMulti,
    }) =>
        MaterialApp(
            home: Scaffold(
                body: SharedLobbyEntry(
          onSinglePlayer: onSingle ?? (_) {},
          onMultiPlayer: onMulti ?? (_) {},
        )));

    testWidgets('the name field proposes the persisted player name',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'prefs.account.playerName': 'Mara'});
      account.resetForTest();
      await account.load();

      await tester.pumpWidget(host());
      await tester.pump();

      expect(
        tester.widget<TextField>(
            find.byKey(const ValueKey('shared-lobby-entry-name'))),
        isA<TextField>().having((f) => f.controller!.text, 'text', 'Mara'),
      );
    });

    testWidgets('SINGLE-PLAYER persists the edited name and hands it over',
        (tester) async {
      String? name;
      await tester.pumpWidget(
          host(onSingle: (n) => name = n, onMulti: (n) => name = n));
      await tester.pump();

      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-entry-name')), 'Rook');
      await tester.tap(find.byKey(const ValueKey('shared-lobby-entry-single')));
      await tester.pump();

      expect(name, 'Rook');
      expect(account.playerName, 'Rook',
          reason: 'the edit lands in the account, not a lobby-local copy');
    });

    testWidgets('MULTI-PLAYER is the door to the seat lobby', (tester) async {
      String? name;
      await tester.pumpWidget(host(onMulti: (n) => name = n));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shared-lobby-entry-multi')));
      await tester.pump();

      expect(name, 'Player'); // the untouched proposal passes through
    });

    testWidgets('a blank name keeps the persisted one', (tester) async {
      String? name;
      await tester.pumpWidget(host(onSingle: (n) => name = n));
      await tester.pump();

      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-entry-name')), '   ');
      await tester.tap(find.byKey(const ValueKey('shared-lobby-entry-single')));
      await tester.pump();

      expect(name, 'Player');
      expect(account.playerName, 'Player');
    });
  });

  group('open seats in the lobby', () {
    Widget host({required ValueChanged<SharedLobbyHandoff> onHandoff}) =>
        MaterialApp(
            home: Scaffold(body: SharedLobbyStep(onHandoff: onHandoff)));

    Future<void> commitCode(WidgetTester tester,
        {String code = 'K7QX2'}) async {
      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-game-number')), code);
      await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
      await tester.pumpAndSettle();
    }

    testWidgets('ADD SEAT opens a slot instead of asking a name',
        (tester) async {
      await tester.pumpWidget(host(onHandoff: (_) {}));
      await tester.pump();
      await commitCode(tester);

      // The open seat: advertised as SEAT 2 — open, no name asked.
      expect(find.byKey(const ValueKey('shared-lobby-seat-open-2')),
          findsOneWidget);
      expect(find.text('SEAT 2 — open'), findsOneWidget);
      expect(find.text('Guest 2'), findsNothing);

      // And a second ADD SEAT opens SEAT 3.
      await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shared-lobby-seat-open-3')),
          findsOneWidget);
    });

    testWidgets('claiming a seat names it and welcomes the player',
        (tester) async {
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
      await tester.pump();
      await commitCode(tester);

      await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
      await tester.pumpAndSettle();

      // The open label is gone; the claimed name shows.
      expect(
          find.byKey(const ValueKey('shared-lobby-seat-open-2')), findsNothing);
      expect(
          find.byKey(const ValueKey('shared-lobby-seat-Ines')), findsOneWidget);
      expect(find.text('Seat taken — welcome, Ines!'), findsOneWidget);

      // The claimed seat rides the handoff.
      await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
      await tester.pump();
      expect(handoff!.seats.single.name, 'Ines');
    });

    testWidgets('a cancelled or blank claim keeps the seat open',
        (tester) async {
      await tester.pumpWidget(host(onHandoff: (_) {}));
      await tester.pump();
      await commitCode(tester);

      await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shared-lobby-seat-open-2')),
          findsOneWidget);

      // A blank confirm (whitespace only) leaves it open too.
      await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-claim-name')), '   ');
      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shared-lobby-seat-open-2')),
          findsOneWidget);
    });

    testWidgets('removing an open slot renumbers the seats below it',
        (tester) async {
      await tester.pumpWidget(host(onHandoff: (_) {}));
      await tester.pump();
      await commitCode(tester);
      await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
      await tester.pumpAndSettle();
      expect(find.text('SEAT 2 — open'), findsOneWidget);
      expect(find.text('SEAT 3 — open'), findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-remove-open-2')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('shared-lobby-seat-open-3')), findsNothing);
      expect(find.text('SEAT 2 — open'), findsOneWidget,
          reason: 'SEAT 3 closed the gap and became SEAT 2 again');
    });

    testWidgets('an open seat blocks the start until claimed', (tester) async {
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
      await tester.pump();
      await commitCode(tester);

      final start = tester.widget<FilledButton>(
          find.byKey(const ValueKey('shared-lobby-start-online')));
      expect(start.onPressed, isNull,
          reason: 'an open seat is a promise not yet kept');
      expect(handoff, isNull);

      await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
      await tester.pumpAndSettle();

      final startAfter = tester.widget<FilledButton>(
          find.byKey(const ValueKey('shared-lobby-start-online')));
      expect(startAfter.onPressed, isNotNull);
    });

    testWidgets('the local seat stays seat 1 with the proposed name',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'prefs.account.playerName': 'Mara'});
      account.resetForTest();
      await account.load();
      await tester.pumpWidget(host(onHandoff: (_) {}));
      await tester.pump();

      expect(
          find.byKey(const ValueKey('shared-lobby-seat-Mara')), findsOneWidget);
      expect(find.text('(you)'), findsOneWidget);
    });
  });
}
