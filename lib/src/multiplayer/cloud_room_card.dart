import 'package:flutter/material.dart';

import 'banner_color_picker.dart';
import 'cloud_room_service.dart';
import 'game_sync.dart';
import 'lobby_seat.dart';

// The shared cloud-room surfaces: every kjhrono game lists its online rooms
// the same way — one card per room with banner-tinted seat chips, a flash
// wash when readiness changes, and the same host menu (hand over, cancel
// handover, delete, leave) driven by the same claim protocol.

/// The room card: banner-colored seat chips (the local seat first, ringed
/// and bold), an amber flash wash with a change note when readiness moved,
/// the clock/status line, and the room menu. All behavior arrives as
/// callbacks — the host app decides what open/handover/delete mean; the
/// card owns the layout and the widget keys tests pin.
class CloudRoomCard extends StatelessWidget {
  const CloudRoomCard({
    super.key,
    required this.room,
    required this.localSeatName,
    this.flash = false,
    this.flashMessage,
    this.onOpen,
    this.onDelete,
    this.onLeave,
    this.onHandover,
    this.onCancelHandover,
  });

  final CloudRoom room;

  /// This device's seat in the room, or null when the device has none.
  final String? localSeatName;

  /// A readiness change just landed: wash the card amber and show
  /// [flashMessage] ("Mara is ready") while it fades.
  final bool flash;
  final String? flashMessage;

  final void Function(CloudRoom room)? onOpen;
  final void Function(CloudRoom room)? onDelete;
  final void Function(CloudRoom room)? onLeave;
  final void Function(CloudRoom room)? onHandover;
  final void Function(CloudRoom room)? onCancelHandover;

  @override
  Widget build(BuildContext context) {
    final flashing = flash;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: Colors.transparent,
        end: flashing ? Colors.amber.withValues(alpha: 0.18) : Colors.transparent,
      ),
      duration: const Duration(milliseconds: 600),
      builder: (context, color, child) => Card(
        key: ValueKey('cloud-${room.code}'),
        color: color,
        child: child,
      ),
      child: ListTile(
        leading: Icon(room.isLocalHost ? Icons.dns_outlined : Icons.groups_outlined),
        title: Text('World ${room.code}${room.isLocalHost ? ' — hosted here' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final seat in seatsLocalFirst(room, localSeatName: localSeatName))
                cloudSeatChip(room.code, seat,
                    isLocal: seat.name == localSeatName, room: room),
            ],
          ),
          const SizedBox(height: 4),
          if (flashing && flashMessage?.isNotEmpty == true)
            Text(
              flashMessage!,
              key: ValueKey('flash-note-${room.code}'),
              style: TextStyle(color: Colors.amber.shade900, fontWeight: FontWeight.w600),
            ),
          const SizedBox(height: 4),
          Text([
            'clock ${room.clock}',
            if (room.hasPassword) 'password-protected',
            if (room.designatedHost.isNotEmpty) 'host handover to ${room.designatedHost} pending',
            if (!room.hasSnapshot) 'not started yet',
          ].join(' · ')),
        ]),
        trailing: PopupMenuButton<String>(
          key: ValueKey('cloud-menu-${room.code}'),
          tooltip: 'Room options',
          onSelected: (choice) {
            if (choice == 'delete') {
              onDelete?.call(room);
            } else if (choice == 'leave') {
              onLeave?.call(room);
            } else if (choice == 'handover') {
              onHandover?.call(room);
            } else if (choice == 'cancel-handover') {
              onCancelHandover?.call(room);
            }
          },
          itemBuilder: (context) => [
            if (room.isLocalHost && room.designatedHost.isNotEmpty && onCancelHandover != null)
              PopupMenuItem(
                key: ValueKey('cloud-cancel-handover-${room.code}'),
                value: 'cancel-handover',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.undo),
                  title: const Text('Cancel handover'),
                  subtitle: Text('Withdraw the pending promotion of ${room.designatedHost}',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
            if (room.isLocalHost && onHandover != null)
              PopupMenuItem(
                key: ValueKey('cloud-handover-${room.code}'),
                value: 'handover',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.how_to_reg_outlined),
                  title: const Text('Hand over host'),
                  subtitle: const Text('Promote a seat; the world continues',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            if (room.isLocalHost && onDelete != null)
              PopupMenuItem(
                key: ValueKey('cloud-delete-${room.code}'),
                value: 'delete',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_forever),
                  title: const Text('Delete room'),
                  subtitle: const Text('Ends the world for every seat',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            if (!room.isLocalHost && onLeave != null)
              PopupMenuItem(
                key: ValueKey('cloud-leave-${room.code}'),
                value: 'leave',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.exit_to_app),
                  title: const Text('Leave room'),
                  subtitle: const Text('Your seat leaves; the world continues',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
          ],
        ),
        onTap: () => onOpen?.call(room),
      ),
    );
  }
}

/// One seat chip: banner swatch, name, ready marker — plus the host crown
/// on the room's first seat so a roster mid-handover reads at a glance.
Widget cloudSeatChip(String roomCode, CloudSeat seat,
    {required bool isLocal, CloudRoom? room}) {
  final color = bannerColor(seat.colorHex);
  return Row(mainAxisSize: MainAxisSize.min, children: [
    Container(
      key: ValueKey('cloud-seat-$roomCode-${seat.name}'),
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
            color: isLocal ? Colors.white : Colors.black26,
            width: isLocal ? 2.5 : 1),
      ),
    ),
    const SizedBox(width: 4),
    Text(
      isLocal ? '${seat.name} (you)' : seat.name,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: isLocal ? FontWeight.w700 : FontWeight.w400,
        color: seat.ready ? null : Colors.grey.shade500,
      ),
    ),
    if (room != null && seat.name == room.hostName) ...[
      const SizedBox(width: 3),
      const Tooltip(
        message: 'Host of this room',
        child: Icon(Icons.workspace_premium, size: 13, color: Colors.amber),
      ),
    ],
    const SizedBox(width: 2),
    Tooltip(
      message:
          '${seat.name}${isLocal ? ' (you)' : ''} ${seat.ready ? 'is ready' : 'has not readied up yet'}',
      child: Icon(
        seat.ready ? Icons.check_circle : Icons.hourglass_empty,
        size: 13,
        color: seat.ready ? Colors.green.shade400 : Colors.grey.shade500,
      ),
    ),
  ]);
}

