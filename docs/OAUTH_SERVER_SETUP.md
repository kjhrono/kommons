# Server-side OAuth setup

The kommons OAuth flow (Google / GitHub) has exactly one server-side
dependency: the game server's GoTrue-compatible auth service. The app never
holds provider secrets — it opens the server's hosted authorize page and
receives a complete session back. This page is the server operator's
checklist; the client side lives in COMMONS.md's OAuth section, and the
schema it sits beside is each game repo's `server/schema.sql`.

## The flow, as the server sees it

```
app ──▶ GET <server>/auth/v1/authorize
            ?provider={google|github}
            &redirect_to=<app origin on the web, or the app's redirect URI on mobile>
                         │
                         ▼
              GoTrue hands the player to the provider's consent screen
              (Google / GitHub — credentials live only here)
                         │
                         ▼
   provider ──▶ GoTrue callback ──▶ 302 to redirectTo
                                    with the implicit fragment
                                    #access_token=…&refresh_token=…&expires_in=…
                         │
                         ▼
   the app decodes the fragment (AuthService.sessionFromImplicitFragment)
   and fetches /auth/v1/user to fill the email
```

That is GoTrue's own route, and the stack's gateway (Kong) already publishes
it — as an *open* route, so the browser redirect needs no apikey. There is
nothing to add on the server for the request itself to work; the only server
work is registering the provider credentials and allow-listing the redirect
targets below.

The app talks to the rest of GoTrue's REST surface (`/auth/v1/token`,
`/auth/v1/signup`, `/auth/v1/user`) on that same origin, so all of it must be
reachable at the URL the app stores as its game server.

## One-time: enable the providers in the GoTrue/Supabase dashboard

For each game server (per game repo — the servers are independent):

1. **Google**
   - In the provider's own console (Google Cloud Console → Credentials),
     create an OAuth 2.0 *Web application* client. Its **Authorized
     redirect URI** is the GoTrue callback:
     `<server>/auth/v1/callback` (on Supabase's own hosting that is
     `https://<project-ref>.supabase.co/auth/v1/callback`; on a self-hosted
     stack it is `https://<your-domain>/auth/v1/callback`).
   - In the GoTrue/Supabase dashboard (Authentication → Providers →
     Google): enable it, paste the client ID and secret.
2. **GitHub**
   - Create an OAuth App (GitHub → Settings → Developer settings). The
     **Authorization callback URL** is the same GoTrue callback:
     `<server>/auth/v1/callback` (on Supabase's own hosting,
     `https://<project-ref>.supabase.co/auth/v1/callback`).
   - Enable the GitHub provider in the dashboard with its client ID and
     secret.

The secrets live only server-side. Nothing in the app, its repo, or its
CI needs them.

## Every deployment: allow-list the redirect targets

GoTrue only redirects to targets it knows. Both of these must be listed
(Authentication → URL Configuration → **Redirect URLs**):

| Platform | What to add | Set by the host app via |
| --- | --- | --- |
| Web | the app's origin — e.g. `https://game.example` (add the port-suffixed form for dev: `http://localhost:port`) | nothing — the shell sends `Uri.base.origin` automatically |
| Android / iOS | the app's redirect — a custom scheme (`mygame://auth`) or the universal-link origin, matching the app's intent-filter / `CFBundleURLTypes` | `account.oauthRedirectUri` |

Notes:

- An unlisted target fails at the very end of the flow — either with
  GoTrue's *redirect URI not allowed* error page, or, as observed on the
  central identity stack, **silently rewritten to `GOTRUE_SITE_URL`**:
  `/authorize` still answers 302, so nothing looks wrong until the member
  lands on the website instead of back in the app. Both are confusing dead
  ends, so add every origin a real deployment uses (production, staging, and
  the dev origins) before turning the provider buttons live.
- The scheme half of a mobile target (`mygame://`) is chosen by the game,
  not by kommons; whatever the game picks, the same value must appear in
  the app's platform manifest and in this allow-list, and the host sets
  `account.oauthRedirectUri = Uri.parse('mygame://auth')`.
- The allow-list is per server. A game's staging server and production
  server have separate lists.
- The **central identity stack** — the one every sibling project signs in
  against — is the exception: its list is not typed into the stack `.env` by
  hand. It is declared in `tool/identity-redirect-allowlist.txt` and converged
  by `tool/identity_allowlist_sync.sh`, because that `.env` gets rewritten for
  other reasons (secrets, providers, host ports) and a rebuild would otherwise
  take the native `scheme://` entry with it. Add or change an entry in the
  declaration, never in the file the stack runs from. A `*/30` guard on the VM
  runs the tool's `--heal` mode, so a rewrite that does drop an entry is
  converged and the running auth re-verified within the half hour instead of
  waiting for a member to notice a sign-in landing on the website.
