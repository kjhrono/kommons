import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The scan-QR join entry point: the camera executor is stubbed like
/// [qrShareExecutor] before it, so the flow is exercised without a camera —
/// scan → confirm → committed and locked like a hand-typed join.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });
  tearDown(() {
    joinScanExecutor = scanJoinCodeWithCamera;
  });

  Widget host({required ValueChanged<SharedLobbyHandoff> onHandoff}) =>
      MaterialApp(home: Scaffold(body: SharedLobbyStep(onHandoff: onHandoff)));

  testWidgets('a scanned code joins through the confirm dialog',
      (tester) async {
    SharedLobbyHandoff? handoff;
    joinScanExecutor = ({required context, required scanLabel}) async {
      expect(scanLabel, 'Scan a friend’s QR');
      return const JoinScanResult.joined('K7QX2');
    };

    await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-scan')));
    await tester.pumpAndSettle();

    // The confirm dialog names the persona, exactly like the paste flow.
    expect(find.text('Invite found — join as Player?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-accept')));
    await tester.pumpAndSettle();

    // Committed and locked like a hand-typed join: the field locks and
    // the code shows in the invite link (never typed into the field).
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-game-number')));
    expect(field.enabled, isFalse);
    final link = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-invite-link')));
    expect(link.controller!.text, '#join=K7QX2');

    // Online start carries the scanned code — after a seat opens and is
    // claimed (JOIN GAME waits for every promised seat to sit down).
    await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shared-lobby-claim-name')), 'Ines');
    await tester.tap(find.byKey(const ValueKey('shared-lobby-claim-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-start-online')));
    await tester.pump();
    expect(handoff!.online, isTrue);
    expect(handoff!.roomCode, 'K7QX2');
  });

  testWidgets('declining the confirm leaves the lobby untouched',
      (tester) async {
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.joined('K7QX2');

    await tester.pumpWidget(host(onHandoff: (_) {}));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-scan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-cancel')));
    await tester.pumpAndSettle();

    // The lobby is untouched: the number field stays empty and unlocked,
    // the invite section never appears, solo is still the way out.
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-lobby-game-number')));
    expect(field.enabled, isTrue);
    expect(
        find.byKey(const ValueKey('shared-lobby-invite-link')), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('shared-lobby-add-seat')))
            .onPressed,
        isNotNull);
  });

  testWidgets('a camera failure says so and stays joinable', (tester) async {
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.failed();

    await tester.pumpWidget(host(onHandoff: (_) {}));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-scan')));
    await tester.pump();

    expect(find.text('Camera unavailable — enter the number instead.'),
        findsOneWidget);
    // The manual join path is untouched.
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('shared-lobby-add-seat')))
            .onPressed,
        isNotNull);
  });

  testWidgets('closing the scanner without a result stays quiet',
      (tester) async {
    joinScanExecutor = ({required context, required scanLabel}) async =>
        const JoinScanResult.dismissed();

    await tester.pumpWidget(host(onHandoff: (_) {}));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-scan')));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });

  test('parsing accepts invite links and bare codes, nothing else', () {
    // The QR the shell draws.
    final full = joinCodeFromScannedText(
        'https://game.example/play#join=K7QX2&server=https://srv.example');
    expect(full?.code, 'K7QX2');
    expect(full?.host, Uri.parse('https://srv.example'));
    // A shortener's query form.
    expect(
        joinCodeFromScannedText('https://g.example/j?join=AB12')?.code, 'AB12');
    // A bare code someone made by hand.
    expect(joinCodeFromScannedText(' K7QX2 ')?.code, 'K7QX2');
    // Not invites: a web page, a sentence, a product barcode.
    expect(joinCodeFromScannedText('https://news.example/article'), isNull);
    expect(joinCodeFromScannedText('Hello world'), isNull);
    expect(joinCodeFromScannedText('5 901234 123457'), isNull);
    expect(joinCodeFromScannedText(null), isNull);
  });
}