/// The room's seats with the local seat leading the row (null keeps the
/// server order).
List<CloudSeat> seatsLocalFirst(CloudRoom room, {String? localSeatName}) {
  if (localSeatName == null) return room.seats;
  return [
    ...room.seats.where((s) => s.name == localSeatName),
    ...room.seats.where((s) => s.name != localSeatName),
  ];
}

/// The handover seat picker: banner-dotted list of who may be promoted (the
/// local seat leads; it may be promoted too — the "host" is really the
/// device holding the secret). Returns the chosen seat name, or null.
Future<String?> showHandoverSeatPicker(BuildContext context, CloudRoom room,
    {String? localSeatName}) async {
  final candidates = seatsLocalFirst(room, localSeatName: localSeatName);
  if (candidates.isEmpty) return null;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Hand over world ${room.code}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
              'Choose the seat that becomes the host. The world keeps running; they claim host powers from their device.'),
          const SizedBox(height: 8),
          for (final seat in candidates)
            ListTile(
              key: ValueKey('handover-${room.code}-${seat.name}'),
              dense: true,
              leading: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                    color: bannerColor(seat.colorHex), shape: BoxShape.circle),
              ),
              title: Text(seat.name),
              onTap: () => Navigator.pop(context, seat.name),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    ),
  );
}

/// The delete confirmation: explicit, and reminds the host the removal is
/// universal. Returns true only after the "Delete for everyone" press.
Future<bool> confirmDeleteRoomDialog(BuildContext context, CloudRoom room) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete world ${room.code}?'),
      content: Text(
        'The room is removed for every seat — ${room.seats.map((s) => s.name).join(', ')}. '
        'Their devices keep nothing but their local saves. This cannot be undone.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it')),
        FilledButton.icon(
          key: const ValueKey('confirm-delete-room'),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete for everyone'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// The leave confirmation. [seatName] personalizes the warning; the world
/// keeps running for the seats that stay.
Future<bool> confirmLeaveRoomDialog(BuildContext context, CloudRoom room,
    {String? seatName}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Leave world ${room.code}?'),
      content: Text(
        seatName == null
            ? 'Your seat departs and the world keeps running for '
                '${room.seats.map((s) => s.name).join(', ')} — your local save stays on this device.'
            : 'Your seat ($seatName) is removed from the roster. The world keeps running for '
                '${room.seats.map((s) => s.name).where((n) => n != seatName).join(', ')}.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay')),
        FilledButton.icon(
          key: const ValueKey('confirm-leave-room'),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.exit_to_app),
          label: const Text('Leave'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// A host action failed — usually because the crown has landed elsewhere
/// (a promoted seat claimed, rotating the secret) and this device no longer
/// holds host powers. Returns true when the credentials were revoked: the
/// caller should forget the local host record so the card stops advertising
/// powers the server refuses. Server-unreachable errors return false — the
/// next attempt may still succeed.
bool hostCredentialsRevoked(Object error) {
  final message = error.toString();
  return message.contains('401') ||
      message.contains('403') ||
      message.contains('42501');
}

/// Outcome of [claimHostPowers] — why a promotion could not be claimed.
enum HostClaimStatus { success, worldNotStarted, promotionConsumed, rejoinFailed }

/// The host-claim protocol, shared by every surface that lists a pending
/// designation (saved-games cards, lobby handover lists): the promoted seat
/// claims the crown itself from its own device — the secret never travels —
/// the claim rotates the room's host secret to a fresh value stored exactly
/// like a created room's, and the seat re-announces under the promoted
/// identity with host rights from the start (createsRoom keeps the
/// existing room row).
///
/// Returns the live [GameSyncService] and the world's snapshot JSON on
/// success — the caller decodes the snapshot into its session, attaches the
/// sync, and enters the world as host (one server round-trip for both).
/// Any other status means nothing was mutated beyond the (already
/// recorded) secret on [HostClaimStatus.rejoinFailed], where a retry is
/// safe: the claim is consumed, the resume is a normal host resume.
Future<(HostClaimStatus, GameSyncService?, String?)> claimHostPowers(
  CloudRoomService service,
  CloudRoom room,
  String seatName,
) async {
  // The world must exist before a crown can be accepted over it.
  final snapshot = await service.snapshotOf(room);
  if (snapshot == null) return (HostClaimStatus.worldNotStarted, null, null);

  final promotedSecret =
      await service.claimHostPromotion(room, seatName: seatName);
  if (promotedSecret == null || promotedSecret.isEmpty) {
    return (HostClaimStatus.promotionConsumed, null, null);
  }
  await service.recordHostSecret(room.code, promotedSecret);
  try {
    final sync = service.hostResumeService(room, hostSecret: promotedSecret);
    final claimed = room.seat(seatName);
    await sync.announcePlayer(LobbySeat(
      name: claimed?.name ?? seatName,
      colorHex: claimed?.colorHex ?? '',
    ));
    return (HostClaimStatus.success, sync, snapshot);
  } catch (_) {
    return (HostClaimStatus.rejoinFailed, null, null);
  }
}