- **The fallback origin is asserted too.** `GOTRUE_SITE_URL` is where every
  unlisted target is rewritten, and GoTrue allows that origin implicitly — so a
  site URL pointing somewhere that cannot finish a sign-in is a silent failure
  of the same shape, and it is the destination of every other silent failure.
  The declaration therefore names it (`site_url=https://…` — a *directive*, not
  an entry), and the nightly `tool/oauth_handoff_probe.sh` compares that value
  against both the fallback it observes in flight and the running container's
  `GOTRUE_SITE_URL`, and reports the two separately so a process running a
  value the stack no longer holds is distinguishable from a mis-set one. It is
  not only asserted: `tool/identity_allowlist_sync.sh` **converges** `SITE_URL`
  from that same directive (rewriting the key and recreating only auth, then
  re-verifying the running container), and refuses a malformed value outright —
  that origin is also the root of every confirmation and recovery link the
  stack mails, so it is never guessed at. **Change it in the declaration, never
  in the stack `.env`**; a manual `.env` edit is converged away within the half
  hour, and until then the nightly probe calls it out.
- **The two mail links are asserted end to end.** A signup confirmation and a
  password recovery are the only mails that carry a LINK a member clicks, and
  both are built as `<GOTRUE_SITE_URL> + one path`. They are not rendered by
  GoTrue's templates at all: the stack's `auth-email` send-email hook assembles
  them from the `site_url` GoTrue hands it, so a wrong origin or path there is a
  code-level drift that no configuration check would see. The declaration names
  the two paths (`mail_confirmation_path`, `mail_recovery_path`) and the nightly
  probe holds each one to the running auth's `MAILER_URLPATHS_*`, to a real
  request at the link's own URL, and to the hook's own rendering — and fails when
  the action is not armed at all, because a link nobody is sent cannot be
  asserted. Add or change a mail path in the declaration, in the hook, and in the
  stack's `MAILER_URLPATHS_*` together.

## The recovery email template: `{{ .Token }}` vs a link

The shell's forgot-password form (Authentication → Emails → Templates →
**Reset Password**; GoTrue's `mailer.templates.recovery`) sends whatever
token the template carries — the template decides whether the player
gets a code or a link. Whichever it is, the shell POSTs what the player
typed (or pasted) to `/auth/v1/verify?type=recovery` unchanged:

| Template token | What the player receives | In the shell |
| --- | --- | --- |
| `{{ .Token }}` | a 6-digit code (expiry: the mailer OTP setting) | type the digits into the reset form — the smooth path, **recommended** |
| `{{ .ConfirmationURL }}` | a verify link — **supported**: a `?token_hash=…&type=recovery` link (newer Supabase generation) signs the player back in wherever it opens; a `#token=…&type=recovery` fragment link signs back in on the device that requested the reset, or pastes into the reset form | opens the app straight into the forced change-password step |

Both templates now complete the flow in-app (COMMONS.md's *Lost & changed
passwords*). `{{ .Token }}` remains the recommendation — one fewer hop, and
it works on any device — but a link template is no longer a dead end.

Whichever token the template carries, the LINK (where a template has one)
always points at `<GOTRUE_SITE_URL>` + the path the mailer uses — never at a
host typed into the template. That is asserted nightly, per action:
`mail_confirmation_path` and `mail_recovery_path` in the declaration name the
two paths, and `oauth_handoff_probe.sh` follows each link's own URL and holds
the hook that renders it to them, so a recovery link that would land somewhere
that cannot finish the flow is reported instead of being discovered by a
player.

Two operational notes:

- **Link generations differ.** Newer Supabase/GoTrue links carry
  `token_hash` in the query string — self-addressing, they sign the player
  in wherever they open. Older/Netlify-era links carry a plain `token` in
  the fragment; the shell verifies those against the reset email, which
  only the device that requested the reset knows (elsewhere the player
  falls back to pasting the link into the reset form on the requesting
  device, or to the code the same email also carries when the template
  includes it). Check one real email from your server to know which
  generation you mail.
- **No cross-talk with invites.** Join-link detection keys on `join=`;
  recovery links key on `type=recovery` (with `token=`/`token_hash=`),
  OAuth fragments on `access_token=` — each detector ignores the others'
  payloads.

