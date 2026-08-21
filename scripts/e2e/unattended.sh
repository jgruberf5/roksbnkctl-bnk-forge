#!/usr/bin/env bash
# Unattended driver: keep running full cycles until TARGET_CLEAN consecutive
# clean ones, restarting the cycle driver if it dies.
#
#   ./unattended.sh
#
# Waits for any in-flight Harbor teardown first, then runs cycle.sh WITHOUT
# SKIP_PREREQ so the first phase rebuilds Harbor and the FLP -- which is also
# what puts fresh module output on the Kubernetes page to watch.
#
# WHY A SUPERVISOR AND NOT JUST cycle.sh
# cycle.sh bounds every phase and heartbeats, but if the driver process itself
# dies -- OOM, a killed terminal, a bad `set -u` on an unset variable in a branch
# that rarely runs -- nothing restarts it and the run silently ends. Unattended,
# that is the difference between 20 hours of progress and 20 hours of nothing.
# This loop notices within a minute and starts the next attempt.
#
# It deliberately does NOT restart on a clean finish or on the attempt ceiling:
# those are answers, not failures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/logs"; mkdir -p "$LOG"
export TARGET_CLEAN="${TARGET_CLEAN:-5}"
MAX_RESTARTS="${MAX_RESTARTS:-20}"
say() { printf '[%s] unattended: %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Liveness, PID-first. The argv-grep form alone produced a FALSE NEGATIVE on
# 2026-08-21 and the supervisor started a SECOND driver while the first was
# plainly running -- two drivers then raced on the same project. The predicate
# itself tests correctly against the real argv, so the root cause is unproven;
# rather than trust a check that has already lied once, ask the kernel about the
# recorded pid and treat argv only as a fallback for a pid we never captured.
alive() {
  local pid n
  pid=$(cat "$LOG/cycle.pid" 2>/dev/null)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  n=$(ps -eo args --no-headers 2>/dev/null | grep -vE 'shell-snapshots|ugrep' | grep -cE 'cycle\.sh' || true)
  (( ${n:-0} > 0 ))
}
# Never launch a second driver, whatever alive() believes. Two cycles on one
# Forge project corrupt each other's state and waste the whole unattended window.
guard_single() {
  local n
  n=$(ps -eo args --no-headers 2>/dev/null | grep -vE 'shell-snapshots|ugrep' | grep -cE 'cycle\.sh' || true)
  (( ${n:-0} == 0 ))
}
done_yet() { grep -q "CLEAN_CYCLE $TARGET_CLEAN of $TARGET_CLEAN" "$LOG/cycle-results.txt" 2>/dev/null; }

say "waiting for any in-flight Harbor teardown"
for _ in $(seq 1 240); do
  ps -eo args --no-headers | grep -vE 'shell-snapshots|ugrep' | grep -qE 'teardown-project\.sh' || break
  command sleep 30
done
say "teardown clear; starting cycles (target $TARGET_CLEAN clean)"

restarts=0
while (( restarts < MAX_RESTARTS )); do
  if done_yet; then say "TARGET REACHED — $TARGET_CLEAN clean cycles"; exit 0; fi
  if ! alive && guard_single; then
    (( restarts++ )) || true
    say "launching cycle.sh (attempt $restarts/$MAX_RESTARTS)"
    # No SKIP_PREREQ: Harbor and the FLP were torn down, so the prereq phase
    # rebuilds them. SKIP_UC1 is never set here -- reusing a project across a
    # restart would make the pass a lie.
    ( cd "$HERE" && setsid nohup ./cycle.sh > "$LOG/cycle-driver.log" 2>&1 < /dev/null & )
    command sleep 45
    ps -eo pid,args --no-headers | grep -vE 'shell-snapshots|ugrep' \
      | awk '/(^| )bash \.\/cycle\.sh|\/cycle\.sh( |$)/ {print $1; exit}' > "$LOG/cycle.pid"
    say "cycle.sh pid $(cat "$LOG/cycle.pid" 2>/dev/null)"
  fi
  command sleep 60
done
say "gave up after $MAX_RESTARTS restarts"
exit 1
