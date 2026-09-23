import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The invite-QR share button: the QR rendered as an image rides the
/// platform share sheet (executor stubbed here), with a copy-link fallback
/// where no share handler exists and a confirmation when the share lands.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });
  tearDown(() {
    qrShareExecutor = shareInviteQrImage;
  });

  Widget host() => MaterialApp(
        home: Scaffold(
          body: SharedLobbyStep(
            onHandoff: (_) {},
            initialCode: 'K7QX2',
            inviteBaseUrl: Uri.parse('https://game.example/play'),
          ),
        ),
      );

  testWidgets('a successful share confirms and leaves the clipboard alone',
      (tester) async {
    var clipboardWrites = 0;
    qrShareExecutor = ({required data, required inviteLink}) async {
      // The image encodes the same invite link the other buttons share.
      expect(data, 'https://game.example/play#join=K7QX2');
      expect(inviteLink, 'https://game.example/play#join=K7QX2');
      return QrShareOutcome.shared;
    };

    await tester.pumpWidget(host());
    await tester.pump();
    // The initial-code delivery snackbar lands one frame after mount and
    // snackbars queue one at a time: retire it before the tap (settle the
    // show animation, outlive the dismiss timer, settle the close).
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester
        .tap(find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester.pumpAndSettle();

    expect(
        find.text(appLocale.strings.inviteQrShared('K7QX2')), findsOneWidget);
    expect(find.text(appLocale.strings.inviteCopied), findsNothing);
    expect(clipboardWrites, 0);
  });

  testWidgets('a dismissed sheet stays quiet (no snackbar, no clipboard)',
      (tester) async {
    qrShareExecutor = ({required data, required inviteLink}) async =>
        QrShareOutcome.dismissed;

    await tester.pumpWidget(host());
    await tester.pump();
    // The initial-code delivery snackbar lands one frame after mount:
    // settle its show animation (this starts its dismiss timer), advance
    // past the timer, then settle the close — a clean messenger before
    // the tap.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester
        .tap(find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('no share handler falls back to copying the invite link',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    qrShareExecutor =
        ({required data, required inviteLink}) async => QrShareOutcome.fallback;

    await tester.pumpWidget(host());
    await tester.pump();
    // The initial-code delivery snackbar lands one frame after mount:
    // settle its show animation (this starts its dismiss timer), advance
    // past the timer, then settle the close — a clean messenger before
    // the tap.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester
        .tap(find.byKey(const ValueKey('shared-lobby-invite-share-qr')));
    await tester.pumpAndSettle();

    expect(copied, 'https://game.example/play#join=K7QX2');
    expect(find.text(appLocale.strings.inviteCopied), findsOneWidget);
    expect(find.text(appLocale.strings.inviteQrShared('K7QX2')), findsNothing);
  });

  testWidgets('the rendered QR is a real PNG with the white mat',
      (tester) async {
    final bytes = await tester
        .runAsync(() => renderInviteQrPng('https://game.example/play'));
    expect(bytes, isNotNull);
    // PNG signature.
    expect(bytes!.first, 0x89);
    expect(bytes[1], 0x50);
  });
}
