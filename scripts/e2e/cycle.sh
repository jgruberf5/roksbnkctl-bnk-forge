#!/usr/bin/env bash
# Run the four use cases end to end, over and over, until one full cycle passes
# every case with no manual intervention.
#
#   ./cycle.sh [max-cycles]        # default 5
#
# WHY THIS EXISTS, AND WHAT IT FIXES
# ----------------------------------
# The use-case scripts work. What kept costing hours was everything AROUND them:
#
#   1. NO PHASE EVER HAD A TIMEOUT. A use case that wedged -- waiting on an ssh
#      that would never answer, a curl with no --max-time, a cluster stuck in
#      `deploying` -- wedged until a human noticed. Every phase here runs under
#      `timeout`, so the worst case is a bounded loss, not an open-ended one.
#   2. SILENCE WAS AMBIGUOUS. A finished run and a dead run look identical from
#      outside. HEARTBEAT is rewritten every 30s with the current phase and its
#      elapsed time, so "nothing is happening" is always distinguishable from
#      "nothing is running".
#   3. FAILURE LEFT WRECKAGE THAT POISONED THE NEXT ATTEMPT. Each cycle tears the
#      use-case projects down before the next begins; a cycle that starts on top
#      of a half-destroyed predecessor measures nothing.
#
# Harbor and the F5 License Proxy are LAB INFRASTRUCTURE, not tests. They are
# built once, before the loop, and torn down after it -- rebuilding them each
# cycle would add ~40 minutes per iteration and test nothing new.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
LOG="$HERE/logs"; mkdir -p "$LOG"
MAX_CYCLES="${1:-5}"
HEARTBEAT="${HEARTBEAT:-$LOG/cycle-heartbeat.txt}"
RESULTS="$LOG/cycle-results.txt"

# Per-phase ceilings, from the measured durations of the passing v1.50.0 run
# (UC2 57m47s was the longest) plus roughly 50% headroom. A phase that exceeds
# these is not slow, it is stuck.
: "${T_UC1:=4800}"; : "${T_UC2:=6000}"; : "${T_UC3:=3600}"; : "${T_UC4:=3600}"
: "${T_TEARDOWN:=5400}"

PHASE="starting"; PHASE_AT=$(date +%s); CYCLE=0
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# The heartbeat runs in its own process so it keeps ticking while a phase blocks.
# Its mtime is the liveness signal: stale file == this driver is dead, full stop.
heartbeat_loop() {
  while :; do
    printf '%s cycle=%s phase=%s elapsed=%ss pid=%s\n' \
      "$(date -u +%s)" "$CYCLE" "$PHASE" "$(( $(date +%s) - PHASE_AT ))" "$$" > "$HEARTBEAT.tmp"
    mv -f "$HEARTBEAT.tmp" "$HEARTBEAT"
    sleep 30
  done
}
heartbeat_loop & HB_PID=$!
# Kill the heartbeat by PID, never `pkill -f heartbeat`: a -f pattern match has
# killed this project's own driving shell three separate times.
cleanup() { kill "$HB_PID" 2>/dev/null; }
trap cleanup EXIT

# phase <name> <timeout-seconds> <logfile> -- <command...>
# Returns 0 pass, 124 timed out (that is `timeout`'s own code, kept distinct so
# the summary can say "stuck" rather than the useless "failed"), else the
# command's status.
phase() {
  local name="$1" secs="$2" logf="$3"; shift 4
  PHASE="$name"; PHASE_AT=$(date +%s)
  say "▶ $name (ceiling ${secs}s) → $logf"
  # --kill-after: some of these block in ssh/curl and ignore a plain TERM.
  timeout --signal=TERM --kill-after=90 "$secs" "$@" > "$logf" 2>&1
  local rc=$? el=$(( $(date +%s) - PHASE_AT ))
  case $rc in
    0)   say "✓ $name passed in ${el}s" ;;
    124) say "✗ $name TIMED OUT after ${el}s — killed. tail:"
         tail -15 "$logf" | sed 's/^/      /' ;;
    *)   say "✗ $name failed (rc=$rc) after ${el}s. tail:"
         tail -15 "$logf" | sed 's/^/      /' ;;
  esac
  printf '%s cycle=%s %s rc=%s elapsed=%ss\n' "$(date -u +%FT%TZ)" "$CYCLE" "$name" "$rc" "$el" >> "$RESULTS"
  return $rc
}

# ---- prerequisites, built once -------------------------------------------
if [[ "${SKIP_PREREQ:-0}" != "1" ]]; then
  # STOP_AFTER=flp is load-bearing: left unset the demo carries straight on into
  # its own disconnected cluster build (steps 4+5), which is UC2's job and would
  # burn a Transit Gateway the use cases need.
  phase "prereq-harbor-flp" 5400 "$LOG/cycle-prereq.log" -- \
    env STOP_AFTER=flp "$HERE/../demos/disconnected-roks-cluster-demo.sh" \
    || { say "FATAL: Harbor/FLP prerequisites did not build — the disconnected cases cannot run"; exit 1; }
fi
PREREQ_ENV="$HERE/../demos/.demo-state/prereq.env"
if [[ -f "$PREREQ_ENV" ]]; then set -a; . "$PREREQ_ENV"; set +a; say "loaded Harbor/FLP handoff from $PREREQ_ENV"
else say "FATAL: no $PREREQ_ENV — the disconnected cases would fail on their HARBOR_IP guard"; exit 1; fi

# ---- the loop -------------------------------------------------------------
while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$(( CYCLE + 1 ))
  say "════════ CYCLE $CYCLE / $MAX_CYCLES ════════"
  failed=0

  # Order respects the Transit Gateway quota: v1 creates a gateway, v3 adopts
  # v1's cluster, and the pair is torn down before v2 creates the next gateway.
  phase "c$CYCLE-uc1-new-connected"      "$T_UC1" "$LOG/cycle$CYCLE-uc1.log" -- "$HERE/v1-new-connected.sh" up      || failed=1
  (( failed )) || phase "c$CYCLE-uc3-existing-connected" "$T_UC3" "$LOG/cycle$CYCLE-uc3.log" -- "$HERE/v3-existing-connected.sh" up || failed=1
  phase "c$CYCLE-uc3-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc3-down.log" -- "$HERE/v3-existing-connected.sh" down || true
  phase "c$CYCLE-uc1-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc1-down.log" -- "$HERE/v1-new-connected.sh" down || true

  if (( ! failed )); then
    phase "c$CYCLE-uc2-new-disconnected"      "$T_UC2" "$LOG/cycle$CYCLE-uc2.log" -- "$HERE/v2-new-disconnected.sh" up      || failed=1
    (( failed )) || phase "c$CYCLE-uc4-existing-disconnected" "$T_UC4" "$LOG/cycle$CYCLE-uc4.log" -- "$HERE/v4-existing-disconnected.sh" up || failed=1
    phase "c$CYCLE-uc4-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc4-down.log" -- "$HERE/v4-existing-disconnected.sh" down || true
    phase "c$CYCLE-uc2-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc2-down.log" -- "$HERE/v2-new-disconnected.sh" down || true
  fi

  if (( ! failed )); then
    say "════════ CYCLE $CYCLE PASSED CLEAN — all four use cases ════════"
    PHASE="passed"; exit 0
  fi
  say "cycle $CYCLE had failures; state torn down, retrying"
done

say "no clean cycle in $MAX_CYCLES attempts — see $RESULTS"
exit 1
