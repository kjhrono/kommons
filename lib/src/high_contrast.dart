import 'package:flutter/material.dart';

/// The high-contrast presentation of a built theme.
///
/// Low-vision players need more than a darker background: contrast mode
/// doubles every structural edge the shell draws — card and dialog outlines,
/// button borders, field outlines, dividers — and pushes the palette to
/// Material's maximum contrast level, so a control is told apart by its
/// shape and its ink, not by a subtle tint. The host's hue survives (the
/// scheme is rebuilt from its own `primary` seed), so a game still looks like
/// itself; only the contrast changes.
///
/// Applied by `ShellApp` whenever `appContrast` is on, over whatever
/// `themeBuilder` returned for the current brightness. Hosts therefore never
/// branch on the setting themselves — anything built from `Theme.of(context)`
/// follows automatically.
ThemeData highContrastTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: base.colorScheme.primary,
    brightness: base.brightness,
    contrastLevel: 1.0,
  ).copyWith(
    // Pure surfaces and ink: the strongest pairing a screen can show, and the
    // one that survives a dimmed or glare-washed display.
    surface: dark ? Colors.black : Colors.white,
    onSurface: dark ? Colors.white : Colors.black,
    // Secondary ink used to be a quiet grey; at this level it must still read
    // as text, so it keeps most of the primary contrast.
    onSurfaceVariant: dark ? const Color(0xFFEDEDED) : const Color(0xFF1C1C1C),
    outline: dark ? Colors.white : Colors.black,
    outlineVariant: dark ? const Color(0xFFB5B5B5) : const Color(0xFF4A4A4A),
  );

  final ink = scheme.onSurface;
  BorderSide edge() => BorderSide(color: scheme.outline, width: 2);
  final thickInk = BorderSide(color: ink, width: 2);

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? Colors.black : Colors.white,
    canvasColor: scheme.surface,
    cardColor: scheme.surface,
    dividerColor: scheme.outline,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    primaryTextTheme:
        base.primaryTextTheme.apply(bodyColor: ink, displayColor: ink),
    iconTheme: base.iconTheme.copyWith(color: ink),
    // Structure, not tint: every divider is a visible 2dp rule.
    dividerTheme:
        DividerThemeData(color: scheme.outline, thickness: 2, space: 2),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: edge()),
    ),
    cardTheme: base.cardTheme.copyWith(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
          side: edge(), borderRadius: BorderRadius.circular(12)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: thickInk,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20))),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      border: OutlineInputBorder(borderSide: edge()),
      enabledBorder: OutlineInputBorder(borderSide: edge()),
      focusedBorder: OutlineInputBorder(borderSide: thickInk),
      disabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: scheme.outlineVariant, width: 2)),
    ),
    // Chips are a bordered control here, not a tinted pill.
    chipTheme: base.chipTheme.copyWith(
      side: edge(),
      labelStyle: base.chipTheme.labelStyle
          ?.copyWith(color: ink, fontWeight: FontWeight.w600),
      secondaryLabelStyle:
          base.chipTheme.secondaryLabelStyle?.copyWith(color: ink),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      textColor: ink,
      iconColor: ink,
      subtitleTextStyle:
          base.listTileTheme.subtitleTextStyle?.copyWith(color: ink),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
          side: edge(), borderRadius: BorderRadius.circular(28)),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: dark ? Colors.white : Colors.black,
      contentTextStyle: TextStyle(
          color: dark ? Colors.black : Colors.white,
          fontWeight: FontWeight.w600),
    ),
  );
}
