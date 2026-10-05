import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../mediasart_auth_client.dart';

/// ----------------------------------------------------------------------------
/// Public entry points
/// ----------------------------------------------------------------------------

/// A "Register" link for projects that don't yet have their own sign-in
/// screen. Tapping it pushes [RegistrationFlow].
///
/// Drop this in your existing login page's footer:
/// ```dart
/// Row(
///   mainAxisAlignment: MainAxisAlignment.center,
///   children: [
///     const Text('No account?'),
///     RegisterLink(auth: auth),
///   ],
/// )
/// ```
class RegisterLink extends StatelessWidget {
  final MediasartAuth auth;
  final void Function(AuthSession session)? onRegistered;
  final String resetRedirectTo;

  const RegisterLink({
    super.key,
    required this.auth,
    required this.resetRedirectTo,
    this.onRegistered,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RegistrationFlow(
              auth: auth,
              resetRedirectTo: resetRedirectTo,
              onRegistered: onRegistered,
            ),
          ),
        );
      },
      child: const Text('Register'),
    );
  }
}

/// A "Forgot password?" link. Tapping it pushes [ForgotPasswordFlow].
///
/// Wire it inline wherever you present a password field — the
/// [RegistrationFlow], [SignInFlow], and [ForgotPasswordFlow] footers
/// all use this.
class ForgotPasswordLink extends StatelessWidget {
  final MediasartAuth auth;

  /// Where the reset link e-mail should redirect — must be a URL your
  /// app claims as a deep link so the token reaches this flow.
  final String resetRedirectTo;

  const ForgotPasswordLink({
    super.key,
    required this.auth,
    required this.resetRedirectTo,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ForgotPasswordFlow(
              auth: auth,
              resetRedirectTo: resetRedirectTo,
            ),
          ),
        );
      },
      child: const Text('Forgot password?'),
    );
  }
}

/// ----------------------------------------------------------------------------
/// RegistrationFlow — email + password → 6-digit code → sign-in
/// ----------------------------------------------------------------------------

/// Full-screen registration flow for projects without their own form.
///
/// Steps:
///   1. Enter email + password → [MediasartAuth.signUpWithConfirmation]
///   2. Enter the 6-digit code emailed to you → [MediasartAuth.verifyCode]
///   3. Sign in with email + password → [MediasartAuth.signIn]
///
/// A [ForgotPasswordLink] sits in the footer for users who already have
/// an account.
class RegistrationFlow extends StatefulWidget {
  final MediasartAuth auth;
  final void Function(AuthSession session)? onRegistered;
  final String resetRedirectTo;

  /// When set, an inline Google OAuth button is shown beneath the
  /// email/password form (requires your app to have registered
  /// [googleRedirectTo] as a deep link).
  final String? googleRedirectTo;

  const RegistrationFlow({
    super.key,
    required this.auth,
    required this.resetRedirectTo,
    this.onRegistered,
    this.googleRedirectTo,
  });

  @override
  State<RegistrationFlow> createState() => _RegistrationFlowState();
}

class _RegistrationFlowState extends State<RegistrationFlow> {
  // Shared controllers across the two screens.
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  // Password visibility for the two password fields on this flow.
  bool _obscurePassword = true;

  // Step tracking.
  _RegStep _step = _RegStep.emailPassword;

  String? _errorMessage;
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _setError(String? msg) {
    setState(() => _errorMessage = msg);
  }

