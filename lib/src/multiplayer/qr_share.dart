import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// What happened when the player tried to share the invite QR image.
enum QrShareOutcome {
  /// The platform share sheet opened and the player acted on it (or backed
  /// out) — the sheet itself was the feedback, nothing more to show.
  shared,

  /// The share sheet was dismissed without a choice; the user decided
  /// against it, so the shell stays quiet (it does not touch the
  /// clipboard behind their back).
  dismissed,

  /// No share handler exists on this platform (or the image could not be
  /// rendered) — the caller should fall back to copying the invite link.
  fallback,
}

/// Renders the QR for [data] and opens the platform share sheet with it as
/// an image ([inviteLink] rides along as text), letting a phone host push
/// the code straight into a chat app or email.
typedef QrShareExecutor = Future<QrShareOutcome> Function({
  required String data,
  required String inviteLink,
});

/// The executor the lobby's share button runs — [shareInviteQrImage] by
/// default. Injectable for tests (and for hosts with their own share
/// delivery); reassign and restore in teardown.
QrShareExecutor qrShareExecutor = shareInviteQrImage;

/// The default [QrShareExecutor]: `share_plus`'s default instance handles
/// every platform route the plugin supports (Android/iOS sheets, macOS,
/// web's Navigator.share, desktop). Where no handler answers, the outcome
/// is [QrShareOutcome.fallback] and the caller copies the invite link
/// instead.
Future<QrShareOutcome> shareInviteQrImage({
  required String data,
  required String inviteLink,
}) async {
  final bytes = await renderInviteQrPng(data);
  if (bytes == null) return QrShareOutcome.fallback;
  try {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            bytes,
            name: 'join-qr.png',
            mimeType: 'image/png',
          ),
        ],
        text: inviteLink,
        title: inviteLink,
      ),
    );
    switch (result.status) {
      case ShareResultStatus.success:
        return QrShareOutcome.shared;
      case ShareResultStatus.dismissed:
        return QrShareOutcome.dismissed;
      case ShareResultStatus.unavailable:
        return QrShareOutcome.fallback;
    }
  } catch (_) {
    // No share handler on this platform (tests, constrained builds).
    return QrShareOutcome.fallback;
  }
}

/// Renders [data] as a QR code PNG with a white mat — black modules on
/// white survive dark-mode chat bubbles and stay scannable from any
/// preview. Null when the render failed (callers fall back to the text
/// link); never throws.
Future<Uint8List?> renderInviteQrPng(String data, {double size = 512}) async {
  try {
    final painter = QrPainter(
      data: data,
      version: QrVersions.auto,
      gapless: true,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size, size),
      Paint()..color = Colors.white,
    );
    painter.paint(canvas, Size.square(size));
    final image =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
