import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

void main() {
  const seats = [
    CloudSeat(name: 'Marcuz', colorHex: 'FF9C27B0', ready: true),
    CloudSeat(name: 'Mara', colorHex: 'FF4CAF50', ready: false),
  ];
  CloudRoom room({bool isLocalHost = true, String designatedHost = ''}) =>
      CloudRoom(
        code: 'KZ9Q2',
        clock: 42,
        hasSnapshot: true,
        hasPassword: false,
        seats: seats,
        isLocalHost: isLocalHost,
        designatedHost: designatedHost,
      );

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('CloudRoomCard', () {
    testWidgets('renders seats local-first with the ringed own chip and crown',
        (tester) async {
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Mara',
      )));
      await tester.pump();

      // Local seat leads and is labeled "(you)".
      final mara =
          tester.getRect(find.byKey(const ValueKey('cloud-seat-KZ9Q2-Mara')));
      final marcuz =
          tester.getRect(find.byKey(const ValueKey('cloud-seat-KZ9Q2-Marcuz')));
      expect(mara.left, lessThan(marcuz.left));
      expect(find.text('Mara (you)'), findsOneWidget);
      // First seat holds the crown.
      expect(find.byTooltip('Host of this room'), findsOneWidget);
      // Status line carries the pending designation.
      expect(find.textContaining('host handover to Mara'), findsOneWidget);
    });

    testWidgets('flash wash shows the change note while it fades',
        (tester) async {
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(),
        localSeatName: 'Marcuz',
        flash: true,
        flashMessage: 'Mara is ready',
      )));
      await tester.pump();

      expect(find.byKey(const ValueKey('flash-note-KZ9Q2')), findsOneWidget);
      expect(find.text('Mara is ready'), findsOneWidget);
    });

    testWidgets('host menu offers handover, cancel and delete', (tester) async {
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Marcuz',
        onOpen: (_) {},
        onDelete: (_) {},
        onHandover: (_) {},
        onCancelHandover: (_) {},
        onLeave: (_) {},
      )));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cloud-menu-KZ9Q2')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('cloud-handover-KZ9Q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-cancel-handover-KZ9Q2')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-delete-KZ9Q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-leave-KZ9Q2')), findsNothing);
    });

    testWidgets(
        'claim button renders only for the designated local seat and fires',
        (tester) async {
      var claimed = 0;
      final designated = CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Mara',
        onClaim: (_) => claimed++,
      );
      await tester.pumpWidget(host(designated));
      await tester.pump();

      // One tap on the card itself: no menu, no detour.
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cloud-claim-KZ9Q2')));
      expect(claimed, 1);

      // Another device's seat sees no button…
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Marcuz',
        onClaim: (_) => claimed++,
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsNothing);

      // …no local seat at all means no button…
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: null,
        onClaim: (_) => claimed++,
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsNothing);

      // …and without the callback the seam stays closed even for the
      // designated seat (canClaim is the single gate).
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Mara',
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsNothing);
      expect(claimed, 1);
    });

    testWidgets('claim-only host: busy spinner and no empty menu',
        (tester) async {
      // The lobby's configuration: claim wired, no menu callbacks.
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Mara',
        onClaim: (_) {},
        claimBusy: true,
      )));
      await tester.pump();

      // Busy: spinner replaces the button (no double-tap invitation).
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Claim-only: no room menu at all when nothing is wired.
      expect(find.byKey(const ValueKey('cloud-menu-KZ9Q2')), findsNothing);

      await tester.pumpWidget(host(CloudRoomCard(
        room: room(designatedHost: 'Mara'),
        localSeatName: 'Mara',
        onClaim: (_) {},
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('cloud-claim-KZ9Q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-menu-KZ9Q2')), findsNothing);
    });

    testWidgets('joiner menu offers only leave', (tester) async {
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(isLocalHost: false),
        localSeatName: 'Mara',
        onLeave: (_) {},
      )));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cloud-menu-KZ9Q2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('cloud-leave-KZ9Q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-delete-KZ9Q2')), findsNothing);
      expect(find.byKey(const ValueKey('cloud-handover-KZ9Q2')), findsNothing);
    });

    testWidgets('callbacks route the menu choices to the host app',
        (tester) async {
      var opened = false;
      var deleted = false;
      await tester.pumpWidget(host(CloudRoomCard(
        room: room(),
        localSeatName: 'Marcuz',
        onOpen: (_) => opened = true,
        onDelete: (_) => deleted = true,
      )));
      await tester.pump();

      await tester.tap(find.text('World KZ9Q2 — hosted here'));
      expect(opened, isTrue);

      await tester.tap(find.byKey(const ValueKey('cloud-menu-KZ9Q2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cloud-delete-KZ9Q2')));
      expect(deleted, isTrue);
    });
  });

  group('room dialogs', () {
    testWidgets('delete confirmation needs the explicit universal press',
        (tester) async {
      late bool confirmed;
      await tester.pumpWidget(host(Builder(
          builder: (context) => TextButton(
                onPressed: () async =>
                    confirmed = await confirmDeleteRoomDialog(context, room()),
                child: const Text('go'),
              ))));
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.textContaining('removed for every seat'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-delete-room')));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });

    testWidgets('handover picker lists seats local-first and returns a name',
        (tester) async {
      late String? picked;
      await tester.pumpWidget(host(Builder(
          builder: (context) => TextButton(
                onPressed: () async => picked = await showHandoverSeatPicker(
                    context, room(),
                    localSeatName: 'Mara'),
                child: const Text('go'),
              ))));
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('handover-KZ9Q2-Mara')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('handover-KZ9Q2-Marcuz')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('handover-KZ9Q2-Marcuz')));
      await tester.pumpAndSettle();
      expect(picked, 'Marcuz');
    });

    test('revoked-credential detection covers the Postgres permission codes',
        () {
      expect(hostCredentialsRevoked(Exception('HTTP 401')), isTrue);
      expect(hostCredentialsRevoked(Exception('42501 permission')), isTrue);
      expect(hostCredentialsRevoked(Exception('connection refused')), isFalse);
    });
  });
}
