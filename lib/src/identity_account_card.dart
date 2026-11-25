import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mediasart_auth_client/mediasart_auth_client.dart' as kit;

import 'app_settings.dart' show appLocale;
import 'oauth_popup_launcher.dart' show collectOAuthCode;
import 'shell_inks.dart';
import 'shell_strings.dart' show ShellLanguage;

// -----------------------------------------------------------------------------
// The MediaSart identity account card: who is signed in, with which methods
// (email, Google — one account can carry both), and the doors to sign in, add
// Google to an email account, and sign out. Any app on the shared identity
// stack (auth.mediasart.com) drops it into its settings and implements a small
// [IdentityAccountHost]; see docs/IDENTITY_ACCOUNT_CARD.md.
// -----------------------------------------------------------------------------

/// How an identity session signs in. An account can carry several;
/// [anonymous] means no account at all.
enum IdentitySignInKind { anonymous, email, google }

/// The icon each method is drawn with on the card.
IconData identitySignInKindIcon(IdentitySignInKind kind) => switch (kind) {
      IdentitySignInKind.anonymous => Icons.no_accounts_outlined,
      IdentitySignInKind.email => Icons.mail_outline,
      IdentitySignInKind.google => Icons.g_mobiledata,
    };

/// The signed-in account as the card shows it: its email and the methods
/// linked to it.
class IdentityAccountInfo {
  const IdentityAccountInfo({required this.email, required this.kinds});

  static const anonymous = IdentityAccountInfo(
    email: null,
    kinds: {IdentitySignInKind.anonymous},
  );

  final String? email;
  final Set<IdentitySignInKind> kinds;

  bool get signedIn => !kinds.contains(IdentitySignInKind.anonymous);

  /// Reads the methods out of the session's JWT (`app_metadata.providers`,
  /// falling back to `app_metadata.provider`). An unreadable token still
  /// belongs to a signed-in account, shown as email.
  factory IdentityAccountInfo.fromSession(kit.AuthSession? session) {
    if (session == null) return anonymous;
    final kinds = <IdentitySignInKind>{};
    try {
      final part = session.accessToken.split('.')[1];
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(part))),
      ) as Map<String, dynamic>;
      final meta = (claims['app_metadata'] as Map?) ?? const {};
      final providers = <String>{
        ...((meta['providers'] as List?) ?? const []).map((p) => '$p'),
        if (meta['provider'] is String) meta['provider'] as String,
      };
      if (providers.contains('google')) kinds.add(IdentitySignInKind.google);
      if (providers.contains('email')) kinds.add(IdentitySignInKind.email);
    } catch (_) {
      // Unreadable: fall through to email below.
    }
    if (kinds.isEmpty) kinds.add(IdentitySignInKind.email);
    return IdentityAccountInfo(email: session.email, kinds: kinds);
  }
}

/// The claims of an identity session's access token (empty when absent or
/// unreadable). Read only, never verified: the stack minted the token, and
/// the app grants nothing on its own from these.
Map<String, dynamic> identityClaims(kit.AuthSession? session) =>
    session == null ? const {} : decodeJwtClaims(session.accessToken);

/// The payload claims of any JWT, unverified (empty when unreadable).
Map<String, dynamic> decodeJwtClaims(String token) {
  try {
    final part = token.split('.')[1];
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(part))),
    );
    if (claims is Map) return claims.map((k, v) => MapEntry('$k', v));
  } catch (_) {}
  return const {};
}

/// The session's `user_metadata` claim: name, Google photo, the synced
/// `kommons` preferences (as of when the token was issued).
Map<String, dynamic> identityUserMetadata(kit.AuthSession? session) {
  final meta = identityClaims(session)['user_metadata'];
  return meta is Map ? meta.map((k, v) => MapEntry('$k', v)) : const {};
}

/// What the card needs from the app hosting it. The app owns where the
/// session lives; the card owns the flows.
abstract class IdentityAccountHost {
  /// The identity client (`MediasartAuth` pointed at auth.mediasart.com).
  kit.MediasartAuth get auth;

  /// Where Google sends the browser back: the app's web origin (hash form
  /// for hash-routed apps) on the web, its custom scheme on Android/iOS.
  /// Must be in the identity stack's `ADDITIONAL_REDIRECT_URLS`.
  String get oauthRedirectTo;

  /// The password-reset link target the registration flow mails.
  String get resetRedirectTo;

  /// The session the app currently holds, or null when signed out.
  kit.AuthSession? get currentSession;

  /// Fires whenever [currentSession] changes (sign-in, refresh, sign-out).
  Stream<Object?> get sessionChanges;

