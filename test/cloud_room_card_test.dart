import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kjhrono_commons/kjhrono_commons.dart';

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
      final mara = tester.getRect(
          find.byKey(const ValueKey('cloud-seat-KZ9Q2-Mara')));
      final marcuz = tester.getRect(
          find.byKey(const ValueKey('cloud-seat-KZ9Q2-Marcuz')));
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

    testWidgets('host menu offers handover, cancel and delete',
        (tester) async {
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

      expect(find.byKey(const ValueKey('cloud-handover-KZ9Q2')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('cloud-cancel-handover-KZ9Q2')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-delete-KZ9Q2')), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-leave-KZ9Q2')), findsNothing);
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
      await tester.pumpWidget(host(Builder(builder: (context) => TextButton(
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
      await tester.pumpWidget(host(Builder(builder: (context) => TextButton(
        onPressed: () async => picked = await showHandoverSeatPicker(
            context, room(), localSeatName: 'Mara'),
        child: const Text('go'),
      ))));
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('handover-KZ9Q2-Mara')), findsOneWidget);
      expect(find.byKey(const ValueKey('handover-KZ9Q2-Marcuz')), findsOneWidget);
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
