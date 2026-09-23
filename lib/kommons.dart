/// The Kommons: everything a kjhrono game hosts before its own
/// content starts — the top bar with the release version and theme toggle,
/// the account/auth flow (email sign-in plus provider seams), the settings
/// screen those controls open, and the persisted day/night theme.
///
/// Games consume this as a path (or later git) dependency and supply their
/// identity through the seams each widget exposes: [AppTopBar.settingsBuilder]
/// decides which settings screen opens, [SettingsScreen]'s `extraSections`
/// append game-specific cards below the shared ones, and the OAuth provider
/// map turns the Google/GitHub buttons into live flows per app.
library;

export 'src/app_settings.dart';
export 'src/app_top_bar.dart';
export 'src/auth_service.dart';
export 'src/settings_screen.dart';
export 'src/shell_strings.dart';
export 'src/shell_preferences.dart';
export 'src/app_splash.dart';
export 'src/oauth_popup_launcher.dart';
export 'src/oauth_session_link.dart';
export 'src/oauth_revoke.dart';
export 'src/recovery_link.dart';
export 'src/shell_app.dart';

// Multiplayer core: seat model, sync transport contracts and implementations,
// room registry, server connection dialog, banner color picker.
export 'src/multiplayer/lobby_seat.dart';
export 'src/multiplayer/game_sync.dart';
export 'src/multiplayer/game_sync_service.dart';
export 'src/multiplayer/cloud_room_service.dart';
export 'src/multiplayer/game_server_dialog.dart';
export 'src/multiplayer/banner_color_picker.dart';
export 'src/multiplayer/lobby_wizard.dart';
export 'src/multiplayer/lobby_step.dart';
export 'src/multiplayer/qr_share.dart';
export 'src/multiplayer/join_link.dart';
export 'src/multiplayer/cloud_room_card.dart';
export 'src/multiplayer/cloud_handover_section.dart';
