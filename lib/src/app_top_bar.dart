import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_settings.dart';
import 'settings_screen.dart';
import 'theme_toggle_button.dart';

/// The reusable top bar for the shell screens (splash, saved games, lobby).
///
/// Left: the app release version (`v1.2.3+45`), so any screen hosting this
/// bar tells testers exactly what build they are running. Right: the
/// day/night theme toggle and the settings button — the same two controls
/// on every screen that hosts the bar, whichever game hosts the screens.
///
/// [title] carries the host screen's name in the middle, and [gameId] tags
/// the settings route so games can share the account/options plumbing
/// while extending their own.
///
/// [settingsBuilder] decides which settings screen the gear opens. Apps
/// that only use the shared sections leave it null (the package's own
/// [SettingsScreen] opens); games with their own sections wrap them in a
/// builder.
class AppTopBar extends StatefulWidget {
  const AppTopBar(
      {super.key, this.title, this.gameId = 'app', this.settingsBuilder});

  /// Host screen title, rendered between the version and the controls.
  final String? title;

  /// Which game is hosting the bar. Keys the settings navigation so games
  /// can share the account/options plumbing while extending their own.
  final String gameId;

  /// Builds the settings screen the gear opens. Defaults to the package's
  /// plain [SettingsScreen]; hosts with game sections wrap theirs here.
  final Widget Function()? settingsBuilder;

  @override
  State<AppTopBar> createState() => _AppTopBarState();
}

class _AppTopBarState extends State<AppTopBar> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _packageInfo = info);
    }).catchError((_) {
      // Platform info unavailable (e.g. web without the plugin binding):
      // the bar simply renders without a version chip.
    });
  }

  void _openSettings() {
    final builder =
        widget.settingsBuilder ?? () => SettingsScreen(gameId: widget.gameId);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => builder()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(children: [
        // Left: release identity for tester bug reports.
        Text(
          _packageInfo == null
              ? ''
              : 'v${_packageInfo!.version}+${_packageInfo!.buildNumber}',
          key: const ValueKey('app-version-chip'),
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
        if (widget.title != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.title!,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ] else
          const Spacer(),
        // Right: theme toggle and settings — identical on every host screen.
        // The label rides on the ICON, not just the tooltip: a Tooltip
        // surfaces its text to the semantics tree only while the tooltip
        // is VISIBLE, so a tooltip-only icon button announces as a bare
        // "button" in a freshly pumped tree (caught at runtime by the
        // route-semantics walk, katalogus
        // test/route_semantics_walk_test.dart).
        ThemeToggleButton(),
        IconButton(
          key: const ValueKey('settings-button'),
          tooltip: appLocale.strings.settingsTooltip,
          icon: Semantics(
            label: appLocale.strings.settingsTooltip,
            child: const Icon(Icons.settings_outlined, size: 20),
          ),
          onPressed: _openSettings,
        ),
      ]),
    );
  }
}

/// The version/theme/settings controls as AppBar actions, for screens whose
/// shell is a Scaffold with its own AppBar (the lobby wizard). Same controls
/// and settings routing as [AppTopBar] — one vocabulary everywhere.
class AppTopBarActions extends StatefulWidget {
  const AppTopBarActions({super.key, this.gameId = 'app'});

  final String gameId;

  @override
  State<AppTopBarActions> createState() => _AppTopBarActionsState();
}

class _AppTopBarActionsState extends State<AppTopBarActions> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _packageInfo = info);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(
        _packageInfo == null
            ? ''
            : 'v${_packageInfo!.version}+${_packageInfo!.buildNumber}',
        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
      ),
      // Labels on the icons, not just the tooltips — see AppTopBar.
      ThemeToggleButton(),
      IconButton(
        tooltip: appLocale.strings.settingsTooltip,
        icon: Semantics(
          label: appLocale.strings.settingsTooltip,
          child: const Icon(Icons.settings_outlined, size: 20),
        ),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => SettingsScreen(gameId: widget.gameId)),
        ),
      ),
    ]);
  }
}
