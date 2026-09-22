import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_settings.dart';
import 'multiplayer/join_link.dart';
import 'shell_strings.dart';

/// What [ShellApp] does with an arriving invite: usually a navigator push
/// of the game's lobby, seeded with [SharedLobbyStep.initialCode].
typedef ShellJoinHandler = void Function(JoinInvite invite);

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
    this.onJoinInvite,
    this.showPreferencesSyncedNotice = true,
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

  /// Receives an invite when the app is opened through a join link
  /// (`…#join=CODE` or `?join=CODE`) — a friend's email, a shared chat
  /// message, a QR code. The shell detects the link (browser URL on web,
  /// app links on mobile: cold start and warm returns) and calls this
  /// once the widget tree is up; the handler navigates to the lobby with
  /// the code pre-locked. See [SharedLobbyStep.initialCode]. Null (the
  /// default) ignores join links entirely.
  final ShellJoinHandler? onJoinInvite;

  /// Tells the player their account just brought their preferences in
  /// (theme, language, name — the cross-project sync, see
  /// [AccountController.preferencesPulled]). Set false to hush it (hosts
  /// that surface the sync differently).
  final bool showPreferencesSyncedNotice;

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
    unawaited(_watchJoinLinks());
  }

  Future<void> _preload() async {
    await Future.wait([appTheme.load(), appLocale.load(), account.load()]);
    if (mounted) setState(() {});
  }

  /// Join-link detection: the browser URL on web; app links on mobile —
  /// the cold-start link plus warm returns while the app runs. Delivers
  /// at most one invite per distinct link (some platforms replay the
  /// initial link on the stream). Errors (tests, desktops without a link
  /// backend) mean "nothing to join here", never a crash.
  Uri? _lastJoinDelivered;

  Future<void> _watchJoinLinks() async {
    final handler = widget.onJoinInvite;
    if (handler == null) return;
    try {
      if (kIsWeb) {
        _deliverJoin(Uri.base, handler);
        return;
      }
      final links = AppLinks();
      // Warm returns first, so nothing falls in the gap while the
      // initial link is being read.
      final subscription = links.uriLinkStream.listen(
        (uri) => _deliverJoin(uri, handler),
        onError: (_) {},
      );
      final initial = await links.getInitialLink();
      if (initial != null) _deliverJoin(initial, handler);
      // The shell lives as long as the app; the subscription rides along.
      // (Kept referenced so the analyzer sees a deliberate listen.)
      _joinSubscription = subscription;
    } catch (_) {
      // No link backend here — nothing to join.
    }
  }

  StreamSubscription<Uri>? _joinSubscription;

  void _deliverJoin(Uri uri, ShellJoinHandler handler) {
    if (uri.toString() == _lastJoinDelivered?.toString()) return;
    final invite = joinInviteFromUri(uri);
    if (invite == null) return;
    _lastJoinDelivered = uri;
    // Deliver once the tree can navigate (a cold start calls while the
    // first frame is still building). scheduleFrame guarantees that a
    // frame actually happens — an idle/static app would otherwise never
    // run the callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) handler(invite);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void dispose() {
    unawaited(_joinSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The sync notice posts on MaterialApp's own root ScaffoldMessenger
    // (handed our key via `scaffoldMessengerKey`) — visible over any
    // screen, including the settings screen the pull may have just
    // repainted. Scaffolds register there by default, so the notice has
    // somewhere to land.
    return _SyncNotice(
      messengerKey: _messengerKey,
      enabled: widget.showPreferencesSyncedNotice,
      child: AnimatedBuilder(
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
            scaffoldMessengerKey: _messengerKey,
            theme: themeBuilder(context, Brightness.light),
            darkTheme: themeBuilder(context, Brightness.dark),
            themeMode: widget.themeMode ?? appTheme.value,
            locale: widget.locale ?? appLocale.value?.locale,
            supportedLocales: widget.supportedLocales ??
                ShellLanguage.values.map((l) => l.locale).toList(),
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              ...?widget.localizationsDelegates,
            ],
            home: widget.home,
          );
        },
      ),
    );
  }
}

/// Listens for pulled preferences and posts the localized snackbar on the
/// root messenger. A [ValueListenableBuilder] (not a listener callback)
/// keeps the subscription mounted across rebuilds; the controller's
/// acknowledge marks ([AccountController.shouldShowSyncNotice] /
/// [AccountController.markSyncNoticeShown]) keep each pull event to one
/// notice even if the messenger was not ready the first time around.
class _SyncNotice extends StatelessWidget {
  const _SyncNotice({
    required this.messengerKey,
    required this.enabled,
    required this.child,
  });

  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: account.preferencesPulled,
      builder: (context, pulled, child) {
        if (pulled > 0 && enabled && account.shouldShowSyncNotice(pulled)) {
          final messenger = messengerKey.currentState;
          if (messenger != null) {
            account.markSyncNoticeShown(pulled);
            // Post after the frame: showSnackBar asserts on live Scaffolds,
            // which a mid-build call would not see. scheduleFrame makes
            // sure the frame happens (an idle/static app would not).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              messenger
                ..clearSnackBars()
                ..showSnackBar(SnackBar(
                  // Read now, after the pull landed: if the locale itself
                  // was pulled, the notice speaks the new language.
                  content: Text(appLocale.strings.preferencesSynced),
                  width: 420,
                  behavior: SnackBarBehavior.floating,
                ));
            });
            WidgetsBinding.instance.scheduleFrame();
          }
        }
        return child!;
      },
      child: child,
    );
  }
}