  Future<void> _requestCode() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      _setError('Please enter your email and password.');
      return;
    }
    setState(() => _busy = true);
    _setError(null);
    try {
      await widget.auth.signUpWithConfirmation(
        email: email,
        password: password,
      );
      setState(() => _step = _RegStep.confirmationCode);
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    } on AuthBannedException {
      _setError('This account has been suspended.');
    }
    setState(() => _busy = false);
  }

  Future<void> _verifyCode(String code) async {
    final email = _emailController.text.trim();
    setState(() => _busy = true);
    _setError(null);
    try {
      await widget.auth.verifyCode(email, code);
      // Sign in automatically after verification.
      final session = await widget.auth.signIn(
        email: email,
        password: _passwordController.text,
      );
      widget.onRegistered?.call(session);
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    } on AuthBannedException {
      _setError('This account has been suspended.');
    }
    setState(() => _busy = false);
  }

  void _toEmailStep() {
    setState(() {
      _step = _RegStep.emailPassword;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register')),
      body: SafeArea(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _buildForm(),
      ),
    );
  }

  Widget _buildForm() {
    switch (_step) {
      case _RegStep.emailPassword:
        return _buildEmailPassword();
      case _RegStep.confirmationCode:
        return _buildConfirmationCode();
    }
  }

  Widget _buildEmailPassword() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Create your account',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailController,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            enabled: !_busy,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: _buildPasswordToggle(),
            ),
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _requestCode(),
            enabled: !_busy,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _busy ? null : _requestCode,
              child: const Text('Send confirmation code'),
            ),
          ),
          if (widget.googleRedirectTo != null) ...[
            const SizedBox(height: 16),
            _googleDivider('Or sign up with Google'),
            const SizedBox(height: 12),
            SignUpWithGoogleButton(
              auth: widget.auth,
              redirectTo: widget.googleRedirectTo!,
              onGoogleAuthenticated: (session) {
                widget.onRegistered?.call(session);
                if (mounted) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
              onGoogleError: (e) => _setError('Google sign-up failed'),
              label: 'Sign up with Google',
            ),
          ],
          const SizedBox(height: 16),
          _footer(),
        ],
      ),
    );
  }

  Widget _buildConfirmationCode() {
    final theme = Theme.of(context);
    final codeController = TextEditingController();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the 6-digit code sent to\n${_emailController.text.trim()}',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: codeController,
            decoration: const InputDecoration(
              labelText: 'Confirmation code',
              border: OutlineInputBorder(),
              hintText: '000000',
            ),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 6,
            enabled: !_busy,
            onFieldSubmitted: (_) async {
              await _verifyCode(codeController.text.trim());
            },
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _busy
                  ? null
                  : () async => _verifyCode(codeController.text.trim()),
              child: const Text('Verify & sign in'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _toEmailStep,
            child: const Text('Use a different email'),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordToggle() {
    return IconButton(
      icon: Icon(
        _obscurePassword ? Icons.visibility_off : Icons.visibility,
      ),
      onPressed: () {
        setState(() => _obscurePassword = !_obscurePassword);
      },
    );
  }

  Widget _footer() {
    return Column(
      children: [
        ForgotPasswordLink(
          auth: widget.auth,
          resetRedirectTo: widget.resetRedirectTo,
        ),
      ],
    );
  }

  Widget _googleDivider(String label) {
    return Row(
      children: [
        Expanded(child: Divider(height: 1, color: Colors.grey.shade300)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
        ),
        Expanded(child: Divider(height: 1, color: Colors.grey.shade300)),
      ],
    );
  }
}

enum _RegStep { emailPassword, confirmationCode }

/// ----------------------------------------------------------------------------
/// ForgotPasswordFlow — email → recovery code → temp password → new password
/// ----------------------------------------------------------------------------

/// Full-screen forgot-password flow for projects without their own reset UI.
///
/// Steps:
///   1. Enter email → [MediasartAuth.requestReset] (a link is e-mailed)
///   2. Enter the recovery code (from the link) →
///      [MediasartAuth.completeReset] confirms the reset: the server
///      e-mails a temp password and revokes other sessions
///   3. Enter the temp password + a new password → sign-in with the
///      temp password, then [MediasartAuth.changePassword] forces the
///      new password immediately
///
/// Pass [initialToken] when your deep-link handler already extracted
/// the token from the reset link; the code field is pre-filled.
class ForgotPasswordFlow extends StatefulWidget {
  final MediasartAuth auth;
  final String resetRedirectTo;
  final void Function(AuthSession session)? onResetCompleted;

  /// The reset-link token, if the app extracted it from the deep link.
  /// Leave null and the user types it manually after entering their e-mail.
  final String? initialToken;

  const ForgotPasswordFlow({
    super.key,
    required this.auth,
    required this.resetRedirectTo,
    this.onResetCompleted,
    this.initialToken,
  });

  @override
  State<ForgotPasswordFlow> createState() => _ForgotPasswordFlowState();
}

class _ForgotPasswordFlowState extends State<ForgotPasswordFlow> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _tempPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();

  bool _obscureTemp = true;
  bool _obscureNew = true;

  _ResetStep _step = _ResetStep.email;
  String? _errorMessage;
  bool _busy = false;
  // Token from the reset link, extracted by the app's deep-link handler
  // and handed to this flow. Empty means the user types it manually.
  String _token = '';

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _tempPasswordController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  void _setError(String? msg) => setState(() => _errorMessage = msg);

  Future<void> _requestReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _setError('Please enter your email.');
      return;
    }
    setState(() => _busy = true);
    _setError(null);
    try {
      await widget.auth.requestReset(
        email: email,
        redirectTo: widget.resetRedirectTo,
      );
      setState(() {
        _step = _ResetStep.code;
        _token = widget.initialToken ?? '';
      });
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    } on AuthBannedException {
      _setError('This account has been suspended.');
    }
    setState(() => _busy = false);
  }

  Future<void> _confirmReset() async {
    final email = _emailController.text.trim();
    final token = _codeController.text.trim();
    if (token.isEmpty) {
      _setError('Please enter the recovery code from your e-mail.');
      return;
    }
    setState(() => _busy = true);
    _setError(null);
    try {
      // completeReset tells the server to set a temp password and
      // e-mail it — the app does NOT receive the temp password here.
      await widget.auth.completeReset(email: email, token: token);
      setState(() {
        _token = token;
        _step = _ResetStep.credentials;
      });
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    } on AuthBannedException {
      _setError('This account has been suspended.');
    }
    setState(() => _busy = false);
  }

  Future<void> _signInWithTempAndChange() async {
    final email = _emailController.text.trim();
    final tempPassword = _tempPasswordController.text;
    final newPassword = _newPasswordController.text;
    if (tempPassword.isEmpty || newPassword.isEmpty) {
      _setError('Please enter the temp password and your new password.');
      return;
    }
    setState(() => _busy = true);
    _setError(null);
    try {
      final session = await widget.auth.signIn(
        email: email,
        password: tempPassword,
      );
      await widget.auth.changePassword(
        session: session,
        newPassword: newPassword,
        onSessionUpdated: widget.onResetCompleted,
      );
      widget.onResetCompleted?.call(session);
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    } on AuthBannedException {
      _setError('This account has been suspended.');
    }
    setState(() => _busy = false);
  }

  void _toEmailStep() {
    setState(() {
      _step = _ResetStep.email;
      _errorMessage = null;
      _token = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _buildForm(),
      ),
    );
  }

  Widget _buildForm() {
    switch (_step) {
      case _ResetStep.email:
        return _buildEmailStep();
      case _ResetStep.code:
        return _buildCodeStep();
      case _ResetStep.credentials:
        return _buildCredentialsStep();
    }
  }

  Widget _buildEmailStep() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reset your password',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Enter your email and we\'ll send a link to reset it.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TextFormField(
            controller: _emailController,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            enabled: !_busy,
            onFieldSubmitted: (_) => _requestReset(),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _busy ? null : _requestReset,
              child: const Text('Send reset link'),
            ),
          ),
        ],
      ),
    );
  }

  /// Step 2: enter the recovery code (from the reset link). Confirms the
  /// reset on the server, which e-mails the temp password.
  Widget _buildCodeStep() {
    final theme = Theme.of(context);
    // Pre-fill from the deep-link token if the app provided one.
    if (_token.isNotEmpty && _codeController.text != _token) {
      _codeController.text = _token;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the recovery code',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Check ${_emailController.text.trim()} for the link.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _codeController,
            decoration: const InputDecoration(
              labelText: 'Recovery code',
              border: OutlineInputBorder(),
              hintText: 'Paste the token from the link',
            ),
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            enabled: !_busy,
            onFieldSubmitted: (_) => _confirmReset(),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _busy ? null : _confirmReset,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Confirm reset'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _toEmailStep,
            child: const Text('Use a different email'),
          ),
        ],
      ),
    );
  }

  /// Step 3: enter the temp password (from the e-mail we just sent) and
  /// a new password. Signs in with the temp password, then forces the
  /// password change to the new one.
  Widget _buildCredentialsStep() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Temp password sent to ${_emailController.text.trim()}',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter it below, plus your new password.',            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _tempPasswordController,
            decoration: InputDecoration(
              labelText: 'Temp password',
              border: const OutlineInputBorder(),
              suffixIcon: _buildTempPasswordToggle(),
            ),
            obscureText: _obscureTemp,
            textInputAction: TextInputAction.next,
            enabled: !_busy,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _newPasswordController,
            decoration: InputDecoration(
              labelText: 'New password',
              border: const OutlineInputBorder(),
              suffixIcon: _buildNewPasswordToggle(),
            ),
            obscureText: _obscureNew,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _signInWithTempAndChange(),
            enabled: !_busy,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _busy ? null : _signInWithTempAndChange,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Reset & sign in'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTempPasswordToggle() {
    return IconButton(
      icon: Icon(
        _obscureTemp ? Icons.visibility_off : Icons.visibility,
      ),
      onPressed: () => setState(() => _obscureTemp = !_obscureTemp),
    );
  }

  Widget _buildNewPasswordToggle() {
    return IconButton(
      icon: Icon(
        _obscureNew ? Icons.visibility_off : Icons.visibility,
      ),
      onPressed: () => setState(() => _obscureNew = !_obscureNew),
    );
  }
}

