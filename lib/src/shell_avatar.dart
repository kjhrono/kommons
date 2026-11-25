import 'package:flutter/material.dart';

// -----------------------------------------------------------------------------
// The player's avatar: what they chose (initials, their sign-in provider's
// photo, or one of the built-in presets), as a token that syncs across
// projects in the account metadata (`kommons.avatar`, see
// shell_preferences.dart), and the round view every shell surface draws it
// with (top bar, settings picker).
//
// Presets are icons, not images: nothing to upload, nothing to moderate, and
// they take the theme's colours so dark and high-contrast modes keep working.
// -----------------------------------------------------------------------------

/// What kind of avatar the player picked.
enum ShellAvatarKind {
  /// One or two letters from the name (or email).
  initials,

  /// The sign-in provider's photo (Google's profile picture).
  provider,

  /// One of [ShellAvatarPreset.all].
  preset,
}

/// A built-in avatar: a stable id (what syncs) and the icon drawn for it.
@immutable
class ShellAvatarPreset {
  const ShellAvatarPreset(this.id, this.icon);

  /// Persisted in the token (`preset:<id>`) — never rename one.
  final String id;
  final IconData icon;

  /// Every preset, in picker order. Append only: ids are synced data.
  static const all = <ShellAvatarPreset>[
    ShellAvatarPreset('fox', Icons.pets),
    ShellAvatarPreset('rocket', Icons.rocket_launch_outlined),
    ShellAvatarPreset('star', Icons.star_outline),
    ShellAvatarPreset('bolt', Icons.bolt),
    ShellAvatarPreset('leaf', Icons.eco_outlined),
    ShellAvatarPreset('music', Icons.music_note_outlined),
    ShellAvatarPreset('castle', Icons.castle_outlined),
    ShellAvatarPreset('sailing', Icons.sailing_outlined),
    ShellAvatarPreset('palette', Icons.palette_outlined),
    ShellAvatarPreset('sports', Icons.sports_esports_outlined),
    ShellAvatarPreset('coffee', Icons.coffee_outlined),
    ShellAvatarPreset('bug', Icons.bug_report_outlined),
  ];

  static ShellAvatarPreset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

/// The player's avatar choice. Round-trips through [token] / [tryParse].
@immutable
class ShellAvatar {
  const ShellAvatar._(this.kind, [this.presetId]);

  static const initials = ShellAvatar._(ShellAvatarKind.initials);
  static const provider = ShellAvatar._(ShellAvatarKind.provider);

  factory ShellAvatar.preset(ShellAvatarPreset preset) =>
      ShellAvatar._(ShellAvatarKind.preset, preset.id);

  final ShellAvatarKind kind;

  /// The preset id, for [ShellAvatarKind.preset].
  final String? presetId;

  /// The synced form: `initials`, `provider` or `preset:<id>`.
  String get token => switch (kind) {
        ShellAvatarKind.initials => 'initials',
        ShellAvatarKind.provider => 'provider',
        ShellAvatarKind.preset => 'preset:$presetId',
      };

  /// Reads a token. Unknown tokens (a newer app's preset, a typo) read as
  /// null — the caller falls back to the default, never a crash.
  static ShellAvatar? tryParse(String? token) {
    if (token == null) return null;
    if (token == 'initials') return initials;
    if (token == 'provider') return provider;
    if (token.startsWith('preset:')) {
      final preset = ShellAvatarPreset.byId(token.substring(7));
      if (preset != null) return ShellAvatar.preset(preset);
    }
    return null;
  }

  /// What to draw for a [choice] that may be unset: an unset choice shows
  /// the provider photo when there is one, the initials otherwise; a
  /// provider choice without a photo (signed out of Google) also falls
  /// back to the initials.
  static ShellAvatar resolve(ShellAvatar? choice, {String? photoUrl}) {
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    final picked = choice ?? (hasPhoto ? provider : initials);
    if (picked.kind == ShellAvatarKind.provider && !hasPhoto) return initials;
    return picked;
  }

  @override
  bool operator ==(Object other) =>
      other is ShellAvatar && other.kind == kind && other.presetId == presetId;

  @override
  int get hashCode => Object.hash(kind, presetId);
}

/// The provider photo in a GoTrue user-metadata map (Google writes
/// `avatar_url` and `picture`), or null.
String? providerPhotoUrlFromMetadata(Map<String, dynamic> metadata) {
  for (final key in const ['avatar_url', 'picture']) {
    final value = metadata[key];
    if (value is String && value.startsWith('https://')) return value;
  }
  return null;
}

/// The provider's full name in a GoTrue user-metadata map (`full_name`,
/// `name`), or null.
String? providerDisplayNameFromMetadata(Map<String, dynamic> metadata) {
  for (final key in const ['full_name', 'name']) {
    final value = metadata[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

/// Up to two letters for [label]: the first letters of the first two
/// words ("Marco Sartori" → "MS"), or the first letter of an email's local
/// part ("marco@…" → "M"). Empty labels give an empty string.
String shellInitials(String? label) {
  final text = (label ?? '').trim();
  if (text.isEmpty) return '';
  final base = text.contains('@') ? text.split('@').first : text;
  final words = base
      .split(RegExp(r'[\s._-]+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return text.characters.first.toUpperCase();
  final letters = text.contains('@')
      ? [words.first.characters.first]
      : words.take(2).map((w) => w.characters.first);
  return letters.join().toUpperCase();
}

/// A round avatar: the provider photo, a preset icon, or initials. A photo
/// that fails to load (offline, expired URL) falls back to the initials.
class ShellAvatarView extends StatelessWidget {
  const ShellAvatarView({
    super.key,
    required this.avatar,
    this.label,
    this.photoUrl,
    this.radius = 16,
    this.anonymous = false,
  });

  /// The resolved choice (see [ShellAvatar.resolve]).
  final ShellAvatar avatar;

  /// Name or email the initials come from.
  final String? label;

  /// The provider photo, used for [ShellAvatarKind.provider].
  final String? photoUrl;

  final double radius;

  /// Draws the signed-out (incognito) avatar instead of [avatar].
  final bool anonymous;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget fallback() => _circle(
          scheme,
          Text(
            shellInitials(label).isEmpty ? '?' : shellInitials(label),
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
              fontSize: radius * 0.8,
            ),
          ),
        );

    if (anonymous) {
      return _circle(
        scheme,
        Icon(Icons.no_accounts_outlined,
            size: radius * 1.2, color: scheme.onSurfaceVariant),
        background: scheme.surfaceContainerHighest,
      );
    }
    switch (avatar.kind) {
      case ShellAvatarKind.provider:
        final url = photoUrl;
        if (url == null || url.isEmpty) return fallback();
        return ClipOval(
          child: Image.network(
            url,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback(),
          ),
        );
      case ShellAvatarKind.preset:
        final preset = ShellAvatarPreset.byId(avatar.presetId ?? '');
        if (preset == null) return fallback();
        return _circle(
          scheme,
          Icon(preset.icon,
              size: radius * 1.1, color: scheme.onPrimaryContainer),
        );
      case ShellAvatarKind.initials:
        return fallback();
    }
  }

  Widget _circle(ColorScheme scheme, Widget child, {Color? background}) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background ?? scheme.primaryContainer,
      ),
      child: child,
    );
  }
}
