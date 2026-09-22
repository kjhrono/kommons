import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_settings.dart';

/// Server address + Supabase anon key picked in the connect dialog.
typedef GameServerConnection = ({String url, String anonKey});

/// SharedPreferences keys for the game-server connection. The lobby has
/// always written these; the settings screen and the cloud account
/// controller read the same keys, so connecting from anywhere enables
/// cloud rooms, cloud sign-in and future save sync alike.
const gameServerUrlPrefKey = 'prefs.online.serverUrl';
const gameServerAnonKeyPrefKey = 'prefs.online.anonKey';

/// Asks for the game-server URL and (when the server is Supabase's Kong
/// gateway) its anon key. Both are remembered and pre-filled next time;
/// an empty key keeps talking to a bare PostgREST without auth headers.
///
/// The dialog is shared by the online lobby and the settings screen so the
/// player can establish the connection from either entry point — most
/// importantly from settings, before any multiplayer room ever existed,
/// because cloud account registration needs a server to register with.
Future<GameServerConnection?> showGameServerConnectionDialog(
    BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return null;
  final urlController =
      TextEditingController(text: prefs.getString(gameServerUrlPrefKey) ?? '');
  final keyController = TextEditingController(
      text: prefs.getString(gameServerAnonKeyPrefKey) ?? '');
  final strings = appLocale.strings;
  final connection = await showDialog<GameServerConnection>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(strings.dialogServerTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlController,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: strings.serverUrlLabel,
              hintText: strings.serverUrlHint,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: keyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: strings.anonKeyLabel,
              hintText: strings.anonKeyHint,
              helperText: strings.anonKeyHelper,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(strings.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            (
              url: urlController.text.trim(),
              anonKey: keyController.text.trim()
            ),
          ),
          child: Text(strings.connect),
        ),
      ],
    ),
  );
  if (connection == null) return null;
  await saveGameServerConnection(connection);
  return connection;
}

/// Persists a connection so every cloud feature (rooms, auth, sync) shares it.
Future<void> saveGameServerConnection(GameServerConnection connection) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(gameServerUrlPrefKey, connection.url);
  if (connection.anonKey.isNotEmpty) {
    await prefs.setString(gameServerAnonKeyPrefKey, connection.anonKey);
  }
}

/// The remembered server URL, or '' when none was configured yet.
Future<String> storedGameServerUrl() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(gameServerUrlPrefKey) ?? '';
}
