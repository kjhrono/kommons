#!/usr/bin/env bash
# verify_consumers.sh — run the gates of the commons package AND every
# consumer that shares its code, so a shell change can never land while
# breaking a game.
#
# Lives in kommons/tool/. Usage from anywhere:
#
#   bash ../kommons/tool/verify_consumers.sh          # all gates
#   bash ../kommons/tool/verify_consumers.sh --quick  # analyze only
#   bash ../kommons/tool/verify_consumers.sh --help
#
# Consumers (edit CONSUMERS below as games join):
#   - the package itself (analyze + test)
#   - examples/probe    (analyze + test, path dep on ../..)
#   - ../kapaxinfiniti   (analyze + test, path dep on ../kommons)
#
# Every project runs even if an earlier one fails; the summary at the end
# lists failures and the exit code is non-zero if anything failed. CI: run
# this single script as the job's step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMONS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

QUICK=0
case "${1:-}" in
  --quick) QUICK=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown flag: $1 (try --help)"; exit 2 ;;
esac

if ! command -v flutter >/dev/null 2>&1; then
  if [ -x "$HOME/Apps/flutter/bin/flutter" ]; then
    export PATH="$HOME/Apps/flutter/bin:$PATH"
  else
    echo "flutter not on PATH (and ~/Apps/flutter not present)" >&2
    exit 2
  fi
fi

# name | directory | gates: a=analyze, t=test
CONSUMERS=(
  "commons|${COMMONS_DIR}|at"
  "probe|${COMMONS_DIR}/examples/probe|at"
  "kapax|${COMMONS_DIR}/../kapaxinfiniti|at"
)

declare -a FAILED=()
declare -a OK=()

run_gate() { # project_dir label command...
  local dir="$1" label="$2"; shift 2
  echo "--- [$label] $(basename "$dir"): $*"
  (cd "$dir" && "$@" 2>&1 | tail -2)
  return ${PIPESTATUS[0]}
}

for entry in "${CONSUMERS[@]}"; do
  IFS='|' read -r name dir gates <<<"$entry"
  echo ""
  echo "=== $name ($dir)"
  if [ ! -d "$dir" ]; then
    FAILED+=("$name (missing directory)")
    continue
  fi
  if [[ "$gates" == *a* ]]; then
    if run_gate "$dir" "$name" flutter analyze >/dev/null; then
      echo "    analyze: OK"
    else
      echo "    analyze: FAILED"
      FAILED+=("$name analyze")
    fi
  fi
  if [[ "$gates" == *t* && $QUICK -eq 0 ]]; then
    if run_gate "$dir" "$name" timeout 500 flutter test >/dev/null; then
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
  echo "ALL GATES GREEN (${#CONSUMERS[@]} consumers$([ $QUICK -eq 1 ] && echo ', analyze-only'))"
  exit 0
fi
echo "FAILURES (${#FAILED[@]}):"
for f in "${FAILED[@]}"; do echo "  - $f"; done
exit 1
