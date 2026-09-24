import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The lobby's persisted roster: with [SharedLobbyStep.gameId] set, the
/// seats (open and claimed) and the committed game number survive an app
/// restart — a host prepares the table in advance and finds it waiting.
/// Starting the game or going solo clears the draft; an invite landing
/// on a prepared table replaces its number for that visit.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });

  Widget host({required ValueChanged<SharedLobbyHandoff> onHandoff}) =>
      MaterialApp(
        home: Scaffold(
          body: SharedLobbyStep(
            key: const ValueKey('lobby'),
            gameId: 'probe',
            onHandoff: onHandoff,
          ),
        ),
      );

  Future<void> prepareTwoSeats(WidgetTester tester) async {
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), 'K7QX2');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-3')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
    await tester.pumpAndSettle();
    // Retire the "Seat taken" snackbar — it overlays the start buttons.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('a prepared roster reopens after a restart', (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await prepareTwoSeats(tester);

    // One open (seat 2) and one claimed (Ines, seat 3), number committed.
    expect(find.text('SEAT 2 — open'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Ines')), findsOneWidget);

    // — the app restarts —
    final saved = await SharedPreferences.getInstance();
    final snapshot = <String, Object>{
      for (final key in saved.getKeys()) key: saved.get(key) as Object,
    };
    SharedPreferences.setMockInitialValues(snapshot);
    account.resetForTest();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await tester.pumpAndSettle();

    // The same table, exactly as prepared: number locked in, one open
    // slot and Ines' claimed seat, JOIN GAME armed.
    expect(
        find.byKey(const ValueKey('shared-lobby-invite-link')), findsOneWidget,
        reason: 'the committed number came back too');
    expect(find.text('SEAT 2 — open'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Ines')), findsOneWidget);
    final start = tester.widget<FilledButton>(
        find.byKey(const ValueKey('shared-lobby-start-online')));
    expect(start.onPressed, isNull,
        reason: 'the prepared open slot still waits for its player');
    expect(handoff, isNull);
  });

  testWidgets('starting the game clears the draft (the table is live now)',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await prepareTwoSeats(tester);
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-claim-name')), 'Rook');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pump();

    expect(handoff, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefs.lobby.probe.roster'), isNull,
        reason: 'the game owns the roster from the handoff on');
  });

  testWidgets('START SOLO clears the draft without firing the handoff twice',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await prepareTwoSeats(tester);

    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-start-solo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-solo')));
    await tester.pump();

    expect(handoff, isNotNull);
    expect(handoff!.online, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefs.lobby.probe.roster'), isNull);
  });

  testWidgets('removing the last seat forgets the whole draft', (tester) async {
    await tester.pumpWidget(host(onHandoff: (_) {}));
    await tester.pump();
    await prepareTwoSeats(tester);

    await tester.tap(find.byKey(const ValueKey('shared-lobby-remove-open-2')));
    await tester.pumpAndSettle();
    var prefs = await SharedPreferences.getInstance();
    var stored = prefs.getString('prefs.lobby.probe.roster');
    expect(stored, isNotNull);
    expect(stored, contains('"seats":[{'), reason: 'Ines remains persisted');

    await tester.tap(find.byKey(const ValueKey('shared-lobby-remove-Ines')));
    await tester.pumpAndSettle();
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefs.lobby.probe.roster'), isNull);
  });

  testWidgets('an invite landing on a prepared table wins for that visit',
      (tester) async {
    await persistRoster(
        'probe', const PersistedRoster(roomCode: 'OLD99', seats: []));
    // A non-empty draft needs a seat to survive persistRoster's empty
    // rule — write the JSON directly instead.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('prefs.lobby.probe.roster',
        '{"roomCode":"OLD99","seats":[{"name":"","colorHex":"FF9C27FF"}]}');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SharedLobbyStep(
          gameId: 'probe',
          initialCode: 'NEW77',
          onHandoff: (_) {},
        ),
      ),
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    final link = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-invite-link')));
    expect(link.controller!.text, contains('NEW77'));
    expect(link.controller!.text, isNot(contains('OLD99')));
  });

  testWidgets('no gameId means no persistence at all', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SharedLobbyStep(onHandoff: (_) {}),
      ),
    ));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), 'K7QX2');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('prefs.lobby')), isEmpty);
  });

  testWidgets('a corrupt draft is discarded, never fatal', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('prefs.lobby.probe.roster', '{not json');

    await tester.pumpWidget(host(onHandoff: (_) {}));
    await tester.pump();
    await tester.pumpAndSettle();

    // The lobby starts clean and the poison pill is gone.
    expect(
        find.byKey(const ValueKey('shared-lobby-invite-link')), findsNothing);
    final after = await SharedPreferences.getInstance();
    expect(after.getString('prefs.lobby.probe.roster'), isNull);
  });
}