Recovery requests are rate-limited per address by GoTrue; the app
surfaces the `over_email_send_rate_limit` message verbatim, so a spammy
tester sees the server's own complaint — not a bug.

## The signup confirmation email — why registrations "sign in asap"

Email registration only proves the address when the server mails a
confirmation. Whether it does is one GoTrue setting:

```
GOTRUE_MAILER_AUTOCONFIRM=false   # mail the confirmation, withhold the session
GOTRUE_MAILER_AUTOCONFIRM=true    # sign the player in immediately, mail nothing
```

**If a fresh registration lands the player straight in the game with no
email involved, your stack has `AUTOCONFIRM=true`** (often set as the
default workaround for a not-yet-configured SMTP). With no working SMTP
that was the honest choice — GoTrue would otherwise try to mail a link
and fail. Once mail works, set it to `false`: the shell then parks every
fresh signup in its check-your-inbox state until the emailed proof
arrives, and an unconfirmed sign-in attempt answers `email_not_confirmed`
instead of a session.

The template (Authentication → Emails → Templates → **Confirm Signup**;
GoTrue's `mailer.templates.confirmation`) picks the shape the proof
takes — the shell handles both:

| Template token | What the player receives | In the shell |
| --- | --- | --- |
| `{{ .Token }}` | a 6-digit code | type the digits into the shell's confirmation form — the smooth path, **recommended** |
| `{{ .ConfirmationURL }}` | a verify link — **supported**: a `?token_hash=…&type=signup` link confirms wherever it opens (any device); a `#token=…&type=signup` fragment link confirms on the device that registered | the app opens, completes the confirmation itself, and lands the player signed in |

As with recovery links, the generations differ (query `token_hash` is
self-addressing; fragment `token` verifies against the registering
device's parked email) and there is **no cross-talk**: confirmation
detection keys on `type=signup`, disjoint from recovery (`type=recovery`),
joins (`join=`) and OAuth fragments (`access_token=`). Re-sending the
email is built in (`POST /auth/v1/resend`, also rate-limited per
address).

## What the server must NOT do

- **No provider logic app-side.** The client never exchanges codes or
  holds secrets; if a flow seems to need them, the redirect allow-list is
  the thing that's missing.
- **No schema changes.** OAuth sessions ride the same `AuthSession`
  persistence as email sessions — the auth surface (`/auth/v1/*`) is
  GoTrue's, not the game schema's. The multiplayer tables in
  `server/schema.sql` (rooms, roster, snapshots, action outbox) are
  untouched by sign-in.
- **No email-confirmation surprise.** A provider identity arrives
  confirmed server-side; if a sign-in still fails with
  `email_not_confirmed`, the server's confirmation flow is intercepting
  provider identities — check the GoTrue mailer settings before assuming
  an app bug.

## Operator checklist

- [ ] Google provider enabled (client ID + secret in the dashboard)
- [ ] GitHub provider enabled (client ID + secret in the dashboard)
- [ ] Provider callbacks registered at Google / GitHub (the GoTrue
      callback URL above)
- [ ] Redirect allow-list: every web origin + every mobile redirect URI
- [ ] The stored game-server URL in the app points at this same origin
      (the `/gt/*` pages are hosted there)
- [ ] A smoke test: provider sign-in on the web build, then on a mobile
      build (warm return *and* a force-killed cold start)
- [ ] Recovery email template set to `{{ .Token }}` — the 6-digit code
      is the path the shell's reset form is built around
- [ ] `GOTRUE_MAILER_AUTOCONFIRM=false` with a working SMTP — otherwise
      email registrations skip verification entirely (see the signup
      confirmation section above; this is the #1 cause of "it signed me
      in without any email")
- [ ] Confirm-signup template chosen: `{{ .Token }}` (recommended) or
      `{{ .ConfirmationURL }}` — both complete in-app
- [ ] Know the grant story: signing out of the app revokes the GoTrue
      session server-side, and Google's grant client-side (Google
      exposes a public revoke endpoint). **GitHub grants are NOT revoked**
      by the app — GitHub's API requires the OAuth app's client secret,
      which only the server holds. Players who want a GitHub grant gone
      revoke it at github.com → Settings → Applications, or the operator
      runs an admin job (e.g. `DELETE /applications/{id}/grant` with the
      server's credentials). Surface this honestly if your game promises
      "sign out everywhere".
- [ ] (Optional) A periodic job revoking stale GoTrue sessions
      (`POST /auth/v1/logout` with each user's tokens) keeps inactive
      sessions from piling up
