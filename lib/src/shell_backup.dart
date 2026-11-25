import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'shell_inks.dart';
import 'shell_strings.dart' show ShellLanguage;

// -----------------------------------------------------------------------------
// Backup export / import. Each app knows its own data; the shell owns the
// file: a JSON envelope with the app id, the data's schema version, the date
// and a SHA-256 checksum, optionally encrypted with a password (PBKDF2 +
// AES-256-GCM). Import refuses another app's backup, a newer schema and a
// damaged file, and asks before replacing anything.
//
// Premium licenses never go in a backup: the app exports only its own data,
// and a license only works on the phone it was issued to anyway.
// -----------------------------------------------------------------------------

/// What an app plugs into the backup card.
abstract class ShellBackupSource {
  /// The app's id, written in the file and checked on import.
  String get appId;

  /// The version of the exported data's shape. Bump it when the shape
  /// changes; [importData] receives the file's version to migrate from.
  int get schemaVersion;

  /// Everything to back up, as JSON-encodable data.
  Future<Map<String, dynamic>> exportData();

  /// Replaces this device's data with [data] (exported at [fromVersion],
  /// never newer than [schemaVersion]).
  Future<void> importData(Map<String, dynamic> data, int fromVersion);
}

/// Why a backup file was refused.
enum ShellBackupError {
  /// Not a backup file, or damaged (bad JSON, failed checksum).
  corrupt,

  /// A backup of another app.
  wrongApp,

  /// Made by a newer version of the app: update first.
  newerVersion,

  /// Encrypted, and the password does not open it.
  wrongPassword,
}

class ShellBackupException implements Exception {
  const ShellBackupException(this.error);
  final ShellBackupError error;

  @override
  String toString() => 'ShellBackupException(${error.name})';
}

/// A decoded backup, before it is applied.
@immutable
class ShellBackupFile {
  const ShellBackupFile({
    required this.appId,
    required this.schemaVersion,
    required this.createdAt,
    required this.encrypted,
    this.data,
  });

  final String appId;
  final int schemaVersion;
  final DateTime createdAt;
  final bool encrypted;

  /// The data; null until an encrypted file is opened with its password.
  final Map<String, dynamic>? data;
}

const _format = 'kommons-backup';
const _formatVersion = 1;

/// PBKDF2 rounds for new encrypted backups (stored in the file, so it can
/// change without breaking old backups).
const shellBackupKdfIterations = 120000;

/// Builds the backup file for [source]. With a non-empty [password] the data
/// is encrypted.
Future<Uint8List> encodeShellBackup(
  ShellBackupSource source, {
  String? password,
  DateTime? now,
  int iterations = shellBackupKdfIterations,
}) async {
  final payload = jsonEncode(await source.exportData());
  final envelope = <String, dynamic>{
    'format': _format,
    'v': _formatVersion,
    'app': source.appId,
    'schema': source.schemaVersion,
    'created': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'checksum': hash.sha256.convert(utf8.encode(payload)).toString(),
  };
  if (password == null || password.isEmpty) {
    envelope['encrypted'] = false;
    envelope['payload'] = payload;
  } else {
    final salt = SecretKeyData.random(length: 16).bytes;
    final key = await _deriveKey(password, salt, iterations);
    final box = await AesGcm.with256bits()
        .encrypt(utf8.encode(payload), secretKey: key);
    envelope['encrypted'] = true;
    envelope['kdf'] = {
      'alg': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64.encode(salt),
    };
    envelope['cipher'] = {
      'alg': 'aes-256-gcm',
      'nonce': base64.encode(box.nonce),
      'mac': base64.encode(box.mac.bytes),
    };
    envelope['payload'] = base64.encode(box.cipherText);
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
}

Future<SecretKey> _deriveKey(String password, List<int> salt, int iterations) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);

