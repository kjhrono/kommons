#!/usr/bin/env bash
# run_phase0.sh — bring up the two-stack central-identity prototype from
# zero (or reuse whatever is already up) and run the 12-check proof.
#
#   ./run_phase0.sh            # prove, leave both stacks running
#   TEARDOWN=1 ./run_phase0.sh # prove, then tear stack B down again
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
for fn in email-verification password-reset; do
  port=$([ "$fn" = email-verification ] && echo 8787 || echo 8788)
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/"; then
    echo "   $fn already serving on :$port"
  else
    ( cd "$KIT_ROOT/supabase/functions" && \
      FUNCTION_PORT=$port setsid nohup "$DENO" run --allow-net --allow-env \
        --env-file=$ENVF "$fn/index.ts" </dev/null >"/tmp/phase0-$fn.log" 2>&1 & )
    echo "   $fn launched on :$port"
  fi
done

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
docker exec -i "supabase_db_$A_PROJECT" psql -U postgres -d project_b -q \
  < project_b_schema.sql

echo "== 6. stack B: compose up"
docker compose up -d --quiet-pull
for i in $(seq 1 30); do
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:31001/health)" = 200 ] && break
  sleep 2
done
curl -s -m 2 -o /dev/null -w '   auth-b health: %{http_code}\n' http://127.0.0.1:31001/health

echo "== 7. post-migration fixes (modern auth.uid, grants)"
docker exec -i "supabase_db_$A_PROJECT" psql -U postgres -d project_b -q \
  < post_migration.sql

echo "== 8. postgrest-b: reload schema cache"
docker compose restart postgrest-b >/dev/null
sleep 4

echo "== 9. the proof (12 checks)"
python3 proof.py

if [ "${TEARDOWN:-0}" = 1 ]; then
  echo "== teardown: stack B down (stack A stays for dev use)"
  docker compose down >/dev/null
fi
