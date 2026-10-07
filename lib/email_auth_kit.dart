/// Barrel re-export for the email_auth_kit subpackage.
///
/// Import via `package:kommons/email_auth_kit.dart` to reach the
/// Supabase + Brevo auth flows and their UI widgets without digging
/// into deep `lib/src/...` paths.
///
/// Public surface:
///   • [MediasartAuth] — the Supabase + Brevo auth client
///   • [AuthSession], [AuthCodeException], [AuthBannedException],
///     [ResetResult] — result & error types
///   • [generateCodeVerifier], [generateCodeChallenge] — PKCE helpers
///   • [RegisterLink] / [RegistrationFlow] / [ForgotPasswordLink] /
///     [ForgotPasswordFlow] / [SignInFlow] / [SignUpWithGoogleButton]
library;

export 'package:mediasart_auth_client/mediasart_auth_client.dart';