  /// Makes [session] the app's session (store it, stamp it on requests).
  Future<void> adoptSession(kit.AuthSession session);

  /// Signs out of the app.
  Future<void> signOut();

  /// Whether the Google row offers its button (apps ship it behind a flag
  /// until the identity stack's provider is configured).
  bool get googleEnabled => true;

  /// Runs before any flow touches the network (e.g. start a cloud client).
  Future<void> prepare() async {}

  /// Runs after a NEW sign-in (not after linking), with the card's context
  /// (e.g. offer to sync local data with the account).
  Future<void> afterSignIn(BuildContext context) async {}

  /// Opens the authorize URL and returns the `code` the redirect carries.
  /// Defaults to kommons' platform collector (web popup / app link).
  Future<String?> collectCode(String authorizeUrl) =>
      collectOAuthCode(authorizeUrl);
}

/// Google sign-in over the identity stack's PKCE flow: builds the authorize
/// URL with an S256 challenge, collects the redirect's code and exchanges
/// it. Returns the Google session, or null when the member backed out.
Future<kit.AuthSession?> collectGoogleSession(IdentityAccountHost host) async {
  final verifier = kit.generateCodeVerifier();
  final url = host.auth.googleOAuthUrl(
    redirectTo: host.oauthRedirectTo,
    codeChallenge: kit.generateCodeChallenge(verifier),
  );
  final code = await host.collectCode(url);
  if (code == null) return null;
  return host.auth.signInWithGoogleCode(
    code: code,
    codeVerifier: verifier,
    redirectTo: host.oauthRedirectTo,
  );
}

/// The outcome of [signInOrLinkGoogle].
enum GoogleAccountResult { cancelled, signedIn, linked }

/// The Google row's action. Signed out: signs in with Google. Signed in
/// with email: moves the Google identity onto THIS account (proof: the
/// current session plus Google consent on the same address) and refreshes
/// the session so it lists Google — never a second, separate account.
Future<GoogleAccountResult> signInOrLinkGoogle(
  IdentityAccountHost host,
) async {
  await host.prepare();
  final current = host.currentSession;
  final google = await collectGoogleSession(host);
  if (google == null) return GoogleAccountResult.cancelled;
  if (current == null) {
    await host.adoptSession(google);
    return GoogleAccountResult.signedIn;
  }
  await host.auth.linkGoogleIdentity(
    passwordSession: current,
    googleUserId: google.userId,
    expectedEmail: google.email,
  );
  await host.adoptSession(await host.auth.refreshSession(session: current));
  return GoogleAccountResult.linked;
}

/// The settings card. Rebuilds on [IdentityAccountHost.sessionChanges].
class IdentityAccountCard extends StatelessWidget {
  const IdentityAccountCard({
    super.key,
    required this.host,
    this.notSignedInText,
    this.createAccountLabel,
  });

  final IdentityAccountHost host;

  /// Under the email row while signed out. Defaults to "Not signed in."
  final String? notSignedInText;

