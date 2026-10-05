# teststack — local end-to-end harness

A throwaway Supabase stack + smoke suite that proves the kit against
real infrastructure. Nothing here ships with a project.

## What's inside

- `supabase/` — minimal stack config (`supabase start`), the kit's
  migration copied in, the two functions staged, and `.env` with the
  local stack's keys (shared local defaults — never real secrets).
- `smoke_test.py` — the 50-check suite (see below).
- `smtp_repro.ts` — step-logged standalone repro of the kit's SMTP
  client, useful when debugging mail delivery.

## Run it

### After any teststack restart (one command)

The smoke suite is driven by run_phase0-style env, so it always runs
against the live stack's CURRENT keys — no stale baked-in values:

```bash
identity/run_phase0.sh --smoke        # steps 1-3 (stack A + fresh
                                      # functions) + all 50 checks
```

Or as a tail on a full identity-proof run: `RUN_SMOKE=1
identity/run_phase0.sh` (proof's 16 checks, then the suite's 23).

The suite reads `KIT_API_URL`, `KIT_EV_URL`, `KIT_PR_URL`,
`KIT_MAILPIT_URL`, `KIT_ANON_KEY`, `KIT_DB_CONTAINER` from the
environment; the defaults inside the file are only a convenience for a
long-lived stack whose keys have not rotated.

### Manual, step by step

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
python3 smoke_test.py                 # 50 checks, exits non-zero on fail
supabase stop                         # when done
```

Mailpit UI (every mail the suite sent): http://127.0.0.1:54324

## verify_vm_project.sh — VM acceptance (Phase 1)

The Phase 0 checks parameterized for the real VM
(see docs/PHASE1_VM_ROLLOUT.md §4): run it per project stack AFTER its
`.env` carries the shared JWT secret and signup is disabled. The env
contract is documented at the top of `verify_vm_project.py`;
`KIT_BREVO_API_KEY` auto-fetches the mailed code (best-effort, falls
back to an interactive prompt), `KIT_MAILPIT_URL` does the same against
Mailpit for teststack runs, `KIT_PROBE_TABLE` (+ optional
`KIT_PROBE_COLUMNS`) selects the auth.uid()-RLS table to probe, and
`KIT_ADMIN_KEY` enables auto-deleting the minted test user.

Validated end-to-end against the prototype stacks mapped onto the VM's
URL shapes (kong-style defaults, bare-PostgREST/GoTrue overrides):
ALL PASS, exit 0.

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
