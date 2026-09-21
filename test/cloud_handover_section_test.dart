import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

void main() {
  const seats = [
    CloudSeat(name: 'Mara', colorHex: 'FF4CAF50', ready: true),
  ];
  CloudRoom room(String code) => CloudRoom(
        code: code,
        clock: 3,
        hasSnapshot: true,
        hasPassword: false,
        seats: seats,
        isLocalHost: false,
        designatedHost: 'Mara',
      );

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders header, error line and one claim-only card per room',
      (tester) async {
    var claimed = '';
    await tester.pumpWidget(host(CloudHandoverSection(
      rooms: [room('AAAA'), room('BBBB')],
      onClaim: (room) => claimed = room.code,
      claimBusy: true,
    )));
    await tester.pump();

    expect(find.text('PENDING HOST HANDOVERS'), findsOneWidget);
    expect(find.byKey(const ValueKey('handover-AAAA')), findsOneWidget);
    expect(find.byKey(const ValueKey('handover-BBBB')), findsOneWidget);
    // Claim-only: cards show no room menu; busy shows spinners, not buttons.
    expect(find.byKey(const ValueKey('cloud-menu-AAAA')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    await tester.pumpWidget(host(CloudHandoverSection(
      rooms: [room('AAAA')],
      onClaim: (room) => claimed = room.code,
    )));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cloud-claim-AAAA')));
    expect(claimed, 'AAAA');
  });

  testWidgets('the error line shows under the header even with no rooms',
      (tester) async {
    await tester.pumpWidget(host(CloudHandoverSection(
      rooms: const [],
      onClaim: (_) {},
      error: 'Could not check pending handovers: server unreachable',
    )));
    await tester.pump();

    expect(find.text('PENDING HOST HANDOVERS'), findsOneWidget);
    expect(find.textContaining('server unreachable'), findsOneWidget);
  });

  testWidgets('quiet when nothing is pending and nothing failed',
      (tester) async {
    await tester.pumpWidget(host(CloudHandoverSection(
      rooms: const [],
      onClaim: (_) {},
    )));
    await tester.pump();

    expect(find.text('PENDING HOST HANDOVERS'), findsNothing);
    expect(find.byType(CloudRoomCard), findsNothing);
  });
}
