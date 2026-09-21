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

- An unlisted target fails at the very end of the flow with
  GoTrue's *redirect URI not allowed* error page — a confusing dead end,
  so add every origin a real deployment uses (production, staging, and the
  dev origins) before turning the provider buttons live.
- The scheme half of a mobile target (`mygame://`) is chosen by the game,
  not by kommons; whatever the game picks, the same value must appear in
  the app's platform manifest and in this allow-list, and the host sets
  `account.oauthRedirectUri = Uri.parse('mygame://auth')`.
- The allow-list is per server. A game's staging server and production
  server have separate lists.

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
