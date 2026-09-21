import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_settings.dart';
import 'shell_strings.dart';

/// How [ShellApp] builds each brightness's theme from the host's seed.
typedef ShellThemeBuilder = ThemeData Function(
    BuildContext context, Brightness brightness);

/// The shell's root widget: one wrapper that owns the MaterialApp wiring
/// every game used to hand-roll —
///
///  * the persisted day/night theme on `theme`/`darkTheme`/`themeMode`
///    ([appTheme], the same toggle the top bar flips);
///  * the persisted language on `locale` ([appLocale], the settings
///    picker's choice) plus Material's localization delegates, with room
///    for the host's own game-string delegates;
///  * the shell's startup preload (theme, locale, account) so the first
///    frame already knows the player and their choices.
///
/// The host supplies identity, not plumbing:
///
/// ```dart
/// void main() => runApp(ShellApp(
///       title: 'My Game',
///       seedColor: const Color(0xff7a5c2e),
///       home: const MySplash(),
///     ));
/// ```
///
/// The default theme is Material 3 seeded from [ShellApp.seedColor]; pass
/// [ShellApp.themeBuilder] for custom palettes or scaffold backgrounds.
/// [ShellApp.locale], [ShellApp.themeMode] and the delegate list are
/// passthrough overrides — unset, the shell's persisted values rule.
class ShellApp extends StatefulWidget {
  const ShellApp({
    super.key,
    required this.home,
    required this.seedColor,
    this.title = '',
    this.themeBuilder,
    this.locale,
    this.themeMode,
    this.localizationsDelegates,
    this.supportedLocales,
    this.debugShowCheckedModeBanner = false,
  });

  /// The app's home — usually the game's [AppSplash].
  final Widget home;

  /// The seed behind the default seeded themes (ignored when a
  /// [themeBuilder] is supplied).
  final Color seedColor;

  /// MaterialApp's title (task switchers, browser tabs).
  final String title;

  /// Builds the light and dark themes. Null uses Material 3 seeded from
  /// [seedColor], both brightnesses.
  final ShellThemeBuilder? themeBuilder;

  /// Overrides the persisted locale. Null follows [appLocale] (unset =
  /// the platform default, English strings in the shell).
  final Locale? locale;

  /// Overrides the persisted theme mode. Null follows [appTheme].
  final ThemeMode? themeMode;

  /// The host's own localization delegates (game strings), merged after
  /// the shell's Material/Widgets/Cupertino globals.
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;

  /// Overrides the app's supported locales. Null defaults to the shell's
  /// [ShellLanguage] list; hosts with their own l10n pass theirs.
  final List<Locale>? supportedLocales;

  /// Passes through to MaterialApp. Games usually keep it false.
  final bool debugShowCheckedModeBanner;

  @override
  State<ShellApp> createState() => _ShellAppState();
}

class _ShellAppState extends State<ShellApp> {
  @override
  void initState() {
    super.initState();
    // The startup preload the shell docs used to ask hosts to write — one
    // place, before the first frame can paint a stale welcome or theme.
    // The explicit rebuild afterwards covers restores that don't notify
    // by themselves (an anonymous player's persisted name changes no
    // notifier value, yet the welcome must re-read it).
    unawaited(_preload());
  }

  Future<void> _preload() async {
    await Future.wait([appTheme.load(), appLocale.load(), account.load()]);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // account included: its load() landing after the first frame repaints
      // the splash welcome with the restored player name.
      animation: Listenable.merge([appTheme, appLocale, account]),
      builder: (context, _) {
        final themeBuilder = widget.themeBuilder ??
            (context, brightness) => ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                      seedColor: widget.seedColor, brightness: brightness),
                  useMaterial3: true,
                );
        return MaterialApp(
          title: widget.title,
          debugShowCheckedModeBanner: widget.debugShowCheckedModeBanner,
          theme: themeBuilder(context, Brightness.light),
          darkTheme: themeBuilder(context, Brightness.dark),
          themeMode: widget.themeMode ?? appTheme.value,
          locale: widget.locale ?? appLocale.value?.locale,
          supportedLocales:
              widget.supportedLocales ?? ShellLanguage.values.map((l) => l.locale).toList(),
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            ...?widget.localizationsDelegates,
          ],
          home: widget.home,
        );
      },
    );
  }
}
