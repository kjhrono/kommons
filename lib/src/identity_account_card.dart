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
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('account-sign-out'),
                  icon: const Icon(Icons.logout, size: 18),
                  label: Text(s.signOut),
                  onPressed: host.signOut,
                ),
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
        googleFailedPrefix = 'Google sign-in failed';

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
        googleFailedPrefix = 'Accesso con Google non riuscito';

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
