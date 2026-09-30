#!/usr/bin/env bash
# run_phase0.sh — bring up the two-stack central-identity prototype from
# zero (or reuse whatever is already up) and run the 12-check proof.
#
#   ./run_phase0.sh            # prove, leave both stacks running
#   TEARDOWN=1 ./run_phase0.sh # prove, then tear stack B down again
#   ./run_phase0.sh --smoke    # no identity work: stack A up (steps 1-3)
#                              # + the kit's 23-check smoke suite
#   RUN_SMOKE=1 ./run_phase0.sh  # full proof, then the smoke suite
#
# Idempotent: every step is a no-op when its outcome already exists.
# Stack A = the kit's supabase teststack (CLI-managed, project id
# email-auth-kit-test, kit functions host-run on :8787/:8788).
# Stack B = this dir's docker-compose (project_b DB, its own PostgREST +
# signup-disabled GoTrue) carrying stack A's JWT secret.
set -euo pipefail
cd "$(dirname "$0")"

KIT_ROOT=$(cd ../.. && pwd)                 # email_auth_kit/ (this dir is teststack/identity)
TESTSTACK=$KIT_ROOT/teststack
A_PROJECT=email-auth-kit-test
A_NETWORK=supabase_network_$A_PROJECT
B_AUTHENTICATOR_PW=b-prototype-authenticator-pw
B_AUTH_ADMIN_PW=b-prototype-auth-pw
export A_NETWORK B_AUTHENTICATOR_PW B_AUTH_ADMIN_PW

echo "== 1. stack A (identity): up"
# Stage the kit migration from its canonical source so a fresh checkout
# (CI) starts the real stack, not a config-less default one.
mkdir -p "$TESTSTACK/supabase/migrations"
cp "$KIT_ROOT/supabase/migrations/"*.sql "$TESTSTACK/supabase/migrations/"
A_START_LOG=/tmp/phase0-stackA-start.log
if ! ( cd "$TESTSTACK" && supabase start ) >"$A_START_LOG" 2>&1; then
  echo "stack A failed to start — last 30 log lines:" >&2
  tail -30 "$A_START_LOG" >&2
  exit 1
fi
docker ps --format '{{.Names}}' | grep -q "supabase_db_$A_PROJECT" || {
  echo "stack A failed to start" >&2; exit 1; }