/// Reads a backup file for [source]. Without [password] an encrypted file
/// comes back with null [ShellBackupFile.data] (so the UI can show what it
/// is and ask); with a wrong one it throws [ShellBackupError.wrongPassword].
Future<ShellBackupFile> decodeShellBackup(
  Uint8List bytes,
  ShellBackupSource source, {
  String? password,
}) async {
  const corrupt = ShellBackupException(ShellBackupError.corrupt);
  final Map<String, dynamic> envelope;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) throw corrupt;
    envelope = decoded;
  } catch (_) {
    throw corrupt;
  }
  if (envelope['format'] != _format || envelope['v'] is! int) throw corrupt;
  final app = envelope['app'];
  final schema = envelope['schema'];
  final created = DateTime.tryParse('${envelope['created']}');
  final payload = envelope['payload'];
  if (app is! String ||
      schema is! int ||
      created == null ||
      payload is! String) {
    throw corrupt;
  }
  if (app != source.appId) {
    throw const ShellBackupException(ShellBackupError.wrongApp);
  }
  if (schema > source.schemaVersion ||
      (envelope['v'] as int) > _formatVersion) {
    throw const ShellBackupException(ShellBackupError.newerVersion);
  }
  final encrypted = envelope['encrypted'] == true;
  ShellBackupFile file(Map<String, dynamic>? data) => ShellBackupFile(
        appId: app,
        schemaVersion: schema,
        createdAt: created,
        encrypted: encrypted,
        data: data,
      );

  String clear;
  if (encrypted) {
    if (password == null || password.isEmpty) return file(null);
    try {
      final kdf = envelope['kdf'] as Map;
      final cipher = envelope['cipher'] as Map;
      final key = await _deriveKey(password,
          base64.decode(kdf['salt'] as String), kdf['iterations'] as int);
      final opened = await AesGcm.with256bits().decrypt(
        SecretBox(base64.decode(payload),
            nonce: base64.decode(cipher['nonce'] as String),
            mac: Mac(base64.decode(cipher['mac'] as String))),
        secretKey: key,
      );
      clear = utf8.decode(opened);
    } on SecretBoxAuthenticationError {
      throw const ShellBackupException(ShellBackupError.wrongPassword);
    } catch (_) {
      throw corrupt;
    }
  } else {
    clear = payload;
  }
  if (hash.sha256.convert(utf8.encode(clear)).toString() !=
      envelope['checksum']) {
    throw corrupt;
  }
  final data = jsonDecode(clear);
  if (data is! Map<String, dynamic>) throw corrupt;
  return file(data);
}

/// Saving and picking files. The default uses file_picker (a save dialog
/// or download, and the system file picker); tests inject their own.
class ShellBackupFiles {
  const ShellBackupFiles();

  /// Saves [bytes] as [fileName]. False when the player cancelled.
  Future<bool> save(String fileName, Uint8List bytes) async {
    final path = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    // The web downloads without returning a path; elsewhere null means
    // the player cancelled.
    return path != null || kIsWeb;
  }

  /// Lets the player pick a backup file. Null when cancelled.
  Future<Uint8List?> pick() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    return result?.files.single.bytes;
  }
}

/// The settings card: export (optionally with a password) and import (with
/// a confirmation before anything is replaced).
class ShellBackupCard extends StatefulWidget {
  const ShellBackupCard({
    super.key,
    required this.source,
    this.files = const ShellBackupFiles(),
    this.kdfIterations = shellBackupKdfIterations,
  });

  final ShellBackupSource source;
  final ShellBackupFiles files;

  /// PBKDF2 rounds (tests lower it).
  final int kdfIterations;

  @override
  State<ShellBackupCard> createState() => _ShellBackupCardState();
}

class _ShellBackupCardState extends State<ShellBackupCard> {
  bool _busy = false;
  String? _message;
  bool _error = false;

  void _say(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
      _error = error;
    });
  }

  Future<void> _export() async {
    final s = shellBackupStrings;
    final password = await _askPassword(context, s.exportPasswordTitle,
        hint: s.exportPasswordHint, optional: true);
    if (password == null) return; // cancelled
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await encodeShellBackup(widget.source,
          password: password, iterations: widget.kdfIterations);
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await widget.files
          .save('${widget.source.appId}-backup-$date.json', bytes);
      _say(saved ? s.exported : s.cancelled);
    } catch (_) {
      _say(s.exportFailed, error: true);
    }
  }

  Future<void> _import() async {
    final s = shellBackupStrings;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await widget.files.pick();
      if (bytes == null) return _say(s.cancelled);
      var file = await decodeShellBackup(bytes, widget.source);
      if (file.data == null) {
        if (!mounted) return;
        final password = await _askPassword(context, s.importPasswordTitle);
        if (password == null || password.isEmpty) return _say(s.cancelled);
        file =
            await decodeShellBackup(bytes, widget.source, password: password);
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('backup-confirm'),
          title: Text(s.confirmTitle),
          content: Text(s.confirmBody(MaterialLocalizations.of(dialogContext)
              .formatMediumDate(file.createdAt.toLocal()))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(
                    MaterialLocalizations.of(dialogContext).cancelButtonLabel)),
            FilledButton(
                key: const ValueKey('backup-confirm-replace'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(s.replace)),
          ],
        ),
      );
      if (ok != true) return _say(s.cancelled);
      await widget.source.importData(file.data!, file.schemaVersion);
      _say(s.imported);
    } on ShellBackupException catch (e) {
      _say(s.errorText(e.error), error: true);
    } catch (_) {
      _say(s.importFailed, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appLocale,
      builder: (context, _) {
        final s = shellBackupStrings;
        return Card(
          key: const ValueKey('backup-card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.save_alt),
                  const SizedBox(width: 8),
                  Text(s.title, style: Theme.of(context).textTheme.titleSmall),
                ]),
                const SizedBox(height: 4),
                Text(s.hint, style: TextStyle(color: scheme.mutedInk)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    key: const ValueKey('backup-export'),
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.upload_file),
                    label: Text(s.export),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('backup-import'),
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.download),
                    label: Text(s.import),
                  ),
                ]),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(_message!,
                      key: const ValueKey('backup-message'),
                      style: TextStyle(
                          color: _error ? scheme.dangerInk : scheme.mutedInk)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A password prompt. Returns null when cancelled; with [optional] an
/// empty answer means "no password".
Future<String?> _askPassword(BuildContext context, String title,
    {String? hint, bool optional = false}) {
  final controller = TextEditingController();
  final s = shellBackupStrings;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('backup-password-dialog'),
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (hint != null) Text(hint),
        TextField(
          key: const ValueKey('backup-password'),
          controller: controller,
          obscureText: true,
          decoration: InputDecoration(labelText: s.password),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel)),
        FilledButton(
          key: const ValueKey('backup-password-ok'),
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: Text(optional ? s.continueLabel : s.open),
        ),
      ],
    ),
  );
}

