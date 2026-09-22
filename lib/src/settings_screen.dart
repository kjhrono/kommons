import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'auth_service.dart';
import 'shell_strings.dart';

/// A handler an app registers for an OAuth provider button ('google',
/// 'github', …). The shell renders the button and calls this on tap; the
/// provider flow itself (client IDs, redirects, server config) belongs to
/// the hosting app.
typedef OAuthProviderHandler = Future<void> Function();

/// The reference OAuth wiring for hosts using the shared web flow: maps
/// each provider id ('google', 'github' — anything the game server has
/// configured in its GoTrue/Supabase dashboard) to the account controller's
/// [AccountController.signInWithProvider]. Pass it straight in:
///
/// ```dart
/// SettingsScreen(oauthProviders: oauthPopupHandlers())
/// ```
///
/// Errors surface through the settings screen's snackbar; a dismissed
/// consent screen is a quiet no-op. Hosts running a custom flow (dedicated
/// callback page, a fully hand-rolled deep-link delivery) keep hand-rolling
/// their handlers map instead.
Map<String, OAuthProviderHandler> oauthPopupHandlers({
  List<String> providers = const ['google', 'github'],
}) =>
    {
      for (final provider in providers)
        provider: () => account.signInWithProvider(provider),
    };

/// Lets a hosting app wire the "connect your server" affordance inside the
/// account card: the shell asks [isConfigured] once on mount and shows the
/// hint + connect button until it answers true; [showConnectionDialog]
/// opens the app's own connection UI and reports whether a server ended up
/// configured (false/null = cancelled).
class ServerConnectionSetup {
  const ServerConnectionSetup(
      {required this.isConfigured, required this.showConnectionDialog});

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
///  * Language — the persisted app-wide language ([appLocale]); hosts put it
///    on `MaterialApp.locale` so the shell re-renders in that language.
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
    this.showAccountCard = true,
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

  /// Hosts that handle identity elsewhere (their own auth stack or screen)
  /// hide the shared email/sign-up card entirely; name and language cards
  /// still render, and the host appends its own sections below them.
  final bool showAccountCard;

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

  // -- Password reset + change ----------------------------------------------
  final _resetCodeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _currentPasswordController = TextEditingController();

  /// The address a reset email was sent to (mirrors the account
  /// controller's parked reset; non-null switches the account card to the
  /// reset sub-form).
  String? _resetEmail;

  /// True opens the change-password section on the signed-in card. It
  /// starts open when the player signed in with the server's temporary
  /// password (the forced-change UX) and stays reachable from a link on
  /// the card afterwards.
  bool _showChangePassword = false;

