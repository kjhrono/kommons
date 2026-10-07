import 'package:flutter/material.dart';

import 'app_settings.dart';

/// A standalone theme mode toggle that cycles through
/// [ThemeMode.light] → [ThemeMode.dark] → [ThemeMode.system] → [ThemeMode.light],
/// so users can follow the OS theme. The same widget is used in both the
/// top-bar header (`AppTopBar` / `AppTopBarActions`) and the settings screen
/// (`SettingsScreen`), so a future redesign of the toggle only touches this file.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key, this.tooltip});

  /// Optional tooltip override. Defaults to the localized string.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appTheme,
      builder: (context, _) {
        final mode = appTheme.mode;

        return IconButton(
          key: const ValueKey('theme-toggle'),
          tooltip: tooltip ?? appLocale.strings.switchThemeTooltip,
          icon: Semantics(
            label: tooltip ?? appLocale.strings.switchThemeTooltip,
            child: Icon(
              switch (mode) {
                ThemeMode.light  => Icons.dark_mode_outlined,
                ThemeMode.dark   => Icons.brightness_auto_outlined,
                ThemeMode.system => Icons.light_mode_outlined,
              },
              size: 20,
            ),
          ),
          onPressed: () => appTheme.mode = appTheme.nextMode,
        );
      },
    );
  }
}
