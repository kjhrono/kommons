import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_settings.dart';
import 'identity_account_card.dart';
import 'settings_screen.dart';
import 'shell_avatar.dart';
import 'shell_inks.dart';
import 'shell_preferences.dart';
import 'shell_strings.dart' show ShellLanguage;
import 'theme_toggle_button.dart';

// -----------------------------------------------------------------------------
// ShellTopBar: the account-and-status bar every app shares, above the app's
// own screen bar (screen name, back button).
//
//   ┌──────────────────────────────────────────────────────────┐
//   │ (MS) Marco Sartori  [G][✉]                 PREMIUM   ⓘ   │  identity, plan, about
//   │ ⟳ Cloud · synced                          🔔²  ☾   ⚙    │  storage, notify, theme, settings
//   └──────────────────────────────────────────────────────────┘
//
// On wide windows the two rows share one line. Everything app-specific plugs
// in: who is signed in ([ShellIdentity] via an adapter), the plan
// ([ShellPlan]), where data lives ([ShellSyncController]) and notifications.
// Slots left null are simply not drawn. Sign-in and sign-out live in
// settings: tapping the identity opens them.
// -----------------------------------------------------------------------------

/// How an account signs in, as the bar draws it (an account can carry
/// several).
enum ShellSignInKind { email, google, github }

/// The icon drawn for each sign-in method.
IconData shellSignInKindIcon(ShellSignInKind kind) => switch (kind) {
      ShellSignInKind.email => Icons.mail_outline,
      ShellSignInKind.google => Icons.g_mobiledata,
      ShellSignInKind.github => Icons.code,
    };

/// Who the bar shows. Signed out is [ShellIdentity.anonymous].
@immutable
class ShellIdentity {
  const ShellIdentity({
    this.name,
    this.email,
    this.kinds = const {},
    this.avatar,
    this.photoUrl,
  });

  static const anonymous = ShellIdentity();

  /// The player name, when they have one (null falls back to [email]).
  final String? name;
  final String? email;

  /// The sign-in methods; empty means signed out.
  final Set<ShellSignInKind> kinds;

  /// The avatar choice (null = default, see [ShellAvatar.resolve]).
  final ShellAvatar? avatar;

  /// The provider photo, when the account has one.
  final String? photoUrl;

  bool get signedIn => kinds.isNotEmpty;

  /// What the bar prints: the name, else the email, else null (guest).
  String? get label => (name != null && name!.isNotEmpty) ? name : email;

  @override
  bool operator ==(Object other) =>
      other is ShellIdentity &&
      other.name == name &&
      other.email == email &&
      setEquals(other.kinds, kinds) &&
      other.avatar == avatar &&
      other.photoUrl == photoUrl;

  @override
  int get hashCode => Object.hash(
      name, email, Object.hashAllUnordered(kinds), avatar, photoUrl);
}

/// The identity of the shell's own [account] controller (email, password
/// and provider sign-in against the game server). The default source when
/// [ShellTopBar.identity] is null.
class ShellAccountIdentity extends ChangeNotifier
    implements ValueListenable<ShellIdentity> {
  ShellAccountIdentity({AccountController? controller})
      : _account = controller ?? account {
    _account.addListener(notifyListeners);
  }

  final AccountController _account;

  @override
  ShellIdentity get value {
    final current = _account.value;
    if (current == null) return ShellIdentity.anonymous;
    final kind = switch (current.provider) {
      'google' => ShellSignInKind.google,
      'github' => ShellSignInKind.github,
      _ => ShellSignInKind.email,
    };
    return ShellIdentity(
      name: _account.hasChosenName
          ? _account.playerName
          : _account.providerDisplayName,
      email: current.email.isEmpty ? null : current.email,
      kinds: {kind},
      avatar: _account.avatar,
      photoUrl: _account.providerPhotoUrl,
    );
  }

  @override
  void dispose() {
    _account.removeListener(notifyListeners);
    super.dispose();
  }
}