echo "== 2. secrets: extract stack A's JWT secret"
A_SECRET=$(docker exec "supabase_auth_$A_PROJECT" printenv GOTRUE_JWT_SECRET | tr -d '\n')
# PostgREST-B needs A's secret in the JWKS-JSON form A's own rest
# container runs with. Select BY PREFIX — env order is not stable.
A_PGRST_JSON=$(docker inspect "supabase_rest_$A_PROJECT" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^PGRST_JWT_SECRET=' | head -1 | cut -d= -f2-)
[ -n "$A_PGRST_JSON" ] || { echo "could not find PGRST_JWT_SECRET in A's rest env" >&2; exit 1; }
export A_GOTRUE_JWT_SECRET="$A_SECRET" PGRST_JWT_SECRET_JSON="$A_PGRST_JSON"

echo "== 3. kit functions: host-run deno on :8787/:8788"
MAILPIT_IP=$(docker inspect "supabase_inbucket_$A_PROJECT" \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}')
ENVF=$TESTSTACK/supabase/functions/.env
mkdir -p "$(dirname "$ENVF")"
cat > "$ENVF" <<EOF
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_ROLE_KEY=$(docker exec "supabase_auth_$A_PROJECT" printenv GOTRUE_SERVICE_ROLE_KEY 2>/dev/null || \
  supabase status -o env 2>/dev/null | grep SERVICE_ROLE | cut -d= -f2)
SUPABASE_ANON_KEY=$(supabase status -o env 2>/dev/null | grep PUBLISHABLE | cut -d= -f2 || \
  grep -h 'ANON_KEY\|PUBLISHABLE' "$TESTSTACK/supabase/functions/.env" 2>/dev/null | tail -1 | cut -d= -f2)
BREVO_SMTP_HOST=$MAILPIT_IP
BREVO_SMTP_PORT=1025
EOF
# Prefer the known-good local keys if the CLI could not print them.
if ! grep -q '^SUPABASE_SERVICE_ROLE_KEY=..' "$ENVF" || ! grep -q '^SUPABASE_ANON_KEY=..' "$ENVF"; then
  echo "could not derive the stack keys automatically" >&2
  exit 1
fi
DENO=${DENO:-$HOME/.deno/bin/deno}
[ -x "$DENO" ] || DENO=$(command -v deno || echo /usr/bin/env deno)
# Always relaunch with fresh env: a supabase stop/start regenerates the
# API keys and Mailpit's IP, so any function left over from a previous run
# (whatever tree it was launched from) serves with dead env and 500s.
# The script arg is the only string present in every invocation form
# (launchers cd into functions/, so the arg may be relative) — match it.
pkill -f 'email-verification/index.ts' 2>/dev/null \
  && echo "   killed stale email-verification" || true
pkill -f 'password-reset/index.ts' 2>/dev/null \
  && echo "   killed stale password-reset" || true
pkill -f 'ban-management/index.ts' 2>/dev/null \
  && echo "   killed stale ban-management" || true
sleep 1
DENO=${DENO:-$HOME/.deno/bin/deno}
[ -x "$DENO" ] || DENO=$(command -v deno || echo /usr/bin/env deno)
for fn in email-verification password-reset ban-management; do
  port=$([ "$fn" = email-verification ] && echo 8787 || echo 8788); [ "$fn" = ban-management ] && port=8789
  ( cd "$KIT_ROOT/supabase/functions" && \
    FUNCTION_PORT=$port setsid nohup "$DENO" run --allow-net --allow-env \
      --env-file=$ENVF "$fn/index.ts" </dev/null >"/tmp/phase0-$fn.log" 2>&1 & )
  echo "   $fn launched on :$port"
done
# Wait for readiness: the proof's first signup races deno's boot otherwise.
for port in 8787 8788; do
  for i in $(seq 1 30); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" || true)
    [ "$code" != "000" ] && break
    sleep 1
  done
done

# Derive the kit smoke suite's env from the LIVE stack and run it. Never
# baked into the suite: any teststack restart regenerates the API keys
# and Mailpit's address, and a stale suite then fails on delivery/DB.
run_smoke() {
  KIT_API_URL="http://127.0.0.1:54321"
  KIT_EV_URL="http://127.0.0.1:8787"
  KIT_PR_URL="http://127.0.0.1:8788"
  KIT_MAILPIT_URL="http://127.0.0.1:54324"
  SUPABASE_BIN=${SUPABASE_BIN:-$(command -v supabase || true)}
  [ -n "$SUPABASE_BIN" ] || SUPABASE_BIN="$HOME/.local/bin/supabase"
  KIT_ANON_KEY=$( ( cd "$TESTSTACK" && "$SUPABASE_BIN" status -o env 2>/dev/null ) \
    | grep -E 'PUBLISHABLE|ANON_KEY' | cut -d= -f2 | tail -1 || true)
  # status -o env prints the value quoted; the apikey header wants it bare.
  KIT_ANON_KEY=${KIT_ANON_KEY%\"}; KIT_ANON_KEY=${KIT_ANON_KEY#\"}
  KIT_DB_CONTAINER="supabase_db_$A_PROJECT"
  export KIT_API_URL KIT_EV_URL KIT_PR_URL KIT_MAILPIT_URL KIT_ANON_KEY KIT_DB_CONTAINER
  [ -n "$KIT_ANON_KEY" ] || { echo "could not derive the anon key for the smoke suite" >&2; exit 1; }
  python3 "$TESTSTACK/smoke_test.py"
}

# --smoke: the teststack-restart companion. Steps 1-3 above bring stack A
# up with fresh env; the 23-check functional suite runs without any of
# the two-stack identity work.
if [ "${1:-}" = "--smoke" ]; then
  run_smoke
  echo "SMOKE-ONLY RUN COMPLETE (stack A left up for dev use)"
  exit 0
fi

echo "== 4. project_b: database + roles (idempotent)"
docker exec "supabase_db_$A_PROJECT" psql -U postgres -tAc \
  "select 1 from pg_database where datname='project_b'" | grep -q 1 || \
  docker exec "supabase_db_$A_PROJECT" psql -U postgres -c "create database project_b;"
docker exec "supabase_db_$A_PROJECT" psql -U postgres -tAc \
  "select 1 from pg_roles where rolname='authenticator_b'" | grep -q 1 || \
  docker exec "supabase_db_$A_PROJECT" psql -U postgres \
    -c "create role authenticator_b login password '$B_AUTHENTICATOR_PW' noinherit;
        grant anon, authenticated to authenticator_b;
        create role auth_admin_b login password '$B_AUTH_ADMIN_PW' noinherit;"

echo "== 5. project_b: schema provisioning"
# CI's database is virgin: no auth schema exists until GoTrue-B boots
# (step 6) and migrates it. The DDL below (default auth.uid(), whoami())
# must not depend on that hidden ordering — create the schema and a stub
# auth.uid() here. NOTE: postgres is NOT a superuser on this stack, and
# GoTrue-B's migration replaces this stub as auth_admin_b — so the stub
# is created AS auth_admin_b (postgres holds admin on that role, having
# created it in step 4). Ownership by auth_admin_b end-to-end means every
# later replace is legal.
docker exec "supabase_db_$A_PROJECT" psql -U postgres -d project_b -q -c \
  "create schema if not exists auth;              -- postgres owns the DB
   grant usage, create on schema auth to auth_admin_b;  -- owner grants
   grant auth_admin_b to postgres;
   set role auth_admin_b;
   create or replace function auth.uid() returns uuid
   language sql stable as \$\$ select null::uuid \$\$;
   reset role;"
docker exec -i "supabase_db_$A_PROJECT" psql -U postgres -d project_b -q \
  < project_b_schema.sql

echo "== 6. stack B: compose up"
docker compose up -d --quiet-pull
for i in $(seq 1 30); do
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:31001/health)" = 200 ] && break
  sleep 2
done
curl -s -m 2 -o /dev/null -w '   auth-b health: %{http_code}\n' http://127.0.0.1:31001/health

# /health answers before GoTrue-B's FIRST-BOOT migration lands its legacy
# auth.uid() (observed on a virgin database: the health-wait passed, then
# the legacy reader overwrote everything we install). The stub's body is
# unique, so wait for the body to CHANGE — i.e. GoTrue's legacy write
# landed — before modernizing. (postgres is not superuser, so the
# fingerprint must be body-based, not ownership-based.)
for i in $(seq 1 60); do
  b=$(docker exec "supabase_db_$A_PROJECT" psql -U postgres -d project_b -tAc \
    "select coalesce(pg_get_functiondef('auth.uid()'::regprocedure),'')" 2>/dev/null || echo '')
  case "$b" in *'null::uuid'*) sleep 2 ;; *) break ;; esac
