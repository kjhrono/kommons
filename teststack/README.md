# teststack — local end-to-end harness

A throwaway Supabase stack + smoke suite that proves the kit against
real infrastructure. Nothing here ships with a project.

## What's inside

- `supabase/` — minimal stack config (`supabase start`), the kit's
  migration copied in, the two functions staged, and `.env` with the
  local stack's keys (shared local defaults — never real secrets).
- `smoke_test.py` — the 18-check suite (see below).
- `smtp_repro.ts` — step-logged standalone repro of the kit's SMTP
  client, useful when debugging mail delivery.

## Run it

```bash
supabase start                        # first run pulls images
supabase db reset                     # applies the kit migration
# run the functions from the host (no Brevo needed):
#   BREVO_SMTP_HOST points at Mailpit's container IP (docker inspect
#   supabase_inbucket_email-auth-kit-test), SMTP port 1025.
#   FUNCTION_PORT makes each function a plain `deno run` server:
deno run --allow-net --allow-env \
  --env-file=supabase/functions/.env \
  supabase/functions/email-verification/index.ts   # FUNCTION_PORT=8787
deno run --allow-net --allow-env \
  --env-file=supabase/functions/.env \
  supabase/functions/password-reset/index.ts       # FUNCTION_PORT=8788
python3 smoke_test.py                 # 18 checks, exits non-zero on fail
supabase stop                         # when done
```

Mailpit UI (every mail the suite sent): http://127.0.0.1:54324

## The stack quirk that shapes this harness

`supabase functions serve` needs the edge-runtime container and a
correct `SUPABASE_URL` **as seen from inside Docker** (`http://kong:8000`).
Running the functions as plain `deno run` host processes instead keeps
all URLs host-side (`http://127.0.0.1:54321`) — the `FUNCTION_PORT`
override in each function exists for exactly this and is inert in
production.

Also note: the "inbucket" container is Mailpit under the hood on this
stack generation — SMTP on **1025** (docker-network only), UI proxied
at 54324. The container IP changes on every `supabase stop/start`, so
refresh `BREVO_SMTP_HOST` in `.env` after a restart.