/// The identity of an app on the MediaSart identity stack
/// ([IdentityAccountHost]). Methods come from the session token; the name
/// and avatar from settings (the shell's [account]) first, then the
/// account's synced `kommons` metadata, then the provider (Google).
class ShellIdentityHostIdentity extends ChangeNotifier
    implements ValueListenable<ShellIdentity> {
  ShellIdentityHostIdentity(this.host, {AccountController? controller})
      : _account = controller ?? account {
    _account.addListener(notifyListeners);
    _sub = host.sessionChanges.listen((_) => notifyListeners());
  }

  final IdentityAccountHost host;
  final AccountController _account;
  late final StreamSubscription<Object?> _sub;

  @override
  ShellIdentity get value {
    final session = host.currentSession;
    final info = IdentityAccountInfo.fromSession(session);
    if (!info.signedIn) return ShellIdentity.anonymous;
    final metadata = identityUserMetadata(session);
    final synced = shellPreferencesFromMetadata(metadata);
    final syncedName = shellPreferenceValue(synced, ShellPrefKey.playerName);
    return ShellIdentity(
      name: _account.hasChosenName
          ? _account.playerName
          : (syncedName ?? providerDisplayNameFromMetadata(metadata)),
      email: info.email,
      kinds: {
        for (final kind in info.kinds)
          if (kind == IdentitySignInKind.email)
            ShellSignInKind.email
          else if (kind == IdentitySignInKind.google)
            ShellSignInKind.google,
      },
      avatar: _account.avatar ??
          ShellAvatar.tryParse(
              shellPreferenceValue(synced, ShellPrefKey.avatar)),
      photoUrl: providerPhotoUrlFromMetadata(metadata),
    );
  }

  @override
  void dispose() {
    _sub.cancel();
    _account.removeListener(notifyListeners);
    super.dispose();
  }
}

/// The app's plan, shown as a badge. Must come from the server (GoTrue
/// `app_metadata` or a table only the server writes), never from
/// `user_metadata`: players can edit their own user metadata.
enum ShellPlan { free, premium }

/// Where the player chose to keep their data.
enum ShellStorageMode { local, cloud }

/// What the sync is doing right now.
enum ShellSyncPhase { idle, syncing, error }

/// The storage status the bar draws.
@immutable
class ShellSyncState {
  const ShellSyncState({
    this.mode = ShellStorageMode.cloud,
    this.online = true,
    this.phase = ShellSyncPhase.idle,
    this.pendingChanges = 0,
    this.lastSyncedAt,
  });

  /// The player's choice.
  final ShellStorageMode mode;

  /// Whether the cloud is reachable. Base it on real request outcomes, not
  /// only on the network interface: wifi up does not mean the server is.
  final bool online;

  final ShellSyncPhase phase;

  /// Local changes not yet in the cloud.
  final int pendingChanges;
  final DateTime? lastSyncedAt;

  /// True when the app is working on local data right now: by choice, or
  /// because the cloud is unreachable.
  bool get workingLocally => mode == ShellStorageMode.local || !online;

  ShellSyncState copyWith({
    ShellStorageMode? mode,
    bool? online,
    ShellSyncPhase? phase,
    int? pendingChanges,
    DateTime? lastSyncedAt,
  }) =>
      ShellSyncState(
        mode: mode ?? this.mode,
        online: online ?? this.online,
        phase: phase ?? this.phase,
        pendingChanges: pendingChanges ?? this.pendingChanges,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
}

/// The app's storage and sync, as the bar sees it. Each app subclasses it
/// (its data lives its own way), updates [value] as things happen, and
/// implements [syncNow]. [setMode] records the player's choice; override
/// it to also move data (call `super.setMode` to update the state).
abstract class ShellSyncController extends ValueNotifier<ShellSyncState> {
  ShellSyncController([super.value = const ShellSyncState()]);

  /// Pushes local changes up and pulls remote ones down.
  Future<void> syncNow();

