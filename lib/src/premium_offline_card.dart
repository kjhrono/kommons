import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'shell_entitlements.dart';
import 'shell_inks.dart';
import 'shell_strings.dart' show ShellLanguage;

/// The settings card for this app's premium: the plan, and which device
/// may use it offline, with the button that moves it here. Add it to
/// [SettingsScreen.extraSections] (or leadingSections).
class PremiumOfflineCard extends StatefulWidget {
  const PremiumOfflineCard({super.key, required this.entitlements});

  final ShellEntitlements entitlements;

  @override
  State<PremiumOfflineCard> createState() => _PremiumOfflineCardState();
}

class _PremiumOfflineCardState extends State<PremiumOfflineCard> {
  bool _busy = false;
  String? _message;

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.entitlements.activateOffline();
    if (!mounted) return;
    final s = premiumOfflineStrings;
    setState(() {
      _busy = false;
      _message = switch (result) {
        ShellActivateResult.activated => null,
        ShellActivateResult.moveLimit => s.moveLimit,
        ShellActivateResult.notEntitled => s.notEntitled,
        ShellActivateResult.suspended => s.suspended,
        ShellActivateResult.unsupported => s.unsupported,
        ShellActivateResult.offline => s.offline,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.entitlements,
      builder: (context, _) {
        final s = premiumOfflineStrings;
        final e = widget.entitlements;
        final offline = e.offline;
        final unlocked = e.entitlement.unlocksAnything;
        final String line;
        if (!offline.supported) {
          line = s.unsupported;
        } else if (offline.clockTampered) {
          line = s.clockTampered;
        } else if (offline.heldHere) {
          line = s.heldHere(MaterialLocalizations.of(context)
              .formatMediumDate(offline.expiresAt!));
        } else if (offline.holderLabel != null) {
          line = s.heldElsewhere(offline.holderLabel!);
        } else {
          line = s.notSet;
        }
        final canMove = offline.supported &&
            !offline.heldHere &&
            e.source == ShellEntitlementSource.online;
        return Card(
          key: const ValueKey('premium-offline-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.workspace_premium_outlined),
                  const SizedBox(width: 8),
                  Text(unlocked ? s.premium : s.free,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ]),
                if (unlocked) ...[
                  const SizedBox(height: 8),
                  Text(line,
                      key: const ValueKey('premium-offline-line'),
                      style: TextStyle(color: scheme.mutedInk)),
                  if (canMove) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('premium-offline-activate'),
                      onPressed: _busy ? null : _activate,
                      icon: const Icon(Icons.offline_pin_outlined),
                      label: Text(s.useHere),
                    ),
                    if (offline.movesLeft != null &&
                        offline.holderLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(s.movesLeft(offline.movesLeft!),
                          style:
                              TextStyle(fontSize: 12, color: scheme.mutedInk)),
                    ],
                  ],
                ],
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(_message!,
                      key: const ValueKey('premium-offline-message'),
                      style: TextStyle(color: scheme.warningInk)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class PremiumOfflineStrings {
  const PremiumOfflineStrings.english()
      : premium = 'PREMIUM',
        free = 'FREE',
        notSet = 'Premium works on every device while online. '
            'No device uses it offline yet.',
        unsupported = 'Premium works on this device while online. '
            'Offline use needs the Android or iOS app.',
        clockTampered =
            'The device clock went backwards. Connect once to use premium offline again.',
        useHere = 'Use premium offline on this device',
        moveLimit =
            'You moved offline premium too often this month. Try again later.',
        notEntitled = 'This account has no premium for this app.',
        suspended = 'Premium for this app is suspended on this account.',
        offline = 'Connect to the internet to do this.',
        _heldHere =
            'Offline on this device, renewed automatically. Next check by',
        _heldElsewhere = 'Offline premium is on',
        _movesLeft = 'moves left this month';

  const PremiumOfflineStrings.italian()
      : premium = 'PREMIUM',
        free = 'FREE',
        notSet = 'Premium funziona su ogni dispositivo quando sei online. '
            'Nessun dispositivo lo usa ancora offline.',
        unsupported =
            'Premium funziona su questo dispositivo quando sei online. '
                'L’uso offline richiede l’app Android o iOS.',
        clockTampered =
            'L’orologio del dispositivo è tornato indietro. Collegati una volta per usare di nuovo premium offline.',
        useHere = 'Usa premium offline su questo dispositivo',
        moveLimit =
            'Hai spostato premium offline troppe volte questo mese. Riprova più avanti.',
        notEntitled = 'Questo account non ha premium per questa app.',
        suspended = 'Premium per questa app è sospeso su questo account.',
        offline = 'Collegati a internet per farlo.',
        _heldHere =
            'Offline su questo dispositivo, rinnovato in automatico. Prossimo controllo entro il',
        _heldElsewhere = 'Premium offline è su',
        _movesLeft = 'spostamenti rimasti questo mese';

  final String premium;
  final String free;
  final String notSet;
  final String unsupported;
  final String clockTampered;
  final String useHere;
  final String moveLimit;
  final String notEntitled;
  final String suspended;
  final String offline;
  final String _heldHere;
  final String _heldElsewhere;
  final String _movesLeft;

  String heldHere(String date) => '$_heldHere $date.';
  String heldElsewhere(String device) => '$_heldElsewhere “$device”.';
  String movesLeft(int n) => '$n $_movesLeft';
}

const _english = PremiumOfflineStrings.english();
const _italian = PremiumOfflineStrings.italian();

PremiumOfflineStrings get premiumOfflineStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
