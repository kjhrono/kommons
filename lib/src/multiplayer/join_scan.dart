import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'join_link.dart';

/// What a scan attempt ended as: [joined] carries the invite code, the
/// other two are the player's or the hardware's "no".
enum JoinScanOutcome {
  /// A code was read and accepted — [code] is the invite to sit at.
  joined,

  /// The player closed the scanner without a result.
  dismissed,

  /// No usable result: the camera is unavailable, or what was read is not
  /// an invite code.
  failed,
}

/// The result of one scan attempt.
class JoinScanResult {
  const JoinScanResult.joined(this.code)
      : outcome = JoinScanOutcome.joined,
        assert(code != '');

  const JoinScanResult.dismissed()
      : code = '',
        outcome = JoinScanOutcome.dismissed;

  const JoinScanResult.failed()
      : code = '',
        outcome = JoinScanOutcome.failed;

  /// The scanned invite code, non-empty only when [outcome] is
  /// [JoinScanOutcome.joined].
  final String code;
  final JoinScanOutcome outcome;
}

/// The swappable scanner seam: tests and hosts stub it like
/// [qrShareExecutor] before it — no camera needed to exercise the flow.
typedef JoinScanExecutor = Future<JoinScanResult> Function({
  required BuildContext context,
  required String scanLabel,
});

/// The default executor: opens the platform scanner dialog and parses what
/// the camera reads. On the web it fails up front — the camera story there
/// is the platform's, and the lobby hides the scan button instead.
Future<JoinScanResult> scanJoinCodeWithCamera({
  required BuildContext context,
  required String scanLabel,
}) async {
  if (kIsWeb) return const JoinScanResult.failed();
  final code = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _JoinScanDialog(scanLabel: scanLabel),
  );
  if (code == null) return const JoinScanResult.dismissed();
  if (code.isEmpty) return const JoinScanResult.failed();
  return JoinScanResult.joined(code);
}

/// The seam the lobby calls — stub it in tests to simulate scans.
JoinScanExecutor joinScanExecutor = scanJoinCodeWithCamera;

/// Parses scanned text into an invite, accepting both shapes a friend can
/// put in front of a camera:
///
///  * a full invite link — the QR the shell draws (`…#join=K7QX2`), or a
///    `?join=` query form from a shortener — parsed by the same codec the
///    clipboard paste uses;
///  * a bare code (`K7QX2`) — a QR someone made by hand.
///
/// Anything else (a web page, a Wi-Fi card, a product) parses to null so
/// the scanner keeps looking instead of committing a stranger's payload.
JoinInvite? joinCodeFromScannedText(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final asLink = joinInviteFromClipboardText(trimmed);
  if (asLink != null) return asLink;
  final bareCode = RegExp(r'^[A-Z0-9]{4,10}$');
  if (bareCode.hasMatch(trimmed)) return JoinInvite(code: trimmed);
  return null;
}

/// The camera dialog: a live preview that closes itself the moment a
/// barcode carrying an invite lands in view, or on the player's cancel.
class _JoinScanDialog extends StatefulWidget {
  const _JoinScanDialog({required this.scanLabel});

  final String scanLabel;

  @override
  State<_JoinScanDialog> createState() => _JoinScanDialogState();
}

class _JoinScanDialogState extends State<_JoinScanDialog> {
  bool _handled = false;

  /// Single-shot close: the scanner can deliver several barcodes across
  /// frames before the pop lands — only the first answer counts.
  void _close(String code) {
    if (_handled || !mounted) return;
    _handled = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.scanLabel,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  key: const ValueKey('join-scan-cancel'),
                  onPressed: () => _close(''),
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
              ],
            ),
          ),
          Flexible(
            child: SizedBox(
              width: 280,
              height: 280,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MobileScanner(
                  key: const ValueKey('join-scan-camera'),
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      final invite = joinCodeFromScannedText(barcode.rawValue);
                      if (invite != null) {
                        _close(invite.code);
                        return;
                      }
                    }
                  },
                  errorBuilder: (context, error) => _ScanError(
                    message: error.errorCode.name,
                    onCancel: () => _close(''),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// The in-dialog failure view: the camera is unavailable (permission, no
/// camera, plugin trouble) — say so and let the player back out.
class _ScanError extends StatelessWidget {
  const _ScanError({required this.message, required this.onCancel});

  final String message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final strings = Theme.of(context);
    return Container(
      color: strings.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_outlined, size: 40),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center, style: strings.textTheme.bodySmall),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onCancel, child: const Icon(Icons.close)),
        ],
      ),
    );
  }
}
