import 'package:flutter/material.dart';

/// Names for the inks the shell draws that a [ColorScheme] has no direct slot
/// for, so no screen has to reach for a literal `Colors.grey` again.
///
/// This exists because of high-contrast mode: that theme rebuilds surfaces and
/// inks at maximum contrast, but a hardcoded `Colors.grey.shade500` stays at
/// exactly the contrast it had — so the one place a low-vision player most
/// needs to read (a helper line, a seat that is not ready) is the one place the
/// mode cannot reach. Anything routed through these getters follows the theme
/// automatically, in both brightnesses and in contrast mode.
///
/// Use `Theme.of(context).colorScheme.mutedInk` rather than importing a colour.
extension ShellInk on ColorScheme {
  /// Secondary text: captions, helper lines, quiet values, unready seats.
  Color get mutedInk => onSurfaceVariant;

  /// Attention that is not a failure: a pending handover, a locked step, an
  /// inbox waiting on a code. Maps to the scheme's accent so contrast mode
  /// strengthens it instead of leaving a pale amber on a white card.
  Color get warningInk => tertiary;

  /// A confirmed or ready state. The scheme's own accent, not a literal green:
  /// the host's palette survives into the status ink, and contrast mode keeps
  /// it legible.
  Color get readyInk => primary;

  /// Failure and danger text (a suspended account, a rejected request).
  Color get dangerInk => error;

  /// Ink that has to sit on a colour the player picked — a banner swatch, the
  /// colour preview — where no theme role can know the background. Both
  /// candidates are measured against that colour and the stronger one wins, so
  /// a pale banner gets dark ink, a dark one gets white, and a mid-tone green
  /// gets whichever of the two actually reads on it.
  Color inkOn(Color background) {
    const pale = Color(0xFFFFFFFF);
    // Near-black rather than pure black: same legibility, less of a hole
    // punched in the swatch.
    const dark = Color(0xFF1B1B1B);
    return _contrastRatio(dark, background) >= _contrastRatio(pale, background)
        ? dark
        : pale;
  }

  static double _contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}
