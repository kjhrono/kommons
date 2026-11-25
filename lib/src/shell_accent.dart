import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'shell_inks.dart';
import 'shell_preferences.dart';
import 'shell_strings.dart' show ShellLanguage;

// -----------------------------------------------------------------------------
// Colour themes: the player picks an accent from a few presets (or keeps the
// app's own colour). ShellApp seeds the Material 3 scheme from it, so dark
// mode and high contrast keep working. The choice syncs across projects like
// the language (`kommons.accent`).
//
// Presets, not a free colour wheel: a random colour often gives poor contrast.
// -----------------------------------------------------------------------------

/// One accent preset. [id] is synced data: never rename one.
@immutable
class ShellAccent {
  const ShellAccent(this.id, this.color, this.englishName, this.italianName);

  final String id;
  final Color color;
  final String englishName;
  final String italianName;

  String get name =>
      appLocale.value == ShellLanguage.italiano ? italianName : englishName;

  /// The presets, in picker order. Append only.
  static const all = <ShellAccent>[
    ShellAccent('ocean', Color(0xff1e6fd9), 'Ocean', 'Oceano'),
    ShellAccent('teal', Color(0xff00796b), 'Teal', 'Verde acqua'),
    ShellAccent('forest', Color(0xff2e7d32), 'Forest', 'Foresta'),
    ShellAccent('gold', Color(0xffb8860b), 'Gold', 'Oro'),
    ShellAccent('sunset', Color(0xffe65100), 'Sunset', 'Tramonto'),
    ShellAccent('berry', Color(0xffad1457), 'Berry', 'Frutti di bosco'),
    ShellAccent('violet', Color(0xff6a1b9a), 'Violet', 'Viola'),
    ShellAccent('slate', Color(0xff455a64), 'Slate', 'Ardesia'),
  ];

  static ShellAccent? byId(String? id) {
    for (final accent in all) {
      if (accent.id == id) return accent;
    }
    return null;
  }
}

/// The player's accent; null keeps the app's own colour.
class AppAccentNotifier extends ValueNotifier<ShellAccent?> {
  AppAccentNotifier() : super(null);

  static const _prefKey = 'prefs.app.accent';

  /// Whether the app lets the player change the colour (ShellApp's
  /// `allowAccent`). The settings picker hides when false.
  bool available = true;

  /// The app's own colour (ShellApp.seedColor), the picker's first swatch.
  Color? appColor;

  /// The seed for the theme: the chosen accent, else [appDefault].
  Color seedOr(Color appDefault) => value?.color ?? appDefault;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = ShellAccent.byId(prefs.getString(_prefKey));
  }

  /// Picks an accent (null: back to the app's colour), persists and syncs.
  Future<void> setAccent(ShellAccent? accent) async {
    value = accent;
    final prefs = await SharedPreferences.getInstance();
    final token = accent?.id ?? 'app';
    await prefs.setString(_prefKey, token);
    unawaited(account.preferenceEdited(ShellPrefKey.accent, token));
  }

  /// Applies a synced accent without pushing it back.
  Future<void> applySynced(String token) async {
    value = ShellAccent.byId(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, token);
  }

  /// The synced token: an id, or 'app' for the app's own colour. Null when
  /// the player never chose.
  Future<String?> storedToken() async =>
      (await SharedPreferences.getInstance()).getString(_prefKey);

  @visibleForTesting
  void resetForTest() {
    value = null;
    available = true;
    appColor = null;
  }
}

/// The app-wide accent notifier. ShellApp listens to it.
final appAccent = AppAccentNotifier();

/// The settings row of colour swatches: the app's own colour first, then
/// the presets.
class AccentPicker extends StatelessWidget {
  const AccentPicker({super.key, this.appColor});

  /// The app's own colour, the first choice. Defaults to ShellApp's
  /// seedColor (or the theme's primary outside ShellApp).
  final Color? appColor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appAccent, appLocale]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final s = appLocale.value == ShellLanguage.italiano
            ? (title: 'Colore', appDefault: 'Colore dell’app')
            : (title: 'Colour', appDefault: 'App colour');
        Widget swatch(String key, Color color, String label, bool selected,
                VoidCallback onTap) =>
            Semantics(
              button: true,
              selected: selected,
              label: label,
              excludeSemantics: true,
              child: Tooltip(
                message: label,
                child: InkWell(
                  key: ValueKey('accent-$key'),
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                          width: 3,
                          color:
                              selected ? scheme.onSurface : Colors.transparent),
                    ),
                    child: selected
                        ? Icon(Icons.check,
                            color: scheme.inkOn(color), size: 18)
                        : null,
                  ),
                ),
              ),
            );
        return Card(
          key: const ValueKey('accent-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.palette_outlined),
                  const SizedBox(width: 8),
                  Text(s.title, style: Theme.of(context).textTheme.titleSmall),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  swatch(
                      'app',
                      appColor ?? appAccent.appColor ?? scheme.primary,
                      s.appDefault,
                      appAccent.value == null,
                      () => appAccent.setAccent(null)),
                  for (final accent in ShellAccent.all)
                    swatch(
                        accent.id,
                        accent.color,
                        accent.name,
                        appAccent.value == accent,
                        () => appAccent.setAccent(accent)),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}