  /// Switches between local-only and cloud storage.
  Future<void> setMode(ShellStorageMode mode) async {
    value = value.copyWith(mode: mode);
  }
}

/// The account-and-status bar every app shares. Fits `Scaffold.appBar`
/// (or anywhere as a plain widget); the app's own screen bar goes below
/// it, in the body.
class ShellTopBar extends StatefulWidget implements PreferredSizeWidget {
  const ShellTopBar({
    super.key,
    this.identity,
    this.plan,
    this.sync,
    this.unreadNotifications,
    this.onNotificationsPressed,
    this.settingsBuilder,
    this.gameId = 'app',
    this.appName,
    this.onInfoPressed,
    this.aboutChildren = const [],
    this.wideBreakpoint = 720,
  });

  /// Who is signed in. Null uses the shell's [account] controller
  /// ([ShellAccountIdentity]); apps on the identity stack pass
  /// [ShellIdentityHostIdentity].
  final ValueListenable<ShellIdentity>? identity;

  /// The FREE / PREMIUM badge. Null hides it.
  final ValueListenable<ShellPlan>? plan;

  /// The storage status and sync button. Null hides them.
  final ShellSyncController? sync;

  /// The badge on the notifications icon.
  final ValueListenable<int>? unreadNotifications;

  /// Opens the app's notifications. Null hides the icon.
  final void Function(BuildContext context)? onNotificationsPressed;

  /// The settings screen the gear and the identity open. Null opens the
  /// shell's [SettingsScreen].
  final Widget Function()? settingsBuilder;

  /// Keys the default [SettingsScreen].
  final String gameId;

  /// The app name in the About dialog (defaults to the package's).
  final String? appName;

  /// Replaces the default About dialog.
  final void Function(BuildContext context)? onInfoPressed;

  /// Extra lines for the default About dialog.
  final List<Widget> aboutChildren;

  /// From this width up, the two rows share one line.
  final double wideBreakpoint;

  /// Row heights. [preferredSize] is the two-row (tallest) layout: a
  /// Scaffold lets the bar be shorter, and the wide layout is.
  static const double rowHeight = 48;
  static const double statusRowHeight = 40;

  @override
  Size get preferredSize => const Size.fromHeight(rowHeight + statusRowHeight);

  @override
  State<ShellTopBar> createState() => _ShellTopBarState();
}

class _ShellTopBarState extends State<ShellTopBar> {
  ShellAccountIdentity? _ownIdentity;

  ValueListenable<ShellIdentity> get _identity =>
      widget.identity ?? (_ownIdentity ??= ShellAccountIdentity());

  @override
  void dispose() {
    _ownIdentity?.dispose();
    super.dispose();
  }

