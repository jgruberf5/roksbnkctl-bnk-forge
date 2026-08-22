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
MAX_CYCLES="${1:-40}"
# How many CLEAN cycles are required before this exits successfully. Unattended
# runs want repeatability, not a single lucky pass: one green cycle proves the
# path works, five prove it is not flaky. UC2 failed once on a stuck pod that
# passed on the next attempt -- exactly the class of thing a single cycle hides.
TARGET_CLEAN="${TARGET_CLEAN:-5}"
CLEAN=0
HEARTBEAT="${HEARTBEAT:-$LOG/cycle-heartbeat.txt}"
RESULTS="$LOG/cycle-results.txt"

# Per-phase ceilings, from the measured durations of the passing v1.50.0 run
# (UC2 57m47s was the longest) plus roughly 50% headroom. A phase that exceeds
# these is not slow, it is stuck.
: "${T_UC1:=4800}"; : "${T_UC2:=6000}"; : "${T_UC3:=3600}"; : "${T_UC4:=3600}"
: "${T_TEARDOWN:=5400}"

PHASE_FILE="$LOG/cycle-phase.txt"
CYCLE=0
set_phase() {  # the only writer; the heartbeat is the only reader
  printf '%s %s %s\n' "$CYCLE" "$1" "$(date +%s)" > "$PHASE_FILE.tmp"
  mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"
}
set_phase starting
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# The heartbeat runs in its own process so it keeps ticking while a phase blocks.
# Its mtime is the liveness signal: stale file == this driver is dead, full stop.
DRIVER_PID=$$
heartbeat_loop() {
  local c ph at
  while :; do
    read -r c ph at < "$PHASE_FILE" 2>/dev/null || { c=?; ph=?; at=$(date +%s); }
    printf '%s cycle=%s phase=%s elapsed=%ss driver_pid=%s\n' \
      "$(date -u +%s)" "$c" "$ph" "$(( $(date +%s) - at ))" "$DRIVER_PID" > "$HEARTBEAT.tmp"
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
  set_phase "$name"; PHASE_AT=$(date +%s)
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
  # "up flp" -- the stop phase is the demo's SECOND POSITIONAL ARGUMENT, not an
  # environment variable (STOP_AFTER="${2:-all}"). Passing it as `env STOP_AFTER=flp`
  # was silently overwritten by that default, so the demo carried on into step 4/4
  # and built a disconnected cluster that then failed at cluster-register -- work
  # that is UC2's job and that burns a Transit Gateway the use cases need.
  phase "prereq-harbor-flp" 5400 "$LOG/cycle-prereq.log" -- \
    "$HERE/../demos/disconnected-roks-cluster-demo.sh" up flp \
    || { say "FATAL: Harbor/FLP prerequisites did not build — the disconnected cases cannot run"; exit 1; }
fi
PREREQ_ENV="$HERE/../demos/.demo-state/prereq.env"
if [[ -f "$PREREQ_ENV" ]]; then set -a; . "$PREREQ_ENV"; set +a; say "loaded Harbor/FLP handoff from $PREREQ_ENV"
else say "FATAL: no $PREREQ_ENV — the disconnected cases would fail on their HARBOR_IP guard"; exit 1; fi

# UC3 and UC4 adopt BARE clusters -- ones with no BNK on them -- not the cluster
# the preceding variant just built. make-bare-cluster.sh spells out why: an
# adopting project gets a fresh deployment-scoped /work, so its terraform state is
# empty and `bnk up` plans a full 64-resource install over an install already
# there. It runs ~13 minutes and exits 1. BNK cannot be stripped afterwards
# either: destroying bnk-install cascades into cluster-create and takes the
# cluster with it.
#
# Handing UC3 the UC1 cluster failed differently and just as fatally -- `bnkforge
# register` refuses a cluster another Forge project already holds (roksbnkctl
# v1.42.0+), so it died at bnkforge-register in 116s. run-all.sh has always had
# this same gap; it never produced a bare cluster, and cycle.sh inherited that.
#
# Only the E2E_* names survive `set -a; . demos/.env` sourcing after the caller's
# environment -- see the header of v3-existing-connected.sh.
export E2E_V3_CLUSTER="f5e2e3"  E2E_V3_PREFIX="f5e2e3"
export E2E_V4_CLUSTER="f5e2e4"  E2E_V4_PREFIX="f5e2e4"

# CIDRs, chosen against what is actually live in this shared account:
#   10.243 Harbor + FLP services VPC (mine, persistent)   10.244 UC1   10.245 UC2
#   10.246 bnk-artifactory-vpc (not mine)   10.247/10.248 peer session roksbnkctl-f6
# The v1.50.0 run used 10.246/10.247 for the bare pair; both are now taken.
BARE_CONN_CIDR="${BARE_CONN_CIDR:-10.249.0.0/16}"
BARE_DISC_CIDR="${BARE_DISC_CIDR:-10.250.0.0/16}"
: "${T_BARE:=5400}"

# ---- the loop -------------------------------------------------------------
while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$(( CYCLE + 1 ))
  say "════════ CYCLE $CYCLE / $MAX_CYCLES ════════"
  failed=0

  # Do not spend a cycle while Forge is unreachable. On 2026-08-22 Forge briefly
  # returned non-JSON from /api/auth/login; every phase then failed in under a
  # second and the loop burned cycles 1-4 in EIGHTEEN SECONDS. A longer outage
  # would exhaust all 40 attempts in minutes and end an unattended run that had
  # nothing wrong with it.
  #
  # Wait for Forge instead. A cycle costs ~4 hours, so spending up to 30 minutes
  # confirming the target is alive is free by comparison.
  _wait_forge() {
    local i tok
    for i in $(seq 1 60); do
      tok=$(curl -sk --max-time 20 -X POST "$FORGE_URL/api/auth/login" \
              -H 'Content-Type: application/json' \
              -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" 2>/dev/null \
            | jq -r '.token // empty' 2>/dev/null)
      [[ -n "$tok" ]] && { (( i > 1 )) && say "Forge reachable again after $(( (i-1) * 30 ))s"; return 0; }
      (( i == 1 )) && say "Forge is not authenticating — holding this cycle rather than burning it"
      command sleep 30
    done
    say "Forge still unreachable after 30m — proceeding anyway so the failure is recorded"
    return 1
  }
  _wait_forge || true

  # RECLAIM before building. A project left behind by a failed teardown blocks
  # every later cycle: `POST /api/stacks/releases/<n>/projects` returns
  # "A project with this name already exists" and the phase dies in ~11 seconds.
  #
  # That is not hypothetical. Cycle 7's cluster-up timed out (exit 124), its
  # teardown then failed deleting a subnet because the half-built cluster still
  # held it, and the project was correctly NOT deleted -- a destroy that did not
  # finish must never be followed by a DELETE, or the cascade orphans whatever it
  # still holds (bnk-forge#125). But nothing ever cleared it afterwards, so cycles
  # 8 and 9 both died on the leftover name having each spent ~50 minutes on UC1
  # first.
  #
  # teardown-project.sh is idempotent: a project that is already gone exits 0, and
  # one whose modules will not destroy still refuses to delete. So this is safe to
  # run unconditionally, and it converts a permanently wedged run into one lost
  # cycle.
  for _p in f5e2e-v1-new-connected f5e2e-v3-existing-conn f5e2e-bare-connected \
            f5e2e-v2-new-disco f5e2e-v4-existing-disco f5e2e-bare-disconnected; do
    "$HERE/teardown-project.sh" "$_p" >> "$LOG/cycle$CYCLE-reclaim.log" 2>&1 || \
      say "reclaim: $_p did not clear — see cycle$CYCLE-reclaim.log"
  done

  # Order respects the Transit Gateway quota: UC1 creates a gateway, UC2 creates
  # the next, and the first is released before the second is made. The bare
  # clusters adopt the shared bnkci-testing gateway (existing_transit_gateway),
  # so they cost no quota. Peak is one demo-created gateway at a time.
  if [[ "${SKIP_UC1:-0}" == "1" ]]; then
    say "SKIP_UC1=1 — reusing the UC1 project already standing"
  else
    phase "c$CYCLE-uc1-new-connected" "$T_UC1" "$LOG/cycle$CYCLE-uc1.log" -- "$HERE/v1-new-connected.sh" up || failed=1
  fi
  (( failed )) || phase "c$CYCLE-bare-connected" "$T_BARE" "$LOG/cycle$CYCLE-bare-conn.log" -- \
      "$HERE/make-bare-cluster.sh" connected f5e2e3 "$BARE_CONN_CIDR" || failed=1
  # Release the bare cluster's Forge registration before UC3 adopts it. The bare
  # project registered it on creation, and since roksbnkctl v1.42.0 `bnkforge
  # register` REFUSES a cluster another project holds rather than moving it, so
  # UC3 dies at `step 'bnkforge-register' failed (exit 1)` in 35s. CONSTRAINTS.md
  # prescribes exactly this step; make-bare-cluster.sh's last line says so too.
  (( failed )) || phase "c$CYCLE-release-f5e2e3" 300 "$LOG/cycle$CYCLE-release-conn.log" -- \
      "$HERE/release-registration.sh" f5e2e3 || failed=1
  (( failed )) || phase "c$CYCLE-uc3-existing-connected" "$T_UC3" "$LOG/cycle$CYCLE-uc3.log" -- \
      "$HERE/v3-existing-connected.sh" up || failed=1

  phase "c$CYCLE-uc3-down"       "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc3-down.log"  -- "$HERE/v3-existing-connected.sh" down || true
  phase "c$CYCLE-bare-conn-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-bare-conn-down.log" -- "$HERE/teardown-project.sh" f5e2e-bare-connected || true
  phase "c$CYCLE-uc1-down"       "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc1-down.log"  -- "$HERE/v1-new-connected.sh" down || true

  if (( ! failed )); then
    phase "c$CYCLE-uc2-new-disconnected" "$T_UC2" "$LOG/cycle$CYCLE-uc2.log" -- "$HERE/v2-new-disconnected.sh" up || failed=1
    (( failed )) || phase "c$CYCLE-bare-disconnected" "$T_BARE" "$LOG/cycle$CYCLE-bare-disc.log" -- \
        "$HERE/make-bare-cluster.sh" disconnected f5e2e4 "$BARE_DISC_CIDR" || failed=1
    (( failed )) || phase "c$CYCLE-release-f5e2e4" 300 "$LOG/cycle$CYCLE-release-disc.log" -- \
        "$HERE/release-registration.sh" f5e2e4 || failed=1
    (( failed )) || phase "c$CYCLE-uc4-existing-disconnected" "$T_UC4" "$LOG/cycle$CYCLE-uc4.log" -- \
        "$HERE/v4-existing-disconnected.sh" up || failed=1

    phase "c$CYCLE-uc4-down"       "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc4-down.log"  -- "$HERE/v4-existing-disconnected.sh" down || true
    phase "c$CYCLE-bare-disc-down" "$T_TEARDOWN" "$LOG/cycle$CYCLE-bare-disc-down.log" -- "$HERE/teardown-project.sh" f5e2e-bare-disconnected || true
    phase "c$CYCLE-uc2-down"       "$T_TEARDOWN" "$LOG/cycle$CYCLE-uc2-down.log"  -- "$HERE/v2-new-disconnected.sh" down || true
  fi

  # SKIP_UC1 applies to the first cycle only; a retry must build its own.
  SKIP_UC1=0

  if (( ! failed )); then
    CLEAN=$(( CLEAN + 1 ))
    say "════════ CYCLE $CYCLE PASSED CLEAN — $CLEAN/$TARGET_CLEAN ════════"
    printf '%s CLEAN_CYCLE %s of %s (cycle=%s)\n' "$(date -u +%FT%TZ)" "$CLEAN" "$TARGET_CLEAN" "$CYCLE" >> "$RESULTS"
    if (( CLEAN >= TARGET_CLEAN )); then
      say "════════ $TARGET_CLEAN CLEAN CYCLES — DONE ════════"
      set_phase passed; exit 0
    fi
    say "continuing: $(( TARGET_CLEAN - CLEAN )) more clean cycle(s) required"
    continue
  fi
  (( CLEAN > 0 )) && say "streak broken at $CLEAN clean cycle(s) — restarting the count"
  CLEAN=0
  say "cycle $CYCLE had failures; state torn down, retrying"
done

say "only $CLEAN/$TARGET_CLEAN clean cycles in $MAX_CYCLES attempts — see $RESULTS"
exit 1
