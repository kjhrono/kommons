import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';

/// A brief ring around whatever a shortcut jumped to.
///
/// The setup rail's value taps already scroll a host's control into view and
/// hand it focus (`LobbyWizard.onRevealControl`). A focus *ring*, though, only
/// appears where the platform reports keyboard highlighting: on a phone or
/// tablet ([FocusHighlightMode.touch]) the screen simply jumps and the player
/// has to guess where they landed. This paints a ring of its own, for a moment,
/// so the destination is obvious on every input device.
///
/// The ring is a foreground painter, so it never changes the child's
/// constraints, size or position: a scroll offset, a card's metrics and a text
/// field's caret all stay exactly where they were. [play] is imperative because
/// only the host knows when the jump finished.
class RevealHighlight extends StatefulWidget {
  const RevealHighlight({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.duration = const Duration(milliseconds: 1200),
    super.key,
  });

  final Widget child;

  /// Follows the control's own corners: a card's 12, a field's 4, half the
  /// height of a round button.
  final BorderRadius borderRadius;

  /// How long the ring runs, fade in and fade out included. With reduced
  /// motion the flash is replaced by a still highlight held for
  /// [RevealHighlightState.stillHold] — or this duration when it is shorter.
  final Duration duration;

  /// The ring's colour in [context]'s theme.
  ///
  /// Exposed so hosts and tests can name the rule instead of guessing it: the
  /// scheme's `tertiary` reads as "the control you asked for" (deliberately not
  /// `primary`, which marks the current step), while high-contrast mode uses
  /// `onSurface`, because there the ring is structure, not a tint. Same rule as
  /// the setup rail's focus ring.
  static Color ringColorOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return appContrast.enabled ? scheme.onSurface : scheme.tertiary;
  }

  @override
  State<RevealHighlight> createState() => RevealHighlightState();
}

/// The live state of a [RevealHighlight], reachable through its `GlobalKey`.
class RevealHighlightState extends State<RevealHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration);

  /// How long the reduced-motion highlight stays up: a short, still ring —
  /// long enough to find the control, short enough that it does not linger the
  /// way the flash it replaces does. A host's shorter [RevealHighlight.duration]
  /// wins, so a control that asked for a quicker ring is not made slower.
  static const Duration stillHold = Duration(milliseconds: 400);

  /// True while the reduced-motion highlight is up. It is a plain flag and a
  /// timer rather than an animation, so nothing repaints between the start and
  /// the end: reduced motion gets a static highlight, not a slower flash.
  bool _still = false;
  Timer? _stillTimer;

  /// Starts the ring, or restarts it. Called by the host once it has scrolled
  /// the control into view; safe to call at any time.
  ///
  /// With reduced motion the flash is swapped for [stillHold] of a still ring
  /// at full strength: no fade in, no drifting fade out, and no frames painted
  /// in between.
  void play() {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      // A flash already under way is cut here too: with motion off, the ring
      // must not keep fading underneath the still highlight (and reappear if
      // the setting flips back before the hold ends).
      if (_controller.isAnimating) {
        _controller.stop();
        _controller.value = 0;
      }
      _stillTimer?.cancel();
      if (!_still) setState(() => _still = true);
      final hold = widget.duration < stillHold ? widget.duration : stillHold;
      _stillTimer = Timer(hold, () {
        if (!mounted) return;
        setState(() => _still = false);
      });
      return;
    }
    _controller.forward(from: 0);
  }

  /// Whether the ring is on screen right now: true from [play] until the run
  /// (or the reduced-motion hold) finishes. Lets a host or a test tell
  /// "revealed and flashing" from "merely scrolled to".
  bool get isPlaying => _still || _controller.isAnimating;

  @override
  void dispose() {
    _stillTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// The ring's opacity at [t], with a quick fade in, a long hold and a slower
  /// fade out: the eye needs more time to travel than to notice.
  static double _fade(double t) {
    const inEnd = 0.12;
    const outStart = 0.65;
    if (t < inEnd) return (t / inEnd).clamp(0.0, 1.0);
    if (t <= outStart) return 1;
    return ((1 - t) / (1 - outStart)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // A live contrast flip has to reach a ring already on screen.
      listenable: appContrast,
      builder: (context, child) {
        final ink = RevealHighlight.ringColorOf(context);
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _controller.value;
            // The reduced-motion highlight is a flag, not a phase: it is on at
            // full strength and then simply clears (see [play]).
            final onScreen = _still || (t > 0 && t < 1);
            return CustomPaint(
              foregroundPainter: onScreen
                  ? _RevealRingPainter(
                      color: ink,
                      radius: widget.borderRadius,
                      opacity: _still ? 1 : _fade(t),
                    )
                  : null,
              child: child,
            );
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Paints the ring inside the control's own bounds.
///
/// Inset by half the stroke: a ring drawn outside the bounds would be clipped
/// by whatever list or card the control lives in, and by the scroll view it
/// jumps inside.
class _RevealRingPainter extends CustomPainter {
  const _RevealRingPainter(
      {required this.color, required this.radius, required this.opacity});

  final Color color;
  final BorderRadius radius;
  final double opacity;

  static const double _stroke = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    final rrect = radius.toRRect(rect);
    // A soft bloom under the line: a flat 2.5dp stroke can disappear over a
    // portrait or a tinted card, and the blur costs nothing.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke * 2
        ..color = color.withValues(alpha: 0.25 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = color.withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_RevealRingPainter old) =>
      old.color != color || old.radius != radius || old.opacity != opacity;
}