  void _openSettings() {
    final builder =
        widget.settingsBuilder ?? () => SettingsScreen(gameId: widget.gameId);
    Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));
  }

  void _openInfo() {
    final custom = widget.onInfoPressed;
    if (custom != null) return custom(context);
    showShellAboutDialog(
      context,
      appName: widget.appName,
      plan: widget.plan?.value,
      children: widget.aboutChildren,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final identity = ValueListenableBuilder<ShellIdentity>(
      valueListenable: _identity,
      builder: (context, value, _) =>
          _IdentityButton(identity: value, onPressed: _openSettings),
    );
    final plan = widget.plan == null
        ? null
        : ValueListenableBuilder<ShellPlan>(
            valueListenable: widget.plan!,
            builder: (context, value, _) => _PlanBadge(plan: value),
          );
    final info = IconButton(
      key: const ValueKey('shell-info'),
      tooltip: shellTopBarStrings.info,
      icon: Semantics(
        label: shellTopBarStrings.info,
        child: const Icon(Icons.info_outline, size: 20),
      ),
      onPressed: _openInfo,
    );
    final syncStatus = widget.sync == null
        ? null
        : ValueListenableBuilder<ShellSyncState>(
            valueListenable: widget.sync!,
            builder: (context, value, _) =>
                _SyncButton(state: value, controller: widget.sync!),
          );
    final notify = widget.onNotificationsPressed == null
        ? null
        : _NotificationsButton(
            unread: widget.unreadNotifications,
            onPressed: () => widget.onNotificationsPressed!(context),
          );
    final settings = IconButton(
      key: const ValueKey('settings-button'),
      tooltip: shellTopBarStrings.settings,
      icon: Semantics(
        label: shellTopBarStrings.settings,
        child: const Icon(Icons.settings_outlined, size: 20),
      ),
      onPressed: _openSettings,
    );

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= widget.wideBreakpoint;
          final rightTools = <Widget>[
            if (notify != null) notify,
            const ThemeToggleButton(),
            settings,
          ];
          if (wide) {
            return SizedBox(
              key: const ValueKey('shell-top-bar-wide'),
              height: ShellTopBar.rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  // Identity and storage share what the tools leave, and
                  // both shrink (ellipsis) before anything overflows.
                  Expanded(
                    child: Row(children: [
                      Flexible(flex: 3, child: identity),
                      if (syncStatus != null) ...[
                        const SizedBox(width: 12),
                        Flexible(flex: 2, child: syncStatus),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 8),
                  if (plan != null) ...[plan, const SizedBox(width: 8)],
                  ...rightTools,
                  info,
                ]),
              ),
            );
          }
          return Column(
            key: const ValueKey('shell-top-bar-narrow'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: ShellTopBar.rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Expanded(
                      child: Align(
                          alignment: Alignment.centerLeft, child: identity),
                    ),
                    if (plan != null) plan,
                    info,
                  ]),
                ),
              ),
              SizedBox(
                height: ShellTopBar.statusRowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: syncStatus ?? const SizedBox.shrink(),
                      ),
                    ),
                    ...rightTools,
                  ]),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _IdentityButton extends StatelessWidget {
  const _IdentityButton({required this.identity, required this.onPressed});

  final ShellIdentity identity;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = shellTopBarStrings;
    final scheme = Theme.of(context).colorScheme;
    final label = identity.label ?? strings.guest;
    final kinds = ShellSignInKind.values.where(identity.kinds.contains);
    return Semantics(
      button: true,
      label: identity.signedIn ? label : strings.guestHint,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('shell-identity'),
        borderRadius: BorderRadius.circular(24),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ShellAvatarView(
              anonymous: !identity.signedIn,
              avatar: ShellAvatar.resolve(identity.avatar,
                  photoUrl: identity.photoUrl),
              photoUrl: identity.photoUrl,
              label: identity.label,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                key: const ValueKey('shell-identity-label'),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            if (!identity.signedIn)
              Icon(Icons.no_accounts_outlined,
                  key: const ValueKey('shell-kind-anonymous'),
                  size: 16,
                  color: scheme.mutedInk)
            else
              for (final kind in kinds)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Icon(shellSignInKindIcon(kind),
                      key: ValueKey('shell-kind-${kind.name}'),
                      size: 16,
                      color: scheme.mutedInk),
                ),
          ]),
        ),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.plan});

  final ShellPlan plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final premium = plan == ShellPlan.premium;
    final text = premium ? shellTopBarStrings.premium : shellTopBarStrings.free;
    return Container(
      key: ValueKey('shell-plan-${plan.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: premium ? scheme.tertiaryContainer : null,
        border: Border.all(
            color: premium ? scheme.tertiary : scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (premium) ...[
          Icon(Icons.workspace_premium,
              size: 14, color: scheme.onTertiaryContainer),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
            color: premium ? scheme.onTertiaryContainer : scheme.mutedInk,
          ),
        ),
      ]),
    );
  }
}

