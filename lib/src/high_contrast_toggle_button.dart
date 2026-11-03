import 'package:flutter/material.dart';

import 'app_settings.dart';

/// The high-contrast toggle: one tap flips [appContrast], which the shell's
/// root listens to so the whole app repaints with [highContrastTheme] and the
/// setup rail starts drawing its shape cues.
///
/// The two states differ by more than colour: the glyph switches between the
/// solid and outlined contrast mark (and Material's selected state rings it),
/// so the control still reads to a player who cannot tell the tints apart.
class HighContrastToggleButton extends StatelessWidget {
  const HighContrastToggleButton({super.key, this.tooltip});

  /// Optional tooltip override. Defaults to the localized string.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appContrast,
      builder: (context, _) {
        final on = appContrast.enabled;
        final label = tooltip ?? appLocale.strings.highContrastTooltip;
        return IconButton(
          key: const ValueKey('contrast-toggle'),
          tooltip: label,
          isSelected: on,
          icon: Semantics(
            label: label,
            child:
                Icon(on ? Icons.contrast : Icons.contrast_outlined, size: 20),
          ),
          onPressed: appContrast.toggle,
        );
      },
    );
  }
}
