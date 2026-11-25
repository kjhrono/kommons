import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';
import 'shell_strings.dart' show ShellLanguage;

/// What the player chose in the delete dialog.
enum _DeleteChoice { thisApp, everywhere }

/// The "Delete account" row for settings, shown while an account is signed
/// in. It asks what to delete:
///
///  * **This app only.** The app's [beforeRemove] deletes everything it
///    keeps for the player, then [AccountController.leaveApp] removes the
///    app's purchases and licenses on the server and signs out here. The
///    MediaSart account, mediasart.com and the other apps stay.
///  * **The whole MediaSart account.** That happens on the mediasart.com
///    account page ([AccountController.accountPageUrl]), which this opens.
class ShellDeleteAccountTile extends StatelessWidget {
  const ShellDeleteAccountTile({
    super.key,
    required this.appId,
    this.appName,
    this.beforeRemove,
    this.openUrl,
  });

  /// The app's id on the server (the same one ShellEntitlements uses).
  final String appId;

  /// The app's name in the dialog ("Remove my data from Katalogus").
  final String? appName;

  /// Deletes everything the app keeps for the player (its own database),
  /// run first while the token still opens it. Throwing stops the removal.
  final Future<void> Function()? beforeRemove;

  /// Opens the account page. Defaults to the system browser.
  final Future<bool> Function(Uri url)? openUrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([account, appLocale]),
      builder: (context, _) {
        if (!account.hasSyncedAccount) return const SizedBox.shrink();
        final s = deleteAccountStrings;
        final danger = Theme.of(context).colorScheme.error;
        return Card(
          child: ListTile(
            key: const ValueKey('delete-account'),
            leading: Icon(Icons.delete_forever_outlined, color: danger),
            title: Text(s.title, style: TextStyle(color: danger)),
            subtitle: Text(s.subtitle),
            onTap: () => _start(context),
          ),
        );
      },
    );
  }

  Future<void> _start(BuildContext context) async {
    final s = deleteAccountStrings;
    final name = appName ?? s.thisAppFallback;
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const ValueKey('delete-account-choice'),
        title: Text(s.choiceTitle),
        children: [
          SimpleDialogOption(
            key: const ValueKey('delete-choice-app'),
            onPressed: () =>
                Navigator.pop(dialogContext, _DeleteChoice.thisApp),
            child: ListTile(
              leading: const Icon(Icons.phonelink_erase_outlined),
              title: Text(s.thisAppTitle(name)),
              subtitle: Text(s.thisAppBody),
            ),
          ),
          SimpleDialogOption(
            key: const ValueKey('delete-choice-everywhere'),
            onPressed: () =>
                Navigator.pop(dialogContext, _DeleteChoice.everywhere),
            child: ListTile(
              leading: const Icon(Icons.public_off_outlined),
              title: Text(s.everywhereTitle),
              subtitle: Text(s.everywhereBody),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case _DeleteChoice.thisApp:
        await _removeFromApp(context, name);
      case _DeleteChoice.everywhere:
        final url = account
            .accountPageUrl((appLocale.value ?? ShellLanguage.english).code);
        final opener = openUrl ??
            (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
        await opener(url);
    }
  }

  Future<void> _removeFromApp(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = deleteAccountStrings;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDeleteDialog(appName: name),
    );
    if (confirmed != true) return;
    try {
      await beforeRemove?.call();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(s.appDataFailed)));
      return;
    }
    final result = await account.leaveApp(appId);
    messenger.showSnackBar(SnackBar(
      content: Text(switch (result) {
        ShellDeleteResult.deleted => s.removed(name),
        ShellDeleteResult.offline => s.offline,
        ShellDeleteResult.notSignedIn || ShellDeleteResult.failed => s.failed,
      }),
    ));
  }
}

class _ConfirmDeleteDialog extends StatefulWidget {
  const _ConfirmDeleteDialog({required this.appName});

  final String appName;