done

echo "== 7. post-migration fixes (modern auth.uid, grants)"
docker exec -i "supabase_db_$A_PROJECT" psql -U postgres -d project_b \
  -v ON_ERROR_STOP=1 -q < post_migration.sql

# Assert the modern reader actually landed (the CI run that motivated
# this ordering failed silently here: the stub survived, RLS saw null).
body=$(docker exec "supabase_db_$A_PROJECT" psql -U postgres -d project_b -tAc \
  "select pg_get_functiondef('auth.uid()'::regprocedure)" 2>/dev/null)
case "$body" in *'request.jwt.claims'*) ;; *) echo "FATAL: auth.uid() is not the modern claim reader" >&2; exit 1 ;; esac

echo "== 8. postgrest-b: reload schema cache"
docker compose restart postgrest-b >/dev/null
# docker restart returns before PGRST-B actually listens; the proof's
# first B call then gets an empty reply and fails spuriously (cold runs
# only — warm reuse never saw it). Wait for the OpenAPI root like auth-b.
for i in $(seq 1 30); do
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:31000/)" = 200 ] && break
  sleep 1
done
sleep 4

echo "== 9. the proof (sections 1-5 + the ban kill-switch section 6)"
# Section 6 drives the kit's ban RPC through A's REST gateway, which
# needs the stack's service-role key — read it from the function env
# derived in step 3 (always fresh, never baked in). status -o env prints
# the value QUOTED; the Bearer header wants it bare.
KIT_SVC_KEY=$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ENVF" | cut -d= -f2- | tr -d '"')
SUPABASE_SERVICE_ROLE_KEY="$KIT_SVC_KEY" python3 proof.py

# Optional smoke tail: the kit's 23-check functional suite after the
# proof (RUN_SMOKE=1 ./run_phase0.sh).
if [ "${RUN_SMOKE:-0}" = 1 ]; then
  echo "== 10. kit smoke suite (23 checks)"
  run_smoke
fi

if [ "${TEARDOWN:-0}" = 1 ]; then
  echo "== teardown: stack B down (stack A stays for dev use)"
  docker compose down >/dev/null
fi