  @override
  void initState() {
    super.initState();
    _emailController.text = account.value?.email ?? '';
    _nameController.text = account.playerName;
    widget.serverSetup?.isConfigured().then((configured) {
      if (mounted) setState(() => _serverConfigured = configured);
    });
    // The splash and the top bar preload the locale; this covers settings
    // as the first screen (deep links, tests). No-op when already loaded.
    unawaited(appLocale.load());
    if (account.isLoaded) {
      _pendingSignupEmail = account.pendingSignupEmail;
      if (_pendingSignupEmail != null) {
        _emailController.text = _pendingSignupEmail!;
      }
      _resetEmail = account.pendingResetEmail;
    } else {
      account.load().then((_) {
        if (!mounted) return;
        final pending = account.pendingSignupEmail;
        final reset = account.pendingResetEmail;
        if (pending == null && reset == null) return;
        setState(() {
          _pendingSignupEmail = pending;
          if (pending != null) _emailController.text = pending;
          _resetEmail = reset;
        });
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _resetCodeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    _currentPasswordController.dispose();
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = appLocale.strings;
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsTitle)),
      body: ListView(
          key: const ValueKey('settings-list'),
          padding: const EdgeInsets.all(16),
          children: [
            // -- Account (host may hide it and own identity elsewhere) ----------
            if (widget.showAccountCard) ...[
              ListenableBuilder(
                listenable: account,
                builder: (context, _) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.person_outline),
                            const SizedBox(width: 8),
                            Text(strings.accountHeader,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2)),
                            const Spacer(),
                            Text(
                              account.value == null
                                  ? strings.guest
                                  : account.value!.provider,
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 12),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          if (_pendingSignupEmail != null) ...[
                            // -- Awaiting email confirmation ---------------------------------
                            Row(children: [
                              const Icon(Icons.mark_email_unread_outlined,
                                  color: Colors.amber),
                              const SizedBox(width: 8),
                              Text(strings.checkYourInbox,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2)),
                            ]),
                            const SizedBox(height: 8),
                            Text(
                              strings.confirmationSent(_pendingSignupEmail!),
                              style: TextStyle(color: Colors.grey.shade400),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              key: const ValueKey('verification-code-field'),
                              controller: _codeController,
                              decoration: InputDecoration(
                                labelText: strings.verificationCodeLabel,
                                hintText: strings.verificationCodeHint,
                                border: const OutlineInputBorder(),
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
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.verified_outlined),
                                label: Text(strings.confirm),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                key: const ValueKey('resend-confirmation'),
                                onPressed:
                                    _cloudBusy ? null : _resendConfirmation,
                                child: Text(strings.resendEmail),
                              ),
                            ]),
                            TextButton(
                              key: const ValueKey('cancel-pending'),
                              onPressed: _cancelPendingSignup,
                              child: Text(strings.useDifferentAddress),
                            ),
                          ] else if (_resetEmail != null &&
                              account.value == null) ...[
                            // -- Password reset in progress ----------------------------------
                            Row(children: [
                              const Icon(Icons.lock_reset, color: Colors.amber),
                              const SizedBox(width: 8),
                              Text(strings.resetTitle,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2)),
                            ]),
                            const SizedBox(height: 8),
                            Text(
                              strings.resetSent(_resetEmail!),
                              style: TextStyle(color: Colors.grey.shade400),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              key: const ValueKey('reset-code-field'),
                              controller: _resetCodeController,
                              decoration: InputDecoration(
                                labelText: strings.resetCodeLabel,
                                hintText: strings.resetCodeHint,
                                border: const OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _verifyResetCode(),
                            ),
                            const SizedBox(height: 8),
                            Row(children: [
                              FilledButton.icon(
                                key: const ValueKey('verify-reset'),
                                onPressed: _cloudBusy ? null : _verifyResetCode,
                                icon: _cloudBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.verified_outlined),
                                label: Text(strings.confirm),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                key: const ValueKey('resend-reset'),
                                onPressed: _cloudBusy ? null : _resendReset,
                                child: Text(strings.resendReset),
                              ),
                            ]),
                            TextButton(
                              key: const ValueKey('cancel-reset'),
                              onPressed: _cloudBusy ? null : _cancelReset,
                              child: Text(strings.cancelReset),
                            ),
                          ] else if (account.value == null) ...[
                            Text(strings.signInPitch,
                                style: TextStyle(color: Colors.grey.shade400)),
                            const SizedBox(height: 12),
                            TextField(
                              key: const ValueKey('email-field'),
                              controller: _emailController,
                              decoration: InputDecoration(
                                labelText: strings.emailLabel,
                                hintText: strings.emailHint,
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
                              decoration: InputDecoration(
                                labelText: strings.passwordLabel,
                                hintText: strings.passwordHint,
                                border: const OutlineInputBorder(),
                              ),
                              autofillHints: const [AutofillHints.password],
                            ),
                            const SizedBox(height: 8),
                            Row(children: [
                              FilledButton.icon(
                                key: const ValueKey('email-signin'),
                                onPressed: _signIn,
                                icon: const Icon(Icons.mail_outline),
                                label: Text(strings.signInWithEmail),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: const ValueKey('oauth-google'),
                                onPressed: _providerEnabled('google')
                                    ? () => _runProvider('google')
                                    : null,
                                child: const Text('Google'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: const ValueKey('oauth-github'),
                                onPressed: _providerEnabled('github')
                                    ? () => _runProvider('github')
                                    : null,
                                child: const Text('GitHub'),
                              ),
                            ]),
                            if (!_serverConfigured &&
                                widget.serverSetup != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.dns_outlined,
                                        size: 16, color: Colors.amber.shade300),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        strings.serverOnboardingHint,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ]),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                key: const ValueKey('connect-server'),
                                onPressed: () async {
                                  final configured = await widget.serverSetup!
                                      .showConnectionDialog(context);
                                  if (configured && mounted) {
                                    setState(() => _serverConfigured = true);
                                  }
                                },
                                icon: const Icon(Icons.lan_outlined),
                                label: Text(strings.connectGameServer),
                              ),
                            ],
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                key: const ValueKey('cloud-signin'),
                                onPressed: _cloudBusy ? null : _cloudSignIn,
                                icon: _cloudBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.cloud_outlined),
                                label: Text(strings.createOrSignInCloud),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                key: const ValueKey('forgot-password'),
                                onPressed:
                                    _cloudBusy ? null : _startPasswordReset,
                                child: Text(strings.forgotPassword),
                              ),
                            ),
                          ] else ...[
                            if (account.isCloudSignedIn &&
                                (account.passwordResetPending ||
                                    _showChangePassword)) ...[
                              // -- Change password: forced after recovery (the
                              // session has no password the player knows), or
                              // opened from the card's link. A current-password
                              // field joins when the player asked for it.
                              Text(strings.signedInAs(account.value!.email),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(
                                account.passwordResetPending
                                    ? strings.changePasswordHint
                                    : strings.changePasswordSectionHint,
                                style: TextStyle(color: Colors.amber.shade300),
                              ),
                              const SizedBox(height: 12),
                              if (!account.passwordResetPending) ...[
                                TextField(
                                  key: const ValueKey('current-password-field'),
                                  controller: _currentPasswordController,
                                  obscureText: true,
                                  decoration: InputDecoration(
                                    labelText: strings.currentPasswordLabel,
                                    border: const OutlineInputBorder(),
                                  ),
                                  autofillHints: const [AutofillHints.password],
                                ),
                                const SizedBox(height: 8),
                              ],
                              TextField(
                                key: const ValueKey('new-password-field'),
                                controller: _newPasswordController,
                                obscureText: true,
                                decoration: InputDecoration(
                                  labelText: strings.newPasswordLabel,
                                  hintText: strings.newPasswordHint,
                                  border: const OutlineInputBorder(),
                                ),
                                autofillHints: const [
                                  AutofillHints.newPassword
                                ],
                                onSubmitted: (_) => account.passwordResetPending
                                    ? _submitNewPassword()
                                    : _changePassword(),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                key: const ValueKey('confirm-password-field'),
                                controller: _confirmPasswordController,
                                obscureText: true,
                                decoration: InputDecoration(
                                  labelText: strings.newPasswordConfirmLabel,
                                  border: const OutlineInputBorder(),
                                ),
                                autofillHints: const [
                                  AutofillHints.newPassword
                                ],
                                onSubmitted: (_) => account.passwordResetPending
                                    ? _submitNewPassword()
                                    : _changePassword(),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  key: const ValueKey('save-new-password'),
                                  onPressed: _cloudBusy
                                      ? null
                                      : account.passwordResetPending
                                          ? _submitNewPassword
                                          : _changePassword,
                                  icon: _cloudBusy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(Icons.save_outlined),
                                  label: Text(strings.changePassword),
                                ),
                              ),
                            ] else ...[
                              Text(strings.signedInAs(account.value!.email),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              Text(
                                account.isCloudSignedIn
                                    ? strings.cloudAccountReady
                                    : strings.deviceLocalAccount,
                                style: TextStyle(
                                    color: Colors.grey.shade500, fontSize: 12),
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
                                label: Text(strings.signOut),
                              ),
                              if (account.isCloudSignedIn) ...[
                                const SizedBox(height: 4),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    key: const ValueKey('open-change-password'),
                                    onPressed: _cloudBusy
                                        ? null
                                        : () => setState(
                                            () => _showChangePassword = true),
                                    child: Text(strings.changePassword),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ]),
                  ),
                ),
              ),
            ],
            // -- Player name ---------------------------------------------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.badge_outlined),
                        const SizedBox(width: 8),
                        Text(strings.playerNameHeader,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2)),
                      ]),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('player-name-field'),
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: strings.playerNameLabel,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: _saveName,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('save-name'),
                        onPressed: () => _saveName(_nameController.text),
                        icon: const Icon(Icons.check),
                        label: Text(strings.saveName),
                      ),
                    ]),
              ),
            ),
            // -- Language -------------------------------------------------------
            Card(
              key: const ValueKey('language-tile'),
              child: ListTile(
                leading: const Icon(Icons.translate),
                title: Text(strings.language),
                subtitle: Text(appLocale.isSet
                    ? appLocale.value!.nativeName
                    : 'English — ${strings.moreLanguagesComing}'),
                trailing: const Icon(Icons.expand_more),
                onTap: _pickLanguage,
              ),
            ),
            // -- Game sections ---------------------------------------------------
            ...widget.extraSections,
            Text(
              strings.settingsFooter,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
          ]),
    );
  }

  /// The language dialog: one entry per supported language, checked where
  /// the persisted notifier stands. Picking pops and persists; cancelling
  /// keeps everything as it was.
  Future<void> _pickLanguage() async {
    final chosen = await showDialog<ShellLanguage>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(appLocale.strings.language),
        content: SingleChildScrollView(
          child: RadioGroup<ShellLanguage>(
            groupValue: appLocale.value,
            onChanged: (value) => Navigator.pop(dialogContext, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final language in ShellLanguage.values)
                  RadioListTile<ShellLanguage>(
                    key: ValueKey('language-${language.code}'),
                    value: language,
                    title: Text(language.nativeName),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel-language'),
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(appLocale.strings.cancel),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await appLocale.setLanguage(chosen);
    if (mounted) setState(() {});
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
    if (!valid) {
      setState(() => _emailError = appLocale.strings.invalidEmail);
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
      setState(() => _emailError = appLocale.strings.invalidEmail);
      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appLocale.strings.shortPassword)),
      );
      return;
    }
    if (!_serverConfigured && widget.serverSetup != null) {
      final configured =
          await widget.serverSetup!.showConnectionDialog(context);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// Confirms the parked registration with the emailed code (or link token).
  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(appLocale.strings.enterCode)));
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
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
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.confirmationResent)));
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
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

  // -- Password reset + change ----------------------------------------------

  /// Sends the reset email for the address in the email field and parks it
  /// — the card switches to the reset-code sub-form.
  Future<void> _startPasswordReset() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _emailError = appLocale.strings.invalidEmail);
      return;
    }
    if (!_serverConfigured && widget.serverSetup != null) {
      final configured =
          await widget.serverSetup!.showConnectionDialog(context);
      if (!mounted || !configured) return; // player cancelled
      setState(() => _serverConfigured = true);
    }
    setState(() => _cloudBusy = true);
    try {
      await account.requestPasswordReset(email);
      await account.parkPasswordReset(email);
      if (mounted) {
        setState(() {
          _resetEmail = email;
          _resetCodeController.clear();
        });
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// The change-password section on the signed-in card: verifies the
  /// current password with a plain sign-in, then PUTs the new one. Runs
  /// through the same `_submitNewPassword` as the forced form, so both
  /// paths share validation and error surfacing.
  Future<void> _changePassword() async {
    final current = _currentPasswordController.text;
    if (current.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appLocale.strings.enterCurrentPassword)),
      );
      return;
    }
    setState(() => _cloudBusy = true);
    try {
      // Proves the current password (and re-locks the session):
      // a wrong one surfaces the server's own invalid-credentials error.
      await account.signInWithPassword(account.value!.email, current);
      final password = _newPasswordController.text;
      if (password.length < 6) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.shortPassword)),
          );
        }
        return;
      }
      if (password != _confirmPasswordController.text) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.passwordMismatch)),
          );
        }
        return;
      }
      await _submitNewPassword();
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// Verifies the reset code: on success the player is signed in and the
  /// account card switches to the forced change-password form.
  Future<void> _verifyResetCode() async {
    final code = _resetCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(appLocale.strings.enterCode)));
      return;
    }
    setState(() => _cloudBusy = true);
    try {
      await account.verifyRecoveryCode(code);
      if (mounted) {
        setState(() {
          _resetEmail = null;
          _resetCodeController.clear();
        });
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// Re-sends the reset email for the parked address.
  Future<void> _resendReset() async {
    try {
      await account.resendPasswordReset();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.resetEmailSent)));
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  /// Abandons the reset — back to the sign-in form.
  Future<void> _cancelReset() async {
    await account.cancelPasswordReset();
    if (mounted) {
      setState(() {
        _resetEmail = null;
        _resetCodeController.clear();
      });
    }
  }

  /// Applies the new password: validates both fields agree and are long
  /// enough, calls the controller, and clears the form on success.
  Future<void> _submitNewPassword() async {
    final password = _newPasswordController.text;
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appLocale.strings.shortPassword)),
      );
      return;
    }
    if (password != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appLocale.strings.passwordMismatch)),
      );
      return;
    }
    setState(() => _cloudBusy = true);
    try {
      await account.changePassword(password);
      if (mounted) {
        _newPasswordController.clear();
        _confirmPasswordController.clear();
        _currentPasswordController.clear();
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appLocale.strings.passwordChanged)));
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _saveName(String name) async {
    await account.setPlayerName(name);
    if (mounted) setState(() {});
  }
}