  @override
  State<_ConfirmDeleteDialog> createState() => _ConfirmDeleteDialogState();
}

class _ConfirmDeleteDialogState extends State<_ConfirmDeleteDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = deleteAccountStrings;
    final ready = _typed.text.trim().toUpperCase() == s.confirmWord;
    return AlertDialog(
      key: const ValueKey('delete-account-dialog'),
      title: Text(s.thisAppTitle(widget.appName)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.confirmBody(widget.appName)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('delete-account-confirm-field'),
            controller: _typed,
            decoration: InputDecoration(labelText: s.typeToConfirm),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('delete-account-confirm'),
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError),
          onPressed: ready ? () => Navigator.pop(context, true) : null,
          child: Text(s.delete),
        ),
      ],
    );
  }
}

class DeleteAccountStrings {
  const DeleteAccountStrings.english()
      : title = 'Delete account',
        subtitle = 'From this app, or your whole MediaSart account.',
        choiceTitle = 'What do you want to delete?',
        thisAppFallback = 'this app',
        _thisAppTitle = 'Remove my data from',
        thisAppBody =
            'Everything this app keeps for you is deleted, including its purchases, and you are signed out here. Your MediaSart account, mediasart.com and the other apps stay.',
        everywhereTitle = 'Delete my MediaSart account',
        everywhereBody =
            'Deletes the account on mediasart.com and in every app. Continues on mediasart.com.',
        _confirmBody = 'This deletes all your data in',
        _confirmTail = 'and cannot be undone.',
        confirmWord = 'DELETE',
        typeToConfirm = 'Type DELETE to confirm',
        delete = 'Delete',
        _removed = 'Your data was removed from',
        offline = 'Connect to the internet to do this.',
        failed = 'Could not delete. Try again later.',
        appDataFailed =
            'Could not remove this app’s data. Nothing was deleted.';

  const DeleteAccountStrings.italian()
      : title = 'Elimina account',
        subtitle = 'Da questa app, o tutto il tuo account MediaSart.',
        choiceTitle = 'Cosa vuoi eliminare?',
        thisAppFallback = 'questa app',
        _thisAppTitle = 'Rimuovi i miei dati da',
        thisAppBody =
            'Tutto ciò che questa app conserva per te viene eliminato, compresi i suoi acquisti, e l’accesso qui termina. Il tuo account MediaSart, mediasart.com e le altre app restano.',
        everywhereTitle = 'Elimina il mio account MediaSart',
        everywhereBody =
            'Elimina l’account su mediasart.com e in tutte le app. Si continua su mediasart.com.',
        _confirmBody = 'Questo elimina tutti i tuoi dati in',
        _confirmTail = 'e non si può annullare.',
        confirmWord = 'ELIMINA',
        typeToConfirm = 'Scrivi ELIMINA per confermare',
        delete = 'Elimina',
        _removed = 'I tuoi dati sono stati rimossi da',
        offline = 'Collegati a internet per farlo.',
        failed = 'Impossibile eliminare. Riprova più tardi.',
        appDataFailed =
            'Impossibile rimuovere i dati di questa app. Non è stato eliminato nulla.';

  final String title;
  final String subtitle;
  final String choiceTitle;
  final String thisAppFallback;
  final String _thisAppTitle;
  final String thisAppBody;
  final String everywhereTitle;
  final String everywhereBody;
  final String _confirmBody;
  final String _confirmTail;
  final String confirmWord;
  final String typeToConfirm;
  final String delete;
  final String _removed;
  final String offline;
  final String failed;
  final String appDataFailed;

  String thisAppTitle(String app) => '$_thisAppTitle $app';
  String confirmBody(String app) => '$_confirmBody $app $_confirmTail';
  String removed(String app) => '$_removed $app.';
}

const _english = DeleteAccountStrings.english();
const _italian = DeleteAccountStrings.italian();

DeleteAccountStrings get deleteAccountStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