/// The storage status line: icon plus short text, tapping opens the sheet
/// with "Sync now" and the local/cloud choice.
class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.state, required this.controller});

  final ShellSyncState state;
  final ShellSyncController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final look = _shellSyncLook(state);
    final color = switch (look.tone) {
      _SyncTone.ok => scheme.readyInk,
      _SyncTone.warn => scheme.warningInk,
      _SyncTone.error => scheme.dangerInk,
      _SyncTone.quiet => scheme.mutedInk,
    };
    return Semantics(
      button: true,
      label: look.text,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('shell-sync'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showSyncSheet(context, controller),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(look.icon, size: 18, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                look.text,
                key: const ValueKey('shell-sync-label'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.mutedInk),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

enum _SyncTone { ok, warn, error, quiet }

/// The icon, tone and text for a sync state.
({IconData icon, _SyncTone tone, String text}) _shellSyncLook(
    ShellSyncState state) {
  final s = shellTopBarStrings;
  final pending =
      state.pendingChanges > 0 ? s.pending(state.pendingChanges) : '';
  if (state.mode == ShellStorageMode.local) {
    return (
      icon: Icons.phone_android,
      tone: _SyncTone.quiet,
      text: s.localByChoice,
    );
  }
  if (!state.online) {
    return (
      icon: Icons.cloud_off_outlined,
      tone: _SyncTone.warn,
      text: '${s.offlineLocal}$pending',
    );
  }
  return switch (state.phase) {
    ShellSyncPhase.syncing => (
        icon: Icons.cloud_sync_outlined,
        tone: _SyncTone.quiet,
        text: s.syncing,
      ),
    ShellSyncPhase.error => (
        icon: Icons.sync_problem,
        tone: _SyncTone.error,
        text: '${s.syncError}$pending',
      ),
    ShellSyncPhase.idle => state.pendingChanges > 0
        ? (
            icon: Icons.cloud_upload_outlined,
            tone: _SyncTone.warn,
            text: '${s.cloud}$pending',
          )
        : (
            icon: Icons.cloud_done_outlined,
            tone: _SyncTone.ok,
            text: s.cloudSynced,
          ),
  };
}

Future<void> _showSyncSheet(
    BuildContext context, ShellSyncController controller) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => ValueListenableBuilder<ShellSyncState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final s = shellTopBarStrings;
        final look = _shellSyncLook(state);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.storageTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(look.icon, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(look.text)),
                ]),
                if (state.lastSyncedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    s.lastSynced(MaterialLocalizations.of(context)
                        .formatTimeOfDay(
                            TimeOfDay.fromDateTime(state.lastSyncedAt!))),
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.mutedInk),
                  ),
                ],
                const SizedBox(height: 16),
                SegmentedButton<ShellStorageMode>(
                  key: const ValueKey('shell-sync-mode'),
                  segments: [
                    ButtonSegment(
                        value: ShellStorageMode.local,
                        icon: const Icon(Icons.phone_android),
                        label: Text(s.modeLocal)),
                    ButtonSegment(
                        value: ShellStorageMode.cloud,
                        icon: const Icon(Icons.cloud_outlined),
                        label: Text(s.modeCloud)),
                  ],
                  selected: {state.mode},
                  onSelectionChanged: (picked) =>
                      controller.setMode(picked.first),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const ValueKey('shell-sync-now'),
                  onPressed: state.workingLocally ||
                          state.phase == ShellSyncPhase.syncing
                      ? null
                      : controller.syncNow,
                  icon: const Icon(Icons.sync),
                  label: Text(s.syncNow),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _NotificationsButton extends StatelessWidget {
  const _NotificationsButton({required this.unread, required this.onPressed});

  final ValueListenable<int>? unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    Widget button(int count) {
      final label = count > 0
          ? shellTopBarStrings.notificationsUnread(count)
          : shellTopBarStrings.notifications;
      return IconButton(
        key: const ValueKey('shell-notifications'),
        tooltip: shellTopBarStrings.notifications,
        icon: Semantics(
          label: label,
          child: Badge(
            isLabelVisible: count > 0,
            label: Text(count > 99 ? '99+' : '$count'),
            child: Icon(
                count > 0
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_none,
                size: 20),
          ),
        ),
        onPressed: onPressed,
      );
    }

    final source = unread;
    if (source == null) return button(0);
    return ValueListenableBuilder<int>(
      valueListenable: source,
      builder: (context, count, _) => button(count),
    );
  }
}

