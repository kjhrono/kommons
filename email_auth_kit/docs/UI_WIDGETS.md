# Auth UI widgets

Three self-contained Flutter widgets for projects that don't yet have
their own sign-in / registration / reset screens. All live in
`lib/src/ui/registration_flow.dart` and are exported through the
package barrel:

```dart
import 'package:mediasart_auth_client/mediasart_auth_client.dart';
```

If you're consuming the kit via the kommons umbrella package, the same
widgets arrive through the barrel re-export:

```dart
import 'package:kommons/email_auth_kit.dart';
```

---

## RegisterLink

A one-line "Register" `TextButton`. Drop it in your existing login
page's footer; tapping it pushes a full-screen `RegistrationFlow`.

### Constructor

```dart
RegisterLink({
  Key? key,
  required MediasartAuth auth,
  required String resetRedirectTo,
  void Function(AuthSession session)? onRegistered,
})
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `auth` | `MediasartAuth` | yes | The kit client — used by the pushed `RegistrationFlow` to call the identity stack and edge functions. |
| `resetRedirectTo` | `String` | yes | Deep-link URL the reset e-mail link redirects to (e.g. `"https://katalogus.mediasart.com/reset"`). Forwarded to the inline `ForgotPasswordLink` inside `RegistrationFlow`. Must be registered as a deep link in your app and allow-listed in the identity stack's Supabase redirect URLs. |
| `onRegistered` | `void Function(AuthSession)?` | no | Fires after the **entire** 3-step flow completes: signup → code verification → auto sign-in. Gives you the resulting `AuthSession` (access + refresh tokens) so you can persist it and navigate home. The widget pops its own route first, so your callback sees a clean stack. |

### Callback contract

`onRegistered` is called **exactly once** per successful registration,
on the main thread, after `auth.signIn()` returns. If any step fails
(server rejection, wrong code, ban, network), the widget shows an inline
error message and `onRegistered` is **not** called. The route is not
popped on failure.

```dart
RegisterLink(
  auth: auth,
  resetRedirectTo: 'https://katalogus.mediasart.com/reset',
  onRegistered: (session) {
    // Persist tokens, navigate to home.
  },
)
```

---

## ForgotPasswordLink

A one-line "Forgot password?" `TextButton`. Tapping it pushes a
`ForgotPasswordFlow`.

### Constructor

```dart
ForgotPasswordLink({
  Key? key,
  required MediasartAuth auth,
  required String resetRedirectTo,
})
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `auth` | `MediasartAuth` | yes | Kit client. |
| `resetRedirectTo` | `String` | yes | The HTTPS deep-link URL the reset e-mail link redirects to. Your app must claim this URL so the token reaches `ForgotPasswordFlow`. |

### Notes

`ForgotPasswordLink` has **no callbacks** — it only navigates. The
pushed `ForgotPasswordFlow` handles the full reset internally (it does
not fire a callback; sign the user in with the temp password inside the
flow and call `MediasartAuth.changePassword` there). See
[RegistrationFlow](#registrationflow) for the flow's
`onRegistered`-equivalent.

Place it inline wherever a password field appears:

```dart
Row(children: [
  ForgotPasswordLink(auth: auth, resetRedirectTo: kResetUrl),
])
```

---

## RegistrationFlow

Full-screen 3-step registration: **email + password → 6-digit code →
auto sign-in**.

### Constructor

```dart
RegistrationFlow({
  Key? key,
  required MediasartAuth auth,
  required String resetRedirectTo,
  void Function(AuthSession session)? onRegistered,
  String? googleRedirectTo,
})
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `auth` | `MediasartAuth` | yes | Kit client. |
| `resetRedirectTo` | `String` | yes | Forwarded to the footer's `ForgotPasswordLink`. |
| `onRegistered` | `void Function(AuthSession)?` | no | Fires once the 3-step flow completes successfully (signup → verify → sign-in). Same contract as `RegisterLink.onRegistered`. |
| `googleRedirectTo` | `String?` | no | When set, an inline "Or sign up with Google" button + `SignUpWithGoogleButton` appear beneath the confirmation-code form. Your app must register this deep-link URL for OAuth redirects. |

### Steps & callbacks

| Step | Action | Server call |
|---|---|---|
| 1 | Enter email + password | `auth.signUpWithConfirmation(email, password)` |
| 2 | Enter 6-digit code from e-mail | `auth.verifyCode(email, code)` |
| 3 | Auto sign-in with the password | `auth.signIn(email, password)` |

After step 3 succeeds the widget calls `onRegistered(session)`, then
pops its own route (via `popUntil(isFirst)`). If any step throws
`AuthBannedException` or `AuthCodeException`, the widget shows an
inline error and keeps the user on the same step.

### Password fields

The password entry in step 1 has a visibility toggle (eye icon). The
code field in step 2 is numeric (`keyboardType: number`).

```dart
RegistrationFlow(
  auth: auth,
  resetRedirectTo: 'https://katalogus.mediasart.com/reset',
  onRegistered: (session) { /* persist + navigate */ },
  googleRedirectTo: 'myapp://oauth/callback', // optional
)
```

---

## Related widgets (same file)

The following are also public and exported from the same barrel, though
not part of the original three:

- **`SignInFlow`** — standalone sign-in page (email + password with
  visibility toggle, inline `ForgotPasswordLink`, optional "Register"
  redirect, optional Google OAuth). `onSignIn(session)` fires after a
  successful sign-in; the widget pops itself.
- **`ForgotPasswordFlow`** — full-screen reset (email → recovery code →
  temp password → new password). `onResetCompleted?(session)` fires
  after the user signs in with the temp password and the new password is
  applied — rare, since this flow usually replaces your sign-in page in
  the navigation stack.
- **`SignUpWithGoogleButton`** — standalone Google OAuth button. Takes
  `auth`, `redirectTo`, and `onGoogleAuthenticated(session)?` /
  `onGoogleError(Object)?`.