  /// The sign-in dialog's register button. Defaults to "Create account".
  final String? createAccountLabel;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Object?>(
      stream: host.sessionChanges,
      builder: (context, _) => ListenableBuilder(
        listenable: appLocale,
        builder: (context, _) => _card(context),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final s = identityAccountStrings;
    final theme = Theme.of(context);
    final info = IdentityAccountInfo.fromSession(host.currentSession);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    Widget method(
      IdentitySignInKind kind, {
      required Widget trailing,
      Widget? title,
      Widget? subtitle,
    }) =>
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(identitySignInKindIcon(kind)),
          title: title ?? Text(s.kindLabel(kind)),
          subtitle: subtitle,
          trailing: trailing,
        );

    final emailLinked = info.kinds.contains(IdentitySignInKind.email);
    final googleLinked = info.kinds.contains(IdentitySignInKind.google);

    return Card(
      key: const ValueKey('account-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  info.signedIn
                      ? Icons.verified_user_outlined
                      : Icons.no_accounts_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Who is signed in rides the email row itself (the address is
            // the email method's own value), not a line of its own.
            method(
              IdentitySignInKind.email,
              title: Text(
                info.signedIn && (info.email ?? '').isNotEmpty
                    ? info.email!
                    : s.kindLabel(IdentitySignInKind.email),
                key: const ValueKey('account-status'),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: info.signedIn
                  ? null
                  : Text(notSignedInText ?? s.notSignedIn, style: muted),
              trailing: emailLinked
                  ? _Linked(label: s.linked)
                  : info.signedIn
                      ? Text(s.notLinked, style: muted)
                      : FilledButton.tonal(
                          key: const ValueKey('account-sign-in-email'),
                          onPressed: () => showIdentitySignInDialog(
                            context,
                            host,
                            createAccountLabel: createAccountLabel,
                          ),
                          child: Text(s.signIn),
                        ),
            ),
            method(
              IdentitySignInKind.google,
              trailing: googleLinked
                  ? _Linked(label: s.linked)
                  : !host.googleEnabled
                      ? Text(s.googleUnavailable, style: muted)
                      : FilledButton.tonal(
                          key: const ValueKey('account-sign-in-google'),
                          onPressed: () => _google(context),
                          // Signed in already: Google joins THIS account.
                          child: Text(
                            info.signedIn ? s.linkGoogle : s.signInWithGoogle,
                          ),
                        ),
            ),
            if (info.signedIn) ...[
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  // Only accounts with a password have one to change.
                  if (emailLinked)
                    TextButton.icon(
                      key: const ValueKey('account-change-password'),
                      icon: const Icon(Icons.password, size: 18),
                      label: Text(s.changePassword),
                      onPressed: () =>
                          showIdentityChangePasswordDialog(context, host),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('account-sign-out'),
                    icon: const Icon(Icons.logout, size: 18),
                    label: Text(s.signOut),
                    onPressed: host.signOut,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _google(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = identityAccountStrings;
    try {
      final result = await signInOrLinkGoogle(host);
      switch (result) {
        case GoogleAccountResult.cancelled:
          return;
        case GoogleAccountResult.linked:
          messenger.showSnackBar(SnackBar(content: Text(s.googleLinked)));
        case GoogleAccountResult.signedIn:
          if (context.mounted) await host.afterSignIn(context);
      }
    } on kit.AuthBannedException {
      messenger.showSnackBar(SnackBar(content: Text(s.banned)));
    } on kit.AuthCodeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.googleFailed(e.reason))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.googleFailed('$e'))));
    }
  }
}

class _Linked extends StatelessWidget {
  const _Linked({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.readyInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

/// Email + password sign-in, with the kit's registration flow one tap away.
/// On success the host's [IdentityAccountHost.afterSignIn] runs.
Future<void> showIdentitySignInDialog(
  BuildContext context,
  IdentityAccountHost host, {
  String? createAccountLabel,
}) async {
  final signedIn = await showDialog<bool>(
    context: context,
    builder: (_) => _SignInDialog(
      host: host,
      createAccountLabel: createAccountLabel,
    ),
  );
  if (signedIn == true && context.mounted) await host.afterSignIn(context);
}

class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.host, this.createAccountLabel});

  final IdentityAccountHost host;
  final String? createAccountLabel;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final s = identityAccountStrings;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.host.prepare();
      final session = await widget.host.auth.signIn(
        email: _email.text.trim(),
        password: _password.text,
      );
      await widget.host.adoptSession(session);
      if (mounted) Navigator.of(context).pop(true);
    } on kit.AuthBannedException {
      setState(() => _error = s.banned);
    } catch (_) {
      setState(() => _error = s.signInFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _register() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => kit.RegistrationFlow(
          auth: widget.host.auth,
          resetRedirectTo: widget.host.resetRedirectTo,
          onRegistered: widget.host.adoptSession,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = identityAccountStrings;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(s.signIn),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: s.email),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(labelText: s.password),
              onSubmitted: (_) => _busy ? null : _signIn(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(s.cancel),
        ),
        TextButton(
          onPressed: _busy ? null : _register,
          child: Text(widget.createAccountLabel ?? s.createAccount),
        ),
        FilledButton(
          key: const ValueKey('account-sign-in-submit'),
          onPressed: _busy ? null : _signIn,
          child: Text(s.signIn),
        ),
      ],
    );
  }
}

