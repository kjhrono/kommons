import 'dart:async';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The invite story: links that carry a game number (…#join=K7QX2), the
/// lobby's invite section for the host (copy / email / paste-to-join),
/// and ShellApp's delivery of an opened link into the app.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('join link parsing', () {
    test('round-trips the fragment form it produces', () {
      const invite = JoinInvite(code: 'K7QX2');
      expect(invite.link(), '#join=K7QX2');

      final parsed =
          joinInviteFromUri(Uri.parse('https://herald.game/#join=K7QX2'));
      expect(parsed, isNotNull);
      expect(parsed!.code, 'K7QX2');
      expect(parsed.host, isNull);
    });

    test('bases the link on a URL when given', () {
      const invite = JoinInvite(code: 'K7QX2');
      final link = invite.link(base: Uri.parse('https://herald.game/next'));
      expect(link, 'https://herald.game/next#join=K7QX2');
      // …and the link parses back to the same invite.
      final parsed = joinInviteFromUri(Uri.parse(link));
      expect(parsed!.code, 'K7QX2');
    });

    test('reads the query form a shortener hands out, with a host', () {
      final parsed = joinInviteFromUri(Uri.parse(
          'https://herald.game/lobby?join=K7QX2&server=https%3A%2F%2Fgames.example.org'));
      expect(parsed!.code, 'K7QX2');
      expect(parsed.host, Uri.parse('https://games.example.org'));
    });

    test('a link without an invite parses to null', () {
      expect(joinInviteFromUri(Uri.parse('https://herald.game/')), isNull);
      expect(joinInviteFromUri(Uri.parse('https://herald.game/#ref=news')),
          isNull);
      expect(joinInviteFromClipboardText('look at this cat'), isNull);
      expect(joinInviteFromClipboardText(null), isNull);
      expect(joinInviteFromClipboardText('   '), isNull);
    });

    test('clipboard text tolerates stray whitespace and bare fragments', () {
      final pasted =
          joinInviteFromClipboardText('  https://herald.game/#join=K7QX2 \n');
      expect(pasted!.code, 'K7QX2');

      final bare = joinInviteFromClipboardText('#join=ABC12');
      expect(bare!.code, 'ABC12');
    });
  });

  group('lobby invite section (host side)', () {
    Widget host({
      required ValueChanged<SharedLobbyHandoff> onHandoff,
      String? initialCode,
    }) =>
        MaterialApp(
          home: Scaffold(
            // A scrollable body like the games' lobbies: the invite
            // section lives at the bottom of the column.
            body: ListView(
              children: [
                SharedLobbyStep(
                  onHandoff: onHandoff,
                  initialCode: initialCode,
                ),
              ],
            ),
          ),
        );

    testWidgets(
        'an invite-committed number locks in and shows the invite section',
        (tester) async {
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(
          host(onHandoff: (h) => handoff = h, initialCode: 'K7QX2'));
      await tester.pump();

      // The player is told which persona the invite seats.
      expect(find.text(appLocale.strings.inviteJoinedAs('Player')),
          findsOneWidget);

      // The number field is locked without a hand-typed join.
      final field = tester.widget<TextField>(
          find.byKey(const ValueKey('shared-lobby-game-number')));
      expect(field.enabled, isFalse);

      // The invite link renders with the committed code.
      final link = tester.widget<TextField>(
          find.byKey(const ValueKey('shared-lobby-invite-link')));
      expect(link.controller!.text, '#join=K7QX2');

      // JOIN GAME is live and carries the committed code.
      await tester.tap(find.byKey(const ValueKey('shared-lobby-start-solo')));
      await tester.pump();
      expect(handoff, isNotNull);

      final join = tester.widget<FilledButton>(
          find.byKey(const ValueKey('shared-lobby-start-online')));
      expect(join.onPressed, isNull,
          reason: 'no guests yet: solo is the only exit');
    });
    testWidgets('copy puts the link on the clipboard and says so',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      await tester.pumpWidget(host(onHandoff: (_) {}, initialCode: 'K7QX2'));
      await tester.pumpAndSettle();

      // Retire the "invited as…" snackbar so the copy feedback isn't
      // queued behind it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
          find.byKey(const ValueKey('shared-lobby-invite-copy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-copy')));
      await tester.pumpAndSettle();

      expect(copied, '#join=K7QX2');
      expect(find.text(appLocale.strings.inviteCopied), findsOneWidget);
    });
    testWidgets('paste joins the pasted invite after a confirm',
        (tester) async {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'https://herald.game/#join=ZZ9PL'};
        }
        return null;
      });
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-paste')));
      await tester.pumpAndSettle();

      // The confirm dialog names the persona it will seat.
      expect(find.text(appLocale.strings.invitePastedJoinAs('Player')),
          findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-invite-accept')));
      await tester.pumpAndSettle();

      // The number locked in as if the player had typed it.
      final field = tester.widget<TextField>(
          find.byKey(const ValueKey('shared-lobby-game-number')));
      expect(field.enabled, isFalse);
      expect(find.byKey(const ValueKey('shared-lobby-invite-link')),
          findsOneWidget);

      // No guests yet: JOIN GAME stays disabled (solo is the only exit).
      final join = tester.widget<FilledButton>(
          find.byKey(const ValueKey('shared-lobby-start-online')));
      expect(join.onPressed, isNull);
      expect(handoff, isNull);
    });

    testWidgets('paste with no invite on the clipboard explains itself',
        (tester) async {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return null;
        return null;
      });
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(host(onHandoff: (h) => handoff = h));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('shared-lobby-invite-paste')));
      await tester.pumpAndSettle();

      expect(find.text(appLocale.strings.inviteNothingToPaste), findsOneWidget);
      expect(handoff, isNull);
    });

    testWidgets('removing the last guest releases the invited number',
        (tester) async {
      SharedLobbyHandoff? handoff;
      await tester.pumpWidget(
          host(onHandoff: (h) => handoff = h, initialCode: 'K7QX2'));
      await tester.pumpAndSettle();

      // Retire the "invited as…" snackbar so it can't cover the buttons.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('shared-lobby-add-seat')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('shared-lobby-remove-open-2')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('shared-lobby-remove-open-2')));
      await tester.pumpAndSettle();

      // The invite section is gone and the number unlocks for a fresh join.
      expect(
          find.byKey(const ValueKey('shared-lobby-invite-link')), findsNothing);
      final add = tester.widget<FilledButton>(
          find.byKey(const ValueKey('shared-lobby-add-seat')));
      expect(add.onPressed, isNotNull);
      expect(handoff, isNull);
    });
  });

  group('ShellApp invite delivery', () {
    final links = _FakeLinks();
    final originalPlatform = AppLinksPlatform.instance;

    setUp(() {
      AppLinksPlatform.instance = links;
      links.initialLink = null; // one test's cold start must not leak
    });
    tearDown(() => AppLinksPlatform.instance = originalPlatform);

    Future<void> pumpShell(WidgetTester tester, List<Uri> delivered) async {
      await tester.pumpWidget(ShellApp(
        title: 'HERALD',
        seedColor: const Color(0xff7a5c2e),
        onJoinInvite: (invite) =>
            delivered.add(Uri.parse('join:${invite.code}')),
        home: const Scaffold(body: Text('splash')),
      ));
      await tester.pump(); // first frame…
      await tester.pump(); // …then the postFrameCallback delivery
    }

    testWidgets('a cold-start join link reaches the handler once',
        (tester) async {
      links.initialLink = Uri.parse('https://herald.game/#join=COLD1');
      final delivered = <Uri>[];
      await pumpShell(tester, delivered);

      expect(delivered, [Uri.parse('join:COLD1')]);
    });

    testWidgets('a warm return arrives over the stream', (tester) async {
      final delivered = <Uri>[];
      await pumpShell(tester, delivered);

      links.controller.add(Uri.parse('mygame://lobby#join=WARM7'));
      // One pump for the stream event, one for the post-frame delivery.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      debugPrint('DELIVERED so far: $delivered');

      expect(delivered, [Uri.parse('join:WARM7')]);
    });

    testWidgets('links without an invite are ignored', (tester) async {
      links.initialLink = Uri.parse('https://herald.game/#ref=news');
      final delivered = <Uri>[];
      await pumpShell(tester, delivered);

      expect(delivered, isEmpty);
    });
  });
}

class _FakeLinks extends AppLinksPlatform {
  Uri? initialLink;
  final controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriLinkStream => controller.stream;
}
