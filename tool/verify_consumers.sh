#!/usr/bin/env bash
# verify_consumers.sh — run the gates of the commons package AND every
# consumer that shares its code, so a shell change can never land while
# breaking a game.
#
# Lives in kommons/tool/. Usage from anywhere:
#
#   bash ../kommons/tool/verify_consumers.sh          # all gates
#   bash ../kommons/tool/verify_consumers.sh --quick  # analyze only
#   bash ../kommons/tool/verify_consumers.sh --list   # print registered consumers
#   bash ../kommons/tool/verify_consumers.sh --tag v0.2.0 [--quick]
#         # gate the tagged snapshot instead of the working tree: the
#         # package itself runs from `git archive` of the tag, and every
#         # other consumer gets a disposable copy whose kommons dep is
#         # overridden onto that snapshot — i.e. "does this consumer
#         # adopt this tag?". The working tree is never touched.
#   bash ../kommons/tool/verify_consumers.sh --help
#
# Consumers (edit CONSUMERS below as games join):
#   - the package itself (analyze + test)
#   - examples/probe    (analyze + test, path dep on ../..)
#
# Every project runs even if an earlier one fails; the summary at the end
# lists failures and the exit code is non-zero if anything failed. CI: run
# this single script as the job's step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMONS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# name | directory | gates: a=analyze, t=test
CONSUMERS=(
  "commons|${COMMONS_DIR}|at"
  "probe|${COMMONS_DIR}/examples/probe|at"
)

QUICK=0
TAG=
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --tag) TAG="${2:-}"; [ -n "$TAG" ] || { echo "--tag needs a ref" >&2; exit 2; }; shift ;;
    --tag=*) TAG="${1#--tag=}" ;;
    --list)
      # Who is wired into the gate — the same list every run executes.
      for entry in "${CONSUMERS[@]}"; do
        IFS='|' read -r name dir gates <<<"$entry"
        case "$gates" in
          at|ta) g="analyze + test" ;;
          a) g="analyze" ;;
          t) g="test" ;;
          *) g="$gates" ;;
        esac
        echo "$name [$g] $dir"
      done
      exit 0 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

if ! command -v flutter >/dev/null 2>&1; then
  if [ -x "$HOME/Apps/flutter/bin/flutter" ]; then
    export PATH="$HOME/Apps/flutter/bin:$PATH"
  else
    echo "flutter not on PATH (and ~/Apps/flutter not present)" >&2
    exit 2
  fi
fi

declare -a FAILED=()
declare -a OK=()

# Tag mode: materialize the ref into a scratch snapshot via git archive
# (read-only on the repo, no worktree metadata) and clean up on exit.
if [ -n "$TAG" ]; then
  REV="$(git -C "$COMMONS_DIR" rev-parse --verify --quiet "$TAG^{commit}")" || {
    echo "no such ref: $TAG (looked in $COMMONS_DIR)" >&2
    exit 2
  }
  TAGTMP="$(mktemp -d)"
  trap 'rm -rf "$TAGTMP"' EXIT
  SNAPSHOT="$TAGTMP/kommons"
  mkdir -p "$SNAPSHOT"
  git -C "$COMMONS_DIR" archive "$REV" | tar -x -C "$SNAPSHOT"
  echo "tag mode: kommons $TAG (${REV:0:8}) — working tree untouched"
fi

run_gate() { # project_dir label command...
  local dir="$1" label="$2"; shift 2
  echo "--- [$label] $(basename "$dir"): $*"
  (cd "$dir" && "$@" 2>&1 | tail -2)
  return ${PIPESTATUS[0]}
}

for entry in "${CONSUMERS[@]}"; do
  IFS='|' read -r name dir gates <<<"$entry"
  rundir="$dir"
  if [ -n "$TAG" ]; then
    if [ "$dir" = "$COMMONS_DIR" ]; then
      rundir="$SNAPSHOT" # the package itself, exactly as tagged
    else
      # Consumer: a disposable copy whose kommons dep is overridden onto
      # the tagged snapshot — the working tree is never modified.
      rundir="$TAGTMP/$name"
      mkdir -p "$rundir"
      (cd "$dir" && tar --exclude=.dart_tool --exclude=build --exclude=.git -cf - .) \
        | (cd "$rundir" && tar -xf -)
      printf '\ndependency_overrides:\n  kommons:\n    path: %s\n' "$SNAPSHOT" \
        >> "$rundir/pubspec.yaml"
    fi
  fi
  echo ""
  echo "=== $name ($rundir)"
  if [ ! -d "$rundir" ]; then
    FAILED+=("$name (missing directory)")
    continue
  fi
  if [ -n "$TAG" ]; then
    if run_gate "$rundir" "$name" flutter pub get >/dev/null; then
      echo "    pub get: OK"
    else
      echo "    pub get: FAILED"
      FAILED+=("$name pub get")
      continue
    fi
  fi
  if [[ "$gates" == *a* ]]; then
    if run_gate "$rundir" "$name" flutter analyze >/dev/null; then
      echo "    analyze: OK"
    else
      echo "    analyze: FAILED"
      FAILED+=("$name analyze")
    fi
  fi
  if [[ "$gates" == *t* && $QUICK -eq 0 ]]; then
    if run_gate "$rundir" "$name" timeout 500 flutter test >/dev/null; then
      echo "    test:    OK"
    else
      echo "    test:    FAILED"
      FAILED+=("$name test")
    fi
  fi
done

echo ""
echo "======================================="
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "ALL GATES GREEN (${#CONSUMERS[@]} consumers$([ $QUICK -eq 1 ] && echo ', analyze-only')${TAG:+ @ $TAG})"
  exit 0
fi
echo "FAILURES (${#FAILED[@]}):"
for f in "${FAILED[@]}"; do echo "  - $f"; done
exit 1