/// The change-password dialog: new password twice, then the identity
/// stack rotates the session (the host adopts the fresh tokens). Returns
/// true when the password changed.
Future<bool> showIdentityChangePasswordDialog(
    BuildContext context, IdentityAccountHost host) async {
  final messenger = ScaffoldMessenger.of(context);
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _ChangePasswordDialog(host: host),
  );
  if (changed == true) {
    messenger.showSnackBar(
        SnackBar(content: Text(identityAccountStrings.passwordChanged)));
  }
  return changed == true;
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.host});

  final IdentityAccountHost host;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = identityAccountStrings;
    if (_password.text != _confirm.text) {
      setState(() => _error = s.passwordsDontMatch);
      return;
    }
    final session = widget.host.currentSession;
    if (session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      kit.AuthSession? fresh;
      await widget.host.auth.changePassword(
        session: session,
        newPassword: _password.text,
        onSessionUpdated: (updated) => fresh = updated,
      );
      if (fresh != null) await widget.host.adoptSession(fresh!);
      if (mounted) Navigator.pop(context, true);
    } on kit.AuthCodeException catch (e) {
      setState(() {
        _busy = false;
        _error = e.reason == 'weak_password' ? s.weakPassword : s.changeFailed;
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _error = s.changeFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = identityAccountStrings;
    return AlertDialog(
      title: Text(s.changePassword),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('account-new-password'),
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(labelText: s.newPassword),
          ),
          TextField(
            key: const ValueKey('account-confirm-password'),
            controller: _confirm,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(labelText: s.confirmPassword),
            onSubmitted: (_) => _busy ? null : _save(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                key: const ValueKey('account-change-password-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(s.cancel),
        ),
        FilledButton(
          key: const ValueKey('account-change-password-save'),
          onPressed: _busy ? null : _save,
          child: Text(s.save),
        ),
      ],
    );
  }
}

/// The card's text, in the app's chosen language ([appLocale]).
class IdentityAccountStrings {
  const IdentityAccountStrings.english()
      : title = 'Account',
        notSignedIn = 'Not signed in.',
        emailMethod = 'Email',
        googleMethod = 'Google',
        anonymousMethod = 'No account',
        signIn = 'Sign in',
        signOut = 'Sign out',
        linked = 'Signed in',
        notLinked = 'Not linked',
        googleUnavailable = 'Not available yet',
        signInWithGoogle = 'Sign in with Google',
        linkGoogle = 'Add Google',
        googleLinked = 'Google added to your account',
        email = 'Email',
        password = 'Password',
        createAccount = 'Create account',
        signInFailed = 'Sign-in failed. Check email and password.',
        banned = 'This account is suspended.',
        cancel = 'Cancel',
        googleFailedPrefix = 'Google sign-in failed',
        changePassword = 'Change password',
        newPassword = 'New password',
        confirmPassword = 'Repeat the new password',
        passwordsDontMatch = 'The two passwords differ.',
        weakPassword = 'Too short or too simple. Try a longer password.',
        changeFailed = 'Could not change the password. Try again.',
        passwordChanged = 'Password changed',
        save = 'Save';

  const IdentityAccountStrings.italian()
      : title = 'Account',
        notSignedIn = 'Non hai effettuato l’accesso.',
        emailMethod = 'Email',
        googleMethod = 'Google',
        anonymousMethod = 'Nessun account',
        signIn = 'Accedi',
        signOut = 'Esci',
        linked = 'Collegato',
        notLinked = 'Non collegato',
        googleUnavailable = 'Non ancora disponibile',
        signInWithGoogle = 'Accedi con Google',
        linkGoogle = 'Aggiungi Google',
        googleLinked = 'Google aggiunto al tuo account',
        email = 'Email',
        password = 'Password',
        createAccount = 'Crea account',
        signInFailed = 'Accesso non riuscito. Controlla email e password.',
        banned = 'Questo account è sospeso.',
        cancel = 'Annulla',
        googleFailedPrefix = 'Accesso con Google non riuscito',
        changePassword = 'Cambia password',
        newPassword = 'Nuova password',
        confirmPassword = 'Ripeti la nuova password',
        passwordsDontMatch = 'Le due password sono diverse.',
        weakPassword = 'Troppo corta o semplice. Prova una password più lunga.',
        changeFailed = 'Impossibile cambiare la password. Riprova.',
        passwordChanged = 'Password cambiata',
        save = 'Salva';

  final String title;
  final String notSignedIn;
  final String emailMethod;
  final String googleMethod;
  final String anonymousMethod;
  final String signIn;
  final String signOut;
  final String linked;
  final String notLinked;
  final String googleUnavailable;
  final String signInWithGoogle;
  final String linkGoogle;
  final String googleLinked;
  final String email;
  final String password;
  final String createAccount;
  final String signInFailed;
  final String banned;
  final String cancel;
  final String googleFailedPrefix;
  final String changePassword;
  final String newPassword;
  final String confirmPassword;
  final String passwordsDontMatch;
  final String weakPassword;
  final String changeFailed;
  final String passwordChanged;
  final String save;

  /// A failed Google step, with the kit's refusal code or the error.
  String googleFailed(String reason) => '$googleFailedPrefix ($reason)';

  String kindLabel(IdentitySignInKind kind) => switch (kind) {
        IdentitySignInKind.anonymous => anonymousMethod,
        IdentitySignInKind.email => emailMethod,
        IdentitySignInKind.google => googleMethod,
      };
}

const _english = IdentityAccountStrings.english();
const _italian = IdentityAccountStrings.italian();

IdentityAccountStrings get identityAccountStrings =>
    appLocale.value == ShellLanguage.italiano ? _italian : _english;