enum _ResetStep { email, code, credentials }

/// ----------------------------------------------------------------------------
/// SignInFlow — standalone sign-in page
/// ----------------------------------------------------------------------------

/// A standalone sign-in screen for projects that don't yet have their own.
///
/// Shows:
///   • email field
///   • password field with a **visibility toggle** (eye icon)
///   • an inline [ForgotPasswordLink] in the footer
///   • an optional "Register" redirect (via [onRegisterRequested])
///   • optional Google OAuth button (when [googleRedirectTo] is set)
///
/// Construct it on your auth gate:
/// ```dart
/// SignInFlow(
///   auth: auth,
///   onSignIn: (session) { /* persist tokens, navigate home */ },
///   onRegisterRequested: () { /* push your registration page */ },
/// )
/// ```
class SignInFlow extends StatefulWidget {
  final MediasartAuth auth;

  /// Where the reset link e-mail should redirect (for the inline
  /// [ForgotPasswordLink]). Projects must supply their own deep link URL.
  final String resetRedirectTo;

  /// When set, an inline Google OAuth button is shown beneath the
  /// email/password form (requires your app to have registered
  /// [googleRedirectTo] as a deep link).
  final String? googleRedirectTo;

  /// Called with the session after a successful sign-in.
  final void Function(AuthSession session)? onSignIn;

