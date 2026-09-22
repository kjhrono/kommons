import 'package:flutter/material.dart';

import '../app_settings.dart';
import 'cloud_room_card.dart';
import 'cloud_room_service.dart';

/// The whole pending-host-handover section as one reusable piece: the
/// PENDING HOST HANDOVERS header, the error line, and one [CloudRoomCard]
/// per room (configured claim-only — the section's whole purpose is the
/// one-tap crown acceptance).
///
/// The host app keeps the data flow: it loads the rooms addressed to its
/// device's seats ([rooms]), reports failures through [error], and wires
/// [onClaim] to its claim-and-enter flow. Renders nothing when there is
/// nothing pending and no error — a quiet no-server lobby stays clean.
class CloudHandoverSection extends StatelessWidget {
  const CloudHandoverSection({
    super.key,
    required this.rooms,
    required this.onClaim,
    this.error,
    this.claimBusy = false,
  });

  /// Rooms with a pending designation addressed to this device (the host
  /// app filters; the cards' own claim gate matches on designatedHost).
  final List<CloudRoom> rooms;

  /// Fired when a card's Claim host button is pressed.
  final ValueChanged<CloudRoom> onClaim;

  /// Listing failed this cycle — shown under the header instead of a
  /// crash or a silent gap.
  final String? error;

  /// A claim protocol is in flight: the pressed card's button yields to a
  /// spinner (see [CloudRoomCard.claimBusy]).
  final bool claimBusy;

  @override
  Widget build(BuildContext context) {
    if (rooms.isEmpty && error == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(appLocale.strings.pendingHandovers,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: Colors.amber.shade300)),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12)),
        for (final room in rooms)
          CloudRoomCard(
            key: ValueKey('handover-${room.code}'),
            room: room,
            localSeatName: room.designatedHost,
            onClaim: onClaim,
            claimBusy: claimBusy,
          ),
      ],
    );
  }
}
