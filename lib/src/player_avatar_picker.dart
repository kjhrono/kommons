import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'shell_avatar.dart';
import 'shell_strings.dart' show ShellLanguage;

/// The avatar choices in settings: initials, the provider photo (when the
/// account has one, e.g. Google) and the built-in presets. Picking saves
/// through [AccountController.setAvatar], which syncs it to the account
/// so every project shows the same avatar.
class PlayerAvatarPicker extends StatelessWidget {
  const PlayerAvatarPicker({super.key, AccountController? controller})
      : _controller = controller;

  final AccountController? _controller;

  @override
  Widget build(BuildContext context) {
    final controller = _controller ?? account;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = playerAvatarStrings;
        final photo = controller.providerPhotoUrl;
        final label = controller.hasChosenName
            ? controller.playerName
            : (controller.providerDisplayName ?? controller.value?.email);
        final current = ShellAvatar.resolve(controller.avatar, photoUrl: photo);
        final options = <(ShellAvatar, String)>[
          (ShellAvatar.initials, s.initials),
          if (photo != null) (ShellAvatar.provider, s.providerPhoto),
          for (final preset in ShellAvatarPreset.all)
            (ShellAvatar.preset(preset), preset.id),
        ];
        final scheme = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.header, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (option, name) in options)
                  Semantics(
                    button: true,
                    selected: option == current,
                    label: name,
                    excludeSemantics: true,
                    child: InkWell(
                      key: ValueKey('avatar-option-${option.token}'),
                      customBorder: const CircleBorder(),
                      onTap: () => controller.setAvatar(option),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: 2,
                            color: option == current
                                ? scheme.primary
                                : Colors.transparent,
                          ),
                        ),
                        child: ShellAvatarView(
                          avatar: option,
                          label: label,
                          photoUrl: photo,
                          radius: 20,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "Use the name from Google" — shown when the account carries a provider
/// name different from the current player name. Tapping fills [onUse].
class ProviderNameSuggestion extends StatelessWidget {
  const ProviderNameSuggestion({super.key, required this.onUse});

  final ValueChanged<String> onUse;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final name = account.providerDisplayName;
        if (name == null || name == account.playerName) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ActionChip(
            key: const ValueKey('use-provider-name'),
            avatar: const Icon(Icons.g_mobiledata, size: 18),
            label: Text(playerAvatarStrings.useProviderName(name)),
            onPressed: () => onUse(name),
          ),
        );
      },
    );
  }
}

class PlayerAvatarStrings {
  const PlayerAvatarStrings.english()
      : header = 'Avatar',
        initials = 'Initials',
        providerPhoto = 'Google photo',
        _useName = 'Use';

  const PlayerAvatarStrings.italian()
      : header = 'Avatar',
        initials = 'Iniziali',
        providerPhoto = 'Foto di Google',
        _useName = 'Usa';

  final String header;
  final String initials;
  final String providerPhoto;
  final String _useName;

  String useProviderName(String name) => '$_useName “$name”';
}

const _english = PlayerAvatarStrings.english();
const _italian = PlayerAvatarStrings.italian();

PlayerAvatarStrings get playerAvatarStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