/// The About dialog the ⓘ opens: app name, version and build (for bug
/// reports), the plan, and any extra lines.
Future<void> showShellAboutDialog(
  BuildContext context, {
  String? appName,
  ShellPlan? plan,
  List<Widget> children = const [],
}) {
  // The dialog opens at once; the version fills in when the platform
  // answers (no platform info — tests, web without the plugin — no line).
  final info = PackageInfo.fromPlatform()
      .then<PackageInfo?>((value) => value)
      .catchError((Object _) => null);
  final s = shellTopBarStrings;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => FutureBuilder<PackageInfo?>(
      future: info,
      builder: (context, snapshot) {
        final package = snapshot.data;
        final name = appName ?? package?.appName ?? '';
        return AlertDialog(
          key: const ValueKey('shell-about'),
          title: Text(name.isEmpty ? s.info : name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (package != null)
                SelectableText(
                    '${s.version} ${package.version}+${package.buildNumber}',
                    key: const ValueKey('shell-about-version')),
              if (plan != null) ...[
                const SizedBox(height: 4),
                Text('${s.plan}: '
                    '${plan == ShellPlan.premium ? s.premium : s.free}'),
              ],
              ...children,
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                  MaterialLocalizations.of(dialogContext).closeButtonLabel),
            ),
          ],
        );
      },
    ),
  );
}

/// The bar's text, in the app's chosen language ([appLocale]).
class ShellTopBarStrings {
  const ShellTopBarStrings.english()
      : guest = 'Guest',
        guestHint = 'Guest, not signed in. Open settings to sign in',
        free = 'FREE',
        premium = 'PREMIUM',
        plan = 'Plan',
        info = 'About this app',
        version = 'Version',
        settings = 'Settings',
        notifications = 'Notifications',
        storageTitle = 'Where your data lives',
        localByChoice = 'Local',
        offlineLocal = 'Offline · local',
        cloud = 'Cloud',
        cloudSynced = 'Cloud · synced',
        syncing = 'Syncing…',
        syncError = 'Sync failed',
        modeLocal = 'This device',
        modeCloud = 'Cloud',
        syncNow = 'Sync now',
        _pendingSuffix = 'to sync',
        _lastSyncedPrefix = 'Last synced at',
        _unreadSuffix = 'unread';

  const ShellTopBarStrings.italian()
      : guest = 'Ospite',
        guestHint =
            'Ospite, accesso non effettuato. Apri le impostazioni per accedere',
        free = 'FREE',
        premium = 'PREMIUM',
        plan = 'Piano',
        info = 'Informazioni sull’app',
        version = 'Versione',
        settings = 'Impostazioni',
        notifications = 'Notifiche',
        storageTitle = 'Dove sono i tuoi dati',
        localByChoice = 'Locale',
        offlineLocal = 'Offline · locale',
        cloud = 'Cloud',
        cloudSynced = 'Cloud · sincronizzato',
        syncing = 'Sincronizzazione…',
        syncError = 'Sincronizzazione non riuscita',
        modeLocal = 'Questo dispositivo',
        modeCloud = 'Cloud',
        syncNow = 'Sincronizza ora',
        _pendingSuffix = 'da sincronizzare',
        _lastSyncedPrefix = 'Ultima sincronizzazione alle',
        _unreadSuffix = 'non lette';

  final String guest;
  final String guestHint;
  final String free;
  final String premium;
  final String plan;
  final String info;
  final String version;
  final String settings;
  final String notifications;
  final String storageTitle;
  final String localByChoice;
  final String offlineLocal;
  final String cloud;
  final String cloudSynced;
  final String syncing;
  final String syncError;
  final String modeLocal;
  final String modeCloud;
  final String syncNow;
  final String _pendingSuffix;
  final String _lastSyncedPrefix;
  final String _unreadSuffix;

  /// " · 3 to sync"
  String pending(int count) => ' · $count $_pendingSuffix';

  String lastSynced(String time) => '$_lastSyncedPrefix $time';

  String notificationsUnread(int count) =>
      '$notifications, $count $_unreadSuffix';
}

const _english = ShellTopBarStrings.english();
const _italian = ShellTopBarStrings.italian();

ShellTopBarStrings get shellTopBarStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