class ShellBackupStrings {
  const ShellBackupStrings.english()
      : title = 'Backup',
        hint = 'Save your data to a file, or restore it from one.',
        export = 'Export backup',
        import = 'Import backup',
        exportPasswordTitle = 'Protect the backup?',
        exportPasswordHint =
            'Enter a password to encrypt the file, or leave it empty. Without the password the file cannot be restored.',
        importPasswordTitle = 'This backup has a password',
        password = 'Password',
        continueLabel = 'Continue',
        open = 'Open',
        confirmTitle = 'Replace your data?',
        _confirmBody =
            'The data on this device will be replaced by the backup from',
        replace = 'Replace',
        exported = 'Backup saved.',
        imported = 'Backup restored.',
        cancelled = 'Nothing changed.',
        exportFailed = 'Could not create the backup.',
        importFailed = 'Could not restore the backup.',
        corrupt = 'This file is not a backup, or it is damaged.',
        wrongApp = 'This is a backup of another app.',
        newerVersion =
            'This backup comes from a newer version. Update the app first.',
        wrongPassword = 'Wrong password.';

  const ShellBackupStrings.italian()
      : title = 'Backup',
        hint = 'Salva i tuoi dati in un file, o ripristinali da un file.',
        export = 'Esporta backup',
        import = 'Importa backup',
        exportPasswordTitle = 'Proteggere il backup?',
        exportPasswordHint =
            'Inserisci una password per cifrare il file, oppure lasciala vuota. Senza la password il file non si potrà ripristinare.',
        importPasswordTitle = 'Questo backup ha una password',
        password = 'Password',
        continueLabel = 'Continua',
        open = 'Apri',
        confirmTitle = 'Sostituire i tuoi dati?',
        _confirmBody =
            'I dati su questo dispositivo saranno sostituiti dal backup del',
        replace = 'Sostituisci',
        exported = 'Backup salvato.',
        imported = 'Backup ripristinato.',
        cancelled = 'Nessuna modifica.',
        exportFailed = 'Impossibile creare il backup.',
        importFailed = 'Impossibile ripristinare il backup.',
        corrupt = 'Questo file non è un backup, oppure è danneggiato.',
        wrongApp = 'Questo è il backup di un’altra app.',
        newerVersion =
            'Questo backup viene da una versione più recente. Aggiorna prima l’app.',
        wrongPassword = 'Password errata.';

  final String title;
  final String hint;
  final String export;
  final String import;
  final String exportPasswordTitle;
  final String exportPasswordHint;
  final String importPasswordTitle;
  final String password;
  final String continueLabel;
  final String open;
  final String confirmTitle;
  final String _confirmBody;
  final String replace;
  final String exported;
  final String imported;
  final String cancelled;
  final String exportFailed;
  final String importFailed;
  final String corrupt;
  final String wrongApp;
  final String newerVersion;
  final String wrongPassword;

  String confirmBody(String date) => '$_confirmBody $date.';

  String errorText(ShellBackupError error) => switch (error) {
        ShellBackupError.corrupt => corrupt,
        ShellBackupError.wrongApp => wrongApp,
        ShellBackupError.newerVersion => newerVersion,
        ShellBackupError.wrongPassword => wrongPassword,
      };
}

const _english = ShellBackupStrings.english();
const _italian = ShellBackupStrings.italian();

ShellBackupStrings get shellBackupStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
