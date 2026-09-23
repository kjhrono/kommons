import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../app_settings.dart' show account, appLocale;
import 'banner_color_picker.dart';
import 'join_link.dart';
import 'lobby_seat.dart';
import 'qr_share.dart' as qr_share;

/// Everything the host app needs to take over: this device's seat, the rest
/// of the table, the shared room code ([GameSyncService.roomCode] reads it
/// back), and whether the game starts online at all.
class SharedLobbyHandoff {
  const SharedLobbyHandoff({
    required this.self,
    required this.seats,
    required this.roomCode,
    required this.online,
  });

  /// The persona the local player will play as.
  final LobbySeat self;

  /// Every other seat at the table (never contains [self]); empty in solo.
  final List<LobbySeat> seats;

  /// The shared room's short code — null when [online] is false.
  final String? roomCode;

  /// False for solo/hot-seat games (no server in the loop).
  final bool online;
}

/// One entry of the roster editor: a [LobbySeat] chip plus its remove button.
class _SeatRow extends StatelessWidget {
  const _SeatRow({required this.seat, this.isSelf = false, this.onRemove});

  final LobbySeat seat;
  final bool isSelf;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
          child: Chip(
            key: ValueKey('shared-lobby-seat-${seat.name}'),
            avatar: CircleAvatar(
              backgroundColor: seat.color,
              child: Text(
                seat.name.isNotEmpty ? seat.name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            label: Text(seat.name),
          ),
        ),
        if (!isSelf && onRemove != null)
          IconButton(
            key: ValueKey('shared-lobby-remove-${seat.name}'),
            tooltip: strings.removeSeatTooltip,
            onPressed: onRemove,
            icon: const Icon(Icons.person_remove_outlined),
          ),
        if (isSelf)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(strings.youMarker,
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ]),
    );
  }
}

/// The shared, app-agnostic first screen of a hosted multiplayer game: a
/// seat for the local player, extra seats joined by entering the host's
/// game number, or an explicitly solo start. Exactly one callback —
/// [onHandoff] — carries everything the game needs into its NEW-GAME
/// section, where the shell's responsibility ends.
///
/// The roster lives in the widget's own state: add a seat, it appears under
/// the local player; remove it and the game number unlocks for the next
/// join. The widget deliberately knows nothing about the game itself —
/// colors come from the shared [nextFreeBannerColorHex] picker so the seats'
/// banners stay distinct.
class SharedLobbyStep extends StatefulWidget {
  const SharedLobbyStep({
    super.key,
    required this.onHandoff,
    this.initialCode,
    this.inviteBaseUrl,
  });

  /// Fired exactly once, when the player starts the game (solo, hot-seat,
  /// or online). The game's NEW-GAME section receives the handoff and
  /// creates its world.
  final ValueChanged<SharedLobbyHandoff> onHandoff;

  /// A game number handed to the lobby before it opened — from a parsed
  /// invite link ([joinInviteFromUri], see [ShellApp]'s link delivery or a
  /// pasted link). Non-empty commits the number immediately, locking it
  /// like any join: an invited player never types the code by hand.
  final String? initialCode;

  /// The page the invite link — and the QR code beside it — builds on, for
  /// hosts on platforms without a natural base URL (mobile builds: the
  /// game's landing page so a scan opens somewhere meaningful). Null (the
  /// default) means the link builds on `Uri.base` on web and the QR stays
  /// hidden where no base exists — a fragment-only invite is nothing to
  /// scan.
  final Uri? inviteBaseUrl;

  @override
  State<SharedLobbyStep> createState() => _SharedLobbyStepState();
}

class _SharedLobbyStepState extends State<SharedLobbyStep> {
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  final _guests = <LobbySeat>[];
  String? _codeError;
  bool _joining = false;

  /// The game number the seats joined with. Kept in state (not the field,
  /// which clears after a join) so the handoff still carries the code.
  String? _joinedCode;

  /// True once a number is committed — by a join, a received invite, or
  /// the initial link: the field locks, the invite section appears, and
  /// the code joins the handoff. Removing every seat releases it.
  bool _codeLocked = false;

  /// True when the committed number arrived from an invite (initial link
  /// or paste) rather than a hand-typed join: the invited player keeps
  /// adding friends' seats to the same table without re-entering it.
  bool _inviteOnly = false;

