#!/usr/bin/env bash
# All four variants, in the order that respects the Transit Gateway quota.
#
# Variants 1 and 2 each CREATE a gateway; variants 3 and 4 adopt one. The
# account is near its ceiling, so this never holds more than one demo-created
# gateway at a time: create it, use it for both the "new" and the "existing"
# variant of that connectivity mode, then destroy it before the next pair.
#
#   1 (new, connected)      creates cluster + VPC + TGW
#   3 (existing, connected) reuses 1's cluster after `bnk down` — no new quota
#   -- teardown --
#   2 (new, disconnected)   creates cluster + VPC + TGW  [needs Harbor + FLP]
#   4 (existing, disco)     reuses 2's cluster after `bnk down`
#
# Each phase stops the run on failure: a variant deployed onto the wreckage of a
# failed previous one measures nothing and cleans up badly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${E2E_LOG_DIR:-$HERE/logs}"; mkdir -p "$LOG"
ONLY="${1:-all}"

run() {
  local name="$1" script="$2" action="${3:-up}"
  printf '\n\033[1m##### %s (%s) — %s\033[0m\n' "$name" "$action" "$(date -u +%H:%M:%S)"
  if "$HERE/$script" "$action" 2>&1 | tee "$LOG/$name-$action.log"; then
    printf '\033[32m##### %s %s OK\033[0m\n' "$name" "$action"; return 0
  fi
  printf '\033[31m##### %s %s FAILED — see %s\033[0m\n' "$name" "$action" "$LOG/$name-$action.log"
  return 1
}

case "$ONLY" in
  connected)
    run v1 v1-new-connected.sh up      || exit 1
    run v3 v3-existing-connected.sh up || exit 1
    ;;
  disconnected)
    run v2 v2-new-disconnected.sh up      || exit 1
    run v4 v4-existing-disconnected.sh up || exit 1
    ;;
  down)
    run v4 v4-existing-disconnected.sh down
    run v2 v2-new-disconnected.sh down
    run v3 v3-existing-connected.sh down
    run v1 v1-new-connected.sh down
    ;;
  all)
    run v1 v1-new-connected.sh up      || exit 1
    run v3 v3-existing-connected.sh up || exit 1
    run v3 v3-existing-connected.sh down
    run v1 v1-new-connected.sh down    || { echo "gateway not released; stopping before variant 2"; exit 1; }
    run v2 v2-new-disconnected.sh up      || exit 1
    run v4 v4-existing-disconnected.sh up || exit 1
    ;;
  *) echo "usage: $0 [all|connected|disconnected|down]" >&2; exit 2 ;;
esac
