#!/usr/bin/env bash
# ============================================================================
# canonical_secret.sh — the ONE definition of the JWT-secret canonical source.
#
# There is exactly one source of truth for the shared JWT secret: the CENTRAL
# IDENTITY stack's .env.  Every project stack's .env, the kat_secrets row and
# the ANON_KEY/SERVICE_ROLE_KEY pair are all downstream of it, never the other
# way round.
#
# This file is the single place that says WHERE that value comes from and HOW
# it is read and fingerprinted.  It is shared by both sides of the story, so
# the monitor that COMPARES against the canonical secret and the repair that
# CONVERGES onto it cannot drift apart:
#
#   * kommons tool/jwt-secret-monitor.sh  sources it on the VM (installed
#     beside it in ~/bin by tool/install_jwt_secret_watch.sh).  That is the cron
#     watch: drift detection plus exact-revert auto re-cut.
#   * katalogus tool/dev/repair_jwt_secret_drift.sh  prepends this file to the
#     payload it streams to the VM, so the operator repair reads the same
#     definition.  It resolves this file from the kommons checkout.
#
# Before this file existed the path and the stripping rules were spelled out
# separately in each script; the drift incident of 2026-10-06 was exactly the
# kind of disagreement that invites.
#
# This file is not meant to be executed directly.  Nothing here ever prints a
# secret value: callers report lengths and fingerprints only.
# ============================================================================

# The canonical source: the identity stack's environment file.  KAT_IDENTITY_ENV
# relocates it (tests, a moved checkout); there is only ever ONE default.
KAT_IDENTITY_ENV_DEFAULT=/home/ubuntu/Projects/kommons/supabase-identity/docker/.env

# kat_canonical_env — the .env file that defines the canonical secret.
kat_canonical_env() { printf '%s' "${KAT_IDENTITY_ENV:-$KAT_IDENTITY_ENV_DEFAULT}"; }

# read_env <file> <VAR> — the value of <VAR>, with surrounding quotes and ALL
# whitespace removed.  Shell-quoted and CRLF files then normalize to the same
# string, so trailing whitespace can never make two identical secrets compare
# unequal.  Prints nothing (and succeeds) when the variable is absent, so it is
# safe under `set -e`.
read_env() {
  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- \
      | tr -d '"' | tr -d "[:space:]" ; } || true
}

# kat_canonical_secret — the canonical value, or empty when it cannot be read.
# A caller that gets empty output MUST refuse to act rather than guess.
kat_canonical_secret() { read_env "$(kat_canonical_env)" JWT_SECRET; }

# secret_fp <value> — the short (16 hex) fingerprint used in human reports.
secret_fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# secret_fp_full <value> — the full fingerprint, used as a registry key.
secret_fp_full() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