  @override
  void initState() {
    super.initState();
    // An invite arrived with the navigation (deep link / parsed link):
    // the code is committed before the first frame, so the invited
    // player lands on a locked lobby — seats, invite, start.
    final initial = widget.initialCode?.trim();
    if (initial != null && initial.isNotEmpty) {
      _joinedCode = initial;
      _codeLocked = true;
      _inviteOnly = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appLocale.strings.inviteJoinedAs(account.playerName)),
        ));
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// The base a shared invite builds on: the page itself on web (the
  /// copied link opens the same app elsewhere), a fragment-only string
  /// on other platforms — the game's own landing URL is the host's to
  /// know, and `#join=…` pastes onto it cleanly.
  Uri? get _linkBase => kIsWeb ? Uri.base : null;

  /// The invite string for the committed code, as the host shares it.
  String get _inviteLink =>
      JoinInvite(code: _joinedCode ?? '').link(base: _effectiveLinkBase);

  /// The URL the QR encodes — null when there is nothing worth scanning:
  /// no committed code, or no base to build a full URL on (a bare
  /// `#join=…` fragment is meaningless to a phone's camera). Web provides
  /// its own page; hosts on other platforms opt in via [SharedLobbyStep.inviteBaseUrl].
  Uri? get _qrUrl {
    final base = _effectiveLinkBase;
    final code = _joinedCode;
    if (base == null || code == null || code.isEmpty) return null;
    return Uri.tryParse(JoinInvite(code: code).link(base: base));
  }

  /// The host's explicit base wins; web falls back to the page itself.
  Uri? get _effectiveLinkBase => widget.inviteBaseUrl ?? _linkBase;

  /// Opens the platform share sheet with the QR rendered as an image (the
  /// invite link rides along as text) so a phone host can push the code
  /// straight into a chat app. Where no share handler exists, the invite
  /// link lands on the clipboard instead — same fallback as the email
  /// button.
  Future<void> _shareInviteQr() async {
    final code = _joinedCode ?? '';
    final outcome = await qr_share.qrShareExecutor(
      data: _inviteLink,
      inviteLink: _inviteLink,
    );
    if (!mounted) return;
    if (outcome == qr_share.QrShareOutcome.fallback) {
      await copyJoinLink(_inviteLink);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.inviteCopied)));
      }
      return;
    }
    if (outcome == qr_share.QrShareOutcome.shared) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appLocale.strings.inviteQrShared(code))));
    }
    // dismissed: the player backed out — nothing to say.
  }

  /// This device's seat: the persisted player's name (falling back to the
  /// localized default) carrying the next free banner color.
  LobbySeat get _self => LobbySeat(
        name: account.playerName,
        colorHex: nextFreeBannerColorHex(taken: const {}),
      );

  List<LobbySeat> get _everyone => [_self, ..._guests];

  Future<void> _addSeat() async {
    final strings = appLocale.strings;
    // An invited lobby commits its code up front: extra seats join the
    // same table without re-typing it. A hand-typed lobby reads the field.
    final code = _joinedCode ?? _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _codeError = strings.gameNumberMissing);
      _codeFocus.requestFocus();
      return;
    }
    setState(() {
      _codeError = null;
      _joining = true;
    });
    final taken = _everyone.map((s) => s.colorHex).toSet();
    final guest = LobbySeat(
      name: '${strings.guest} ${_guests.length + 2}',
      colorHex: nextFreeBannerColorHex(taken: taken),
    );
    // The join keeps its own focus on the form: either the seat is added
    // and the number locks (the game's actual invite flow talks to the
    // server when the game starts), or the error explains what to fix.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() {
      _joining = false;
      _joinedCode = code;
      _codeLocked = true;
      _guests.add(guest);
      _codeController.clear();
    });
  }

  void _removeSeat(LobbySeat seat) {
    setState(() {
      _guests.remove(seat);
      if (_guests.isEmpty) {
        // The last seat gone: the committed number is nobody's join any
        // more — release it (field unlocks, invite section goes).
        _codeLocked = false;
        _inviteOnly = false;
        _joinedCode = null;
      }
    });
  }

  /// Reads a received invite off the clipboard and, after a confirm, sits
  /// the player at that table: the code commits and locks exactly like a
  /// hand-typed join.
  Future<void> _pasteInvite() async {
    final strings = appLocale.strings;
    final text = await readJoinLinkClipboard();
    final invite = joinInviteFromClipboardText(text);
    if (!mounted) return;
    if (invite == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(strings.inviteNothingToPaste)));
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.inviteHeader),
        content: Text(strings.invitePastedJoinAs(account.playerName)),
        actions: [
          TextButton(
            key: const ValueKey('shared-lobby-invite-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('shared-lobby-invite-accept'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.confirm),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      _joinedCode = invite.code;
      _codeLocked = true;
      _inviteOnly = true;
      _codeError = null;
    });
  }

  Future<void> _copyInviteLink() async {
    await copyJoinLink(_inviteLink);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(appLocale.strings.inviteCopied)));
    }
  }

  /// Opens the mail client with the invite pre-filled (the player picks
  /// the recipients — the shell never sees an address book). Where no
  /// mail handler exists, the link lands on the clipboard instead.
  Future<void> _emailInviteLink() async {
    final body = Uri(
      scheme: 'mailto',
      queryParameters: {
        'subject':
            '${appLocale.strings.inviteLinkLabel} · ${_joinedCode ?? ''}',
        'body': _inviteLink,
      },
    );
    try {
      await launcher.launchUrl(body);
    } catch (_) {
      await copyJoinLink(_inviteLink);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.inviteCopied)));
      }
    }
  }

  void _startSolo() => widget.onHandoff(SharedLobbyHandoff(
        self: _self,
        seats: const [],
        roomCode: null,
        online: false,
      ));

  void _startOnline() {
    if (_guests.isEmpty || !_codeLocked) return;
    widget.onHandoff(SharedLobbyHandoff(
      self: _self,
      seats: List.unmodifiable(_guests),
      roomCode: _joinedCode,
      online: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    // Scrollable: the step grows with every seat, the invite link, and
    // the QR — small viewports must reach the start buttons.
    return SingleChildScrollView(
      child: Column(
        key: const ValueKey('shared-lobby-step'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(strings.seatsHeader,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _SeatRow(seat: _self, isSelf: true),
          for (final guest in _guests)
            _SeatRow(seat: guest, onRemove: () => _removeSeat(guest)),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('shared-lobby-game-number'),
            controller: _codeController,
            focusNode: _codeFocus,
            enabled: _guests.isEmpty && !_joining && !_codeLocked,
            decoration: InputDecoration(
              labelText: strings.gameNumberLabel,
              hintText: strings.gameNumberHint,
              errorText: _codeError,
              prefixIcon: const Icon(Icons.numbers),
            ),
            onSubmitted: (_) => _addSeat(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              key: const ValueKey('shared-lobby-add-seat'),
              onPressed: (!_joining && (_inviteOnly || _guests.isEmpty))
                  ? _addSeat
                  : null,
              icon: _joining
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.group_add),
              label: Text(strings.addSeat),
            ),
          ),
          if (_codeLocked) ...[
            const SizedBox(height: 20),
            Text(strings.inviteHeader,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('shared-lobby-invite-link'),
              controller: TextEditingController(text: _inviteLink),
              readOnly: true,
              decoration: InputDecoration(
                labelText: strings.inviteLinkLabel,
                hintText: strings.inviteLinkHint,
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('shared-lobby-invite-copy'),
                onPressed: _copyInviteLink,
                icon: const Icon(Icons.copy),
                label: Text(strings.inviteCopy),
              ),
              OutlinedButton.icon(
                key: const ValueKey('shared-lobby-invite-email'),
                onPressed: _emailInviteLink,
                icon: const Icon(Icons.mail_outline),
                label: Text(strings.inviteSendEmail),
              ),
              OutlinedButton.icon(
                key: const ValueKey('shared-lobby-invite-share-qr'),
                onPressed: _shareInviteQr,
                icon: const Icon(Icons.ios_share),
                label: Text(strings.inviteShare),
              ),
            ]),
            if (_qrUrl != null) ...[
              const SizedBox(height: 12),
              Center(
                key: const ValueKey('shared-lobby-invite-qr'),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    // A white mat keeps the code scannable in dark mode (the
                    // shell's default): QR readers want a quiet zone, not the
                    // app's theme.
                    child: QrImageView(
                      data: _qrUrl!.toString(),
                      size: 148,
                      backgroundColor: Colors.white,
                      // Screen readers announce the invite itself.
                      semanticsLabel: _qrUrl!.toString(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(strings.inviteQrHint,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center),
                ]),
              ),
            ],
          ] else ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('shared-lobby-invite-paste'),
                onPressed: _pasteInvite,
                icon: const Icon(Icons.content_paste),
                label: Text(strings.invitePaste),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(strings.hotSeatNote,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('shared-lobby-start-online'),
            onPressed: _guests.isEmpty ? null : _startOnline,
            icon: const Icon(Icons.sensors),
            label: Text(strings.joinGame),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('shared-lobby-start-solo'),
            onPressed: _startSolo,
            icon: const Icon(Icons.person),
            label: Text(strings.soloStart),
          ),
        ],
      ),
    );
  }
}
