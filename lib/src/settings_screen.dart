import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'auth_service.dart';

/// A handler an app registers for an OAuth provider button ('google',
/// 'github', …). The shell renders the button and calls this on tap; the
/// provider flow itself (client IDs, redirects, server config) belongs to
/// the hosting app.
typedef OAuthProviderHandler = Future<void> Function();

/// Lets a hosting app wire the "connect your server" affordance inside the
/// account card: the shell asks [isConfigured] once on mount and shows the
/// hint + connect button until it answers true; [showConnectionDialog]
/// opens the app's own connection UI and reports whether a server ended up
/// configured (false/null = cancelled).
class ServerConnectionSetup {
  const ServerConnectionSetup({required this.isConfigured, required this.showConnectionDialog});

  final Future<bool> Function() isConfigured;
  final Future<bool> Function(BuildContext context) showConnectionDialog;
}

/// The shared settings screen, hosted by the top bar's gear. Sections:
///
///  * Account — sign in with an email (cloud registration on the game
///    server, or a device-local record), plus provider buttons enabled by
///    the app's [SettingsScreen.oauthProviders], or sign out. The address
///    is what a cloud save service will key shared games by.
///  * Player name — how the realm addresses you while anonymous (and the
///    display name of an email account).
///  * Language — a placeholder with the picker ready for translations.
///
/// Games append their own cards below these through [SettingsScreen.extraSections]
/// and wire server onboarding through [SettingsScreen.serverSetup] — the
/// shell itself never opens an app-specific dialog.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.gameId = 'app',
    this.extraSections = const <Widget>[],
    this.oauthProviders = const <String, OAuthProviderHandler>{},
    this.serverSetup,
  });

  /// Which game is hosting the screen. Tags the route so games can share
  /// the account/options plumbing while extending their own.
  final String gameId;

  /// Game-specific section cards, rendered below the shared ones (before
  /// the footer note).
  final List<Widget> extraSections;

  /// Provider handlers keyed by provider id ('google', 'github', …). A
  /// provider without a handler renders its button disabled.
  final Map<String, OAuthProviderHandler> oauthProviders;

  /// The app's server-connection onboarding, shown inside the account card
  /// while no game server is configured. Omitted on hosts that onboard
  /// elsewhere (cloud sign-in then explains itself through its error).
  final ServerConnectionSetup? serverSetup;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  String? _emailError;
  bool _cloudBusy = false;

  /// Whether a game-server connection is configured. Checked on init and
  /// after the app's connect dialog returns, so the cloud button can
  /// explain itself (and retry) before asking the player to host a room
  /// first.
  bool _serverConfigured = false;

  /// A registration awaiting its email confirmation (mirrors the account
  /// controller's parked signup; the mirror updates in setState paths).
  String? _pendingSignupEmail;
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _emailController.text = account.value?.email ?? '';
    _nameController.text = account.playerName;
    widget.serverSetup?.isConfigured().then((configured) {
      if (mounted) setState(() => _serverConfigured = configured);
    });
    if (account.isLoaded) {
      _pendingSignupEmail = account.pendingSignupEmail;
      if (_pendingSignupEmail != null) _emailController.text = _pendingSignupEmail!;
    } else {
      account.load().then((_) {
        if (!mounted) return;
        final pending = account.pendingSignupEmail;
        if (pending != null) {
          setState(() {
            _pendingSignupEmail = pending;
            _emailController.text = pending;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool _providerEnabled(String id) => widget.oauthProviders.containsKey(id);

  /// Runs a provider flow the hosting app registered. Errors surface as a
  /// snackbar; success simply re-renders (the account notifier already
  /// carries the signed-in state).
  Future<void> _runProvider(String id) async {
    final handler = widget.oauthProviders[id];
    if (handler == null) return;
    try {
      await handler();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account_ = account.value;
    return Scaffold(
      appBar: AppBar(title: const Text('SETTINGS')),
      body: ListView(
          key: const ValueKey('settings-list'),
          padding: const EdgeInsets.all(16),
          children: [
        // -- Account -------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.person_outline),
                const SizedBox(width: 8),
                const Text('ACCOUNT', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                const Spacer(),
                Text(
                  account_ == null ? 'Guest' : account_.provider,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ]),
              const SizedBox(height: 12),
              if (_pendingSignupEmail != null) ...[
                // -- Awaiting email confirmation ---------------------------------
                Row(children: [
                  const Icon(Icons.mark_email_unread_outlined, color: Colors.amber),
                  const SizedBox(width: 8),
                  const Text('CHECK YOUR INBOX', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ]),
                const SizedBox(height: 8),
                Text(
                  'We sent a confirmation to $_pendingSignupEmail. Enter the code from the email — or open its link — to finish registering.',
                  style: TextStyle(color: Colors.grey.shade400),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('verification-code-field'),
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Verification code',
                    hintText: 'the 6 digits from the email',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _verifyCode(),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.icon(
                    key: const ValueKey('verify-code'),
                    onPressed: _cloudBusy ? null : _verifyCode,
                    icon: _cloudBusy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.verified_outlined),
                    label: const Text('Confirm'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('resend-confirmation'),
                    onPressed: _cloudBusy ? null : _resendConfirmation,
                    child: const Text('Resend email'),
                  ),
                ]),
                TextButton(
                  key: const ValueKey('cancel-pending'),
                  onPressed: _cancelPendingSignup,
                  child: const Text('Use a different address'),
                ),
              ] else if (account_ == null) ...[
                Text('Sign in to keep your name, saves and shared games on the cloud. Email comes first; other providers can join later.',
                    style: TextStyle(color: Colors.grey.shade400)),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('email-field'),
                  controller: _emailController,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'you@example.com',
                    errorText: _emailError,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('password-field'),
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (cloud account)',
                    hintText: '6+ characters — registers on first use',
                    border: OutlineInputBorder(),
                  ),
                  autofillHints: const [AutofillHints.password],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.icon(
                    key: const ValueKey('email-signin'),
                    onPressed: _signIn,
                    icon: const Icon(Icons.mail_outline),
                    label: const Text('Sign in with email'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('oauth-google'),
                    onPressed: _providerEnabled('google') ? () => _runProvider('google') : null,
                    child: const Text('Google'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('oauth-github'),
                    onPressed: _providerEnabled('github') ? () => _runProvider('github') : null,
                    child: const Text('GitHub'),
                  ),
                ]),
                if (!_serverConfigured && widget.serverSetup != null) ...[
                  const SizedBox(height: 8),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.dns_outlined, size: 16, color: Colors.amber.shade300),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Cloud accounts register on your game server — connect once below (the same connection online multiplayer uses).',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('connect-server'),
                    onPressed: () async {
                      final configured = await widget.serverSetup!.showConnectionDialog(context);
                      if (configured && mounted) setState(() => _serverConfigured = true);
                    },
                    icon: const Icon(Icons.lan_outlined),
                    label: const Text('Connect game server'),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('cloud-signin'),
                    onPressed: _cloudBusy ? null : _cloudSignIn,
                    icon: _cloudBusy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_outlined),
                    label: const Text('Create / sign in to cloud account'),
                  ),
                ),
              ] else ...[
                Text('Signed in as ${account_.email}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  account.isCloudSignedIn
                      ? 'Cloud account — verified by your game server, ready for cloud saves.'
                      : 'Remembered on this device only. Add a password above for a cloud account.',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('signout'),
                  // signOut is async (prefs write + best-effort server call)
                  // but its notifier update is synchronous — call it outside
                  // setState; wrapping it inside would return a Future from
                  // the callback and throw.
                  onPressed: () {
                    account.signOut();
                    setState(() {});
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ]),
          ),
        ),
        // -- Player name ---------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.badge_outlined),
                const SizedBox(width: 8),
                const Text('PLAYER NAME', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              ]),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('player-name-field'),
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'How the realm addresses you',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: _saveName,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('save-name'),
                onPressed: () => _saveName(_nameController.text),
                icon: const Icon(Icons.check),
                label: const Text('Save name'),
              ),
            ]),
          ),
        ),
        // -- Language ------------------------------------------------------
        Card(
          child: ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('Language'),
            subtitle: const Text('English — more languages coming'),
            key: const ValueKey('language-tile'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {}, // translations land here
          ),
        ),
        // -- Game sections ---------------------------------------------------
        ...widget.extraSections,
        Text(
          'Settings are stored on this device. Signing in prepares them for cloud sync.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
        ),
      ]),
    );
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
    if (!valid) {
      setState(() => _emailError = 'Enter a valid email address');
      return;
    }
    setState(() {
      _emailError = null;
      account.signInWithEmail(email);
    });
  }

  /// Cloud round-trip: registers the account on the game server on first
  /// use, verifies the password after that, and persists the session.
  /// Errors surface inline (validation) or as a snackbar (server answers).
  /// When no server connection exists yet and the app offers one, the
  /// connect dialog opens once and the attempt retries immediately — a
  /// fresh player can register straight from settings without visiting
  /// multiplayer first.
  Future<void> _cloudSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _emailError = 'Enter a valid email address');
      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a password of at least 6 characters.')),
      );
      return;
    }
    if (!_serverConfigured && widget.serverSetup != null) {
      final configured = await widget.serverSetup!.showConnectionDialog(context);
      if (!mounted) return;
      if (!configured) return; // player cancelled
      setState(() => _serverConfigured = true);
    }
    setState(() {
      _emailError = null;
      _cloudBusy = true;
    });
    try {
      await account.signInWithPassword(email, password);
      if (mounted) setState(() {});
    } on AuthException catch (error) {
      if (!mounted) return;
      // The server registered the address but withheld the session until
      // the confirmation email is verified — switch to the inbox flow.
      if (error.code == 'email_not_confirmed') {
        await account.parkPendingSignup(email);
        setState(() => _pendingSignupEmail = email);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// Confirms the parked registration with the emailed code (or link token).
  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the code from the email.')));
      return;
    }
    setState(() => _cloudBusy = true);
    try {
      await account.confirmSignupCode(code);
      if (mounted) {
        setState(() {
          _pendingSignupEmail = null;
          _codeController.clear();
        });
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// Re-sends the confirmation email for the parked registration.
  Future<void> _resendConfirmation() async {
    try {
      await account.resendSignupConfirmation();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Confirmation email sent again.')));
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  /// Abandons the parked registration — back to the sign-in form.
  Future<void> _cancelPendingSignup() async {
    await account.cancelPendingSignup();
    if (mounted) {
      setState(() {
        _pendingSignupEmail = null;
        _codeController.clear();
      });
    }
  }

  Future<void> _saveName(String name) async {
    await account.setPlayerName(name);
    if (mounted) setState(() {});
  }
}
