import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared lobby step: seats by game number, solo start, and the single
/// handoff callback the game's NEW-GAME section receives.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });

  Widget host({required ValueChanged<SharedLobbyHandoff> onHandoff}) =>
      MaterialApp(home: Scaffold(body: SharedLobbyStep(onHandoff: onHandoff)));

  testWidgets('solo start hands off offline with only the local seat',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();

    // The local seat renders with the persisted player's name.
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-Player')), findsOneWidget);
    expect(find.text('(you)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-solo')));
    await tester.pump();

    expect(handoff, isNotNull);
    expect(handoff!.online, isFalse);
    expect(handoff!.roomCode, isNull);
    expect(handoff!.seats, isEmpty);
    expect(handoff!.self.name, 'Player');
  });

  testWidgets('adding a seat locks the game number; JOIN GAME hands off online',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();

    // Before any seat: JOIN GAME is disabled — solo is the only way out.
    final joinBefore = tester.widget<FilledButton>(
        find.byKey(const ValueKey('shared-lobby-start-online')));
    expect(joinBefore.onPressed, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), 'K7QX2');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();

    // An open slot appeared — no name asked — and the number committed.
    expect(
        find.byKey(const ValueKey('shared-lobby-seat-open-2')), findsOneWidget);

    // Claim it, then JOIN GAME carries the claimed seat online.
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pump();

    expect(handoff, isNotNull);
    expect(handoff!.online, isTrue);
    expect(handoff!.roomCode, 'K7QX2');
    expect(handoff!.seats.single.name, 'Ines');
    expect(handoff!.self.name, 'Player');
  });

  testWidgets('removing an open slot unlocks the game number again',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();

    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), 'K7QX2');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-remove-open-2')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('shared-lobby-seat-open-2')), findsNothing);
    // The committed number is nobody's join any more — the field reads
    // empty and unlocked for a fresh join.
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-game-number')));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, isEmpty);
    expect(handoff, isNull, reason: 'removing a seat never fires the handoff');
  });

  testWidgets('an empty game number shows the localized error, adds nothing',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();

    expect(find.text('Enter the game number the host shared.'), findsOneWidget);
    expect(handoff, isNull);
  });

  testWidgets('the local seat carries the persisted player name',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'prefs.account.playerName': 'Mara'});
    account.resetForTest();
    await account.load();
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-solo')));
    await tester.pump();

    expect(handoff!.self.name, 'Mara');
  });

  testWidgets('starting the table announces it: Starting table {code}',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();

    // Build a startable table: commit the number, open a seat, claim it.
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-game-number')), '7');
    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
    await tester.pumpAndSettle();
    // The welcome snackbar queues ahead — let it pass.
    await tester.pump(const Duration(seconds: 4));

    // The exit is as visible as the arrival: the confirmation shows as
    // the handoff fires, and the code rides into the game.
    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pump();

    expect(find.text(appLocale.strings.startingTableAs('7')), findsOneWidget);
    expect(handoff, isNotNull);
    expect(handoff!.online, isTrue);
    expect(handoff!.roomCode, '7');
  });

  testWidgets(
      'a locked code with no seats arms JOIN GAME for the invited guest',
      (tester) async {
    SharedLobbyHandoff? handoff;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SharedLobbyStep(
          onHandoff: (h) => handoff = h,
          initialCode: 'K7QX2',
        ),
      ),
    ));
    await tester.pump();

    // Armed with zero seats: the guest is joining the host's table.
    final join = tester.widget<FilledButton>(
        find.byKey(const ValueKey('shared-lobby-start-online')));
    expect(join.onPressed, isNotNull);

    // The arrival snackbar holds the messenger for its full window(s) in
    // fake time — pump until it is really gone before starting, so the
    // exit confirmation is the one on stage.
    for (var i = 0;
        i < 12 && find.byType(SnackBar).evaluate().isNotEmpty;
        i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();

    // The exit fires the online handoff — the code travels, the exit
    // confirmation announces the table.
    await tester
        .ensureVisible(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pumpAndSettle();

    expect(handoff, isNotNull);
    expect(handoff!.online, isTrue);
    expect(handoff!.roomCode, 'K7QX2');
    expect(handoff!.seats, isEmpty);
    expect(
        find.text(appLocale.strings.startingTableAs('K7QX2')), findsOneWidget);
  });

  group('invite QR', () {
    testWidgets(
        'a committed code with a base URL shows a QR encoding the invite link',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SharedLobbyStep(
            onHandoff: (_) {},
            initialCode: 'K7QX2',
            inviteBaseUrl: Uri.parse('https://game.example/play'),
          ),
        ),
      ));
      await tester.pump();

      expect(
          find.byKey(const ValueKey('shared-lobby-invite-qr')), findsOneWidget);
      // The QR encodes exactly the invite link — same contract the copy
      // and email buttons share (asserted via the semantics label, the
      // widget's public echo of its payload).
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.semanticsLabel, 'https://game.example/play#join=K7QX2');
      expect(find.text(appLocale.strings.inviteQrHint), findsOneWidget);
    });

    testWidgets(
        'no base URL means no QR — a fragment-only invite is nothing to scan',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SharedLobbyStep(onHandoff: (_) {}, initialCode: 'K7QX2'),
        ),
      ));
      await tester.pump();

      // The invite section itself is still there (copy, email…).
      expect(find.byKey(const ValueKey('shared-lobby-invite-link')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('shared-lobby-invite-qr')), findsNothing);
    });

    testWidgets('the QR hides until the code is committed', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SharedLobbyStep(
            onHandoff: (_) {},
            inviteBaseUrl: Uri.parse('https://game.example/play'),
          ),
        ),
      ));
      await tester.pump();

      expect(
          find.byKey(const ValueKey('shared-lobby-invite-qr')), findsNothing);
    });
  });
}