  /// Called when the user taps "Register" — push your own registration
  /// screen, or leave null to hide the link.
  final VoidCallback? onRegisterRequested;

  const SignInFlow({
    super.key,
    required this.auth,
    required this.resetRedirectTo,
    this.onSignIn,
    this.onRegisterRequested,
    this.googleRedirectTo,
  });

  @override
  State<SignInFlow> createState() => _SignInFlowState();
}

class _SignInFlowState extends State<SignInFlow> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  // The single password visibility toggle for this flow.
  bool _obscurePassword = true;

  String? _errorMessage;
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _setError(String? msg) => setState(() => _errorMessage = msg);

  void _togglePasswordVisibility() {
    setState(() => _obscurePassword = !_obscurePassword);
  }

  Widget _googleDivider(String label) {
    return Row(
      children: [
        Expanded(child: Divider(height: 1, color: Colors.grey.shade300)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
        ),
        Expanded(child: Divider(height: 1, color: Colors.grey.shade300)),
      ],
    );
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      _setError('Please enter your email and password.');
      return;
    }
    setState(() => _busy = true);
    _setError(null);
    try {
      final session = await widget.auth.signIn(
        email: email,
        password: password,
      );
      widget.onSignIn?.call(session);
      // Pop the sign-in page so the caller's navigation sees the home.
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } on AuthBannedException catch (e) {
      final until = e.bannedUntil;
      if (until != null) {
        _setError('Account suspended until $until.');
      } else {
        _setError('This account has been suspended.');
      }
    } on AuthCodeException catch (e) {
      _setError(_humanize(e));
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Welcome back',
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    // Email --------------------------------------------------
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      enabled: !_busy,
                    ),
                    const SizedBox(height: 16),
                    // Password -------------------------------------------------
                    TextFormField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: _togglePasswordVisibility,
                        ),
                      ),
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _signIn(),
                      enabled: !_busy,
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    // Sign-in button
                    SizedBox(
                      height: 44,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _signIn,
                        child: const Text('Sign in'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Google OAuth (optional)
                    if (widget.googleRedirectTo != null) ...[
                      _googleDivider('Or sign in with Google'),
                      const SizedBox(height: 12),
                      SignUpWithGoogleButton(
                        auth: widget.auth,
                        redirectTo: widget.googleRedirectTo!,
                        onGoogleAuthenticated: (session) {
                          widget.onSignIn?.call(session);
                          if (mounted) {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                          }
                        },
                        onGoogleError: (e) => _setError('Google sign-in failed'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    // Footer — ForgotPasswordLink inline + Register
                    Column(
                      children: [
                        // ForgotPasswordLink — inline in the footer
                        ForgotPasswordLink(
                          auth: widget.auth,
                          resetRedirectTo: widget.resetRedirectTo,
                        ),
                        if (widget.onRegisterRequested != null) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _busy ? null : widget.onRegisterRequested,
                            child: const Text('Register'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// ----------------------------------------------------------------------------
/// SignUpWithGoogleButton — hosted-authorize OAuth with PKCE
/// ----------------------------------------------------------------------------

/// A "Sign in/up with Google" button backed by the identity stack's
/// hosted-authorize OAuth flow using PKCE (S256).
///
/// Tap it to open Google's consent screen in the external browser;
/// when Google redirects back to [redirectTo] (a deep link your app has
/// registered), the widget exchanges the returned code for a session
/// and fires [onGoogleAuthenticated].
///
/// Your app must:
///   1. Register [redirectTo] as a deep-links scheme (e.g.
///      `myapp://oauth/callback`) and declare it on iOS/Android in
///      `Info.plist` and `AndroidManifest.xml`.
///   2. Add [redirectTo] to the identity stack's Supabase project
///      redirect URL allow-list.
///
/// Example:
/// ```dart
/// SignUpWithGoogleButton(
///   auth: auth,
///   redirectTo: 'myapp://oauth/callback',
///   onGoogleAuthenticated: (session) {
///     Navigator.of(context).pushAndRemoveUntil(home, (_) => false);
///   },
/// )
/// ```
///
/// The PKCE [codeVerifier] is generated and stored automatically;
/// the deep-link listener is active only while the widget is mounted.
class SignUpWithGoogleButton extends StatefulWidget {
  final MediasartAuth auth;

  /// Your app's deep-link URL for the OAuth redirect. Must be allow-listed
  /// in the identity stack's Supabase project settings.
  final String redirectTo;

  /// Fired after a successful Google sign-in, with the resulting session.
  final void Function(AuthSession session)? onGoogleAuthenticated;

  /// Fired when the OAuth flow fails (browser unavailable, network, ban,
  /// invalid code, etc.).
  final void Function(Object error)? onGoogleError;

  /// Button label. Defaults to "Sign in with Google".
  final String? label;

  const SignUpWithGoogleButton({
    super.key,
    required this.auth,
    required this.redirectTo,
    this.onGoogleAuthenticated,
    this.onGoogleError,
    this.label,
  });

  @override
  State<SignUpWithGoogleButton> createState() =>
      _SignUpWithGoogleButtonState();
}

class _SignUpWithGoogleButtonState extends State<SignUpWithGoogleButton> {
  bool _busy = false;

  // PKCE — kept in instance state so we can pair the verifier with the
  // code returned by the deep link.
  String? _codeVerifier;
  StreamSubscription<Uri?>? _uriSub;

  @override
  void dispose() {
    _uriSub?.cancel();
    super.dispose();
  }

  Future<void> _launchGoogle() async {
    _codeVerifier = generateCodeVerifier();
    final codeChallenge = generateCodeChallenge(_codeVerifier!);

    final authUrl = widget.auth.googleOAuthUrl(
      redirectTo: widget.redirectTo,
      codeChallenge: codeChallenge,
    );
    final redirectUri = Uri.parse(widget.redirectTo);

    // Listen *before* hand-off to the browser.
    _uriSub = uriEventHandler.listen((uri) => _onRedirect(uri, redirectUri));

    setState(() => _busy = true);
    try {
      final launched = await launchUrl(Uri.parse(authUrl));
      if (!launched) {
        _uriSub?.cancel();
        widget.onGoogleError?.call(Exception('No browser available'));
        setState(() => _busy = false);
      }
      // _busy stays true, waiting for the deep-link redirect.
    } catch (e) {
      _uriSub?.cancel();
      widget.onGoogleError?.call(e);
      setState(() => _busy = false);
    }
  }

  void _onRedirect(Uri? uri, Uri expected) {
    if (uri == null || _codeVerifier == null) return;
    // Only act on redirects to our declared deep link.
    if (uri.scheme != expected.scheme ||
        uri.host != expected.host ||
        uri.path != expected.path) {
      return;
    }
    _uriSub?.cancel();

    final code = uri.queryParameters['code'];
    if (code == null) {
      widget.onGoogleError?.call(
        Exception('No authorization code in redirect'),
      );
      setState(() => _busy = false);
      return;
    }

    widget.auth
        .signInWithGoogleCode(
          code: code,
          codeVerifier: _codeVerifier!,
          redirectTo: widget.redirectTo,
        )
        .then((session) {
          _codeVerifier = null;
          widget.onGoogleAuthenticated?.call(session);
          if (mounted) setState(() => _busy = false);
        })
        .catchError((Object e) {
          _codeVerifier = null;
          widget.onGoogleError?.call(e);
          if (mounted) setState(() => _busy = false);
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _launchGoogle,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface,
        ),
        icon: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400, width: 1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              'G',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Colors.blue.shade700,
              ),
            ),
          ),
        ),
        label: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(widget.label ?? 'Sign in with Google'),
      ),
    );
  }
}

/// ----------------------------------------------------------------------------
/// Helpers
/// ----------------------------------------------------------------------------

/// Human-readable, reason-specific error strings for the UI.
String _humanize(AuthCodeException e) {
  return switch (e.reason) {
    'rate_limited' => 'Too many attempts. Please wait a moment and try again.',
    'invalid' => 'That code or token is invalid.${e.attemptsLeft != null ? ' (${e.attemptsLeft} tries left)' : ''}',
    'locked' => 'Too many wrong attempts. Please request a new code.',
    'expired' => 'The code has expired. Please request a new one.',
    'no_pending' => 'Nothing to verify for this email. Please start again.',
    'invalid_credentials' => 'Wrong email or password.',
    'weak_password' => 'Password is too weak. Please choose a stronger one.',
    'network' => 'Couldn’t reach the server. Check your connection.',
    'unauthorized' => 'Session expired — please sign in again.',
    'temp_password_timeout' =>
      'Timed out waiting for the reset. Please try again.',
    _ => e.detail ?? 'Something went wrong. Please try again.',
  };
}
