#!/usr/bin/env bash
# Ordered teardown of the v1.45.0 four-use-case run.
#
# Order is not cosmetic, twice over:
#
#   1. The ADOPT projects (v3, v4) must run `bnk down` while their cluster still
#      exists. The bare projects own those clusters, so destroying 118/119 first
#      would leave 120/121 running `bnk down` against a deleted cluster — the
#      failure recorded as roksbnkctl#79, which blocks the module behind it.
#   2. Harbor goes LAST: the FLP's VSI lives inside the services VPC that the
#      harbor module owns, so destroying Harbor first fails on `vpc_in_use`.
#
# Groups run in parallel; stages are barriers.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a

API="$FORGE_URL"
# shellcheck source=forge-destroy-lib.sh
source "$HERE/forge-destroy-lib.sh"
tok() { curl -sk -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token") or "")'; }
T=$(tok)
say()  { printf '   %s\n' "$*" >&2; }
head_() { printf '\n\033[1m══ [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
LEFTOVERS=0

# destroy <id> <label> — destroy-all, wait for every module to reach a terminal
# cleared state, then delete.
#
# It polls MODULE STATUSES, never deployed_count/failed_count: a module in
# `destroying` is counted by neither, so the project summary reads 0/0 while the
# teardown is still running. See forge-destroy-lib.sh — that misread deleted
# project 114 out from under its own in-flight destroy and orphaned two clusters.
destroy() {
  local pid="$1" label="$2" i rc
  curl -sk -o /dev/null -X POST "$API/api/projects/$pid/destroy-all" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{}'
  for i in $(seq 1 240); do
    forge_project_destroyed "$pid"; rc=$?
    (( rc == 0 )) && { say "$label ($pid): every module terminally destroyed"; break; }
    sleep 20
  done
  if (( rc != 0 )); then
    say "!! $label ($pid): destroy did not finish clean — $(forge_project_module_report "$pid")"
    say "!! NOT deleting it — deleting now would cascade away any in-flight destroy task"
    LEFTOVERS=1
    return 1
  fi
  curl -sk -o /dev/null -X DELETE "$API/api/projects/$pid" -H "Authorization: Bearer $T"
  say "$label ($pid): project deleted"
}

stage() {  # stage <name> <id:label>...
  local name="$1"; shift
  head_ "$name"
  local pids=()
  for spec in "$@"; do destroy "${spec%%:*}" "${spec##*:}" & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" || LEFTOVERS=1; done
}

stage "STAGE 1 — adopt projects (bnk down; clusters survive)" \
  8:v3-existing-conn 9:v4-existing-disco

# v1/v2 own their own clusters and are independent of the bare pair, but they are
# held to stage 2 so the whole cluster layer comes down together.
stage "STAGE 2 — projects that own clusters" \
  1:v1-new-connected 6:v2-new-disco 3:bare-connected 7:bare-disconnected

stage "STAGE 3 — F5 License Proxy (its VSI is in Harbor's VPC)" 5:flp
stage "STAGE 4 — Harbor registry" 2:harbor

head_ "Remaining state"
# Check clusters BY NAME. `ibmcloud ks clusters` has reported count:0 over
# demonstrably running clusters in this account; `cluster get` has been right
# every time.
for C in f5e2e1 f5e2e2 f5e2e3 f5e2e4; do
  if timeout 90 ibmcloud ks cluster get --cluster "$C" >/dev/null 2>&1; then
    say "!! cluster $C STILL PRESENT — remove with: ibmcloud ks cluster rm --cluster $C --force-delete-storage -f"
    LEFTOVERS=1
  else
    say "cluster $C: gone"
  fi
done
timeout 120 ibmcloud tg gateways --output json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin); r=d if isinstance(d,list) else d.get("transit_gateways",[])
print("   gateways: %d/10"%len(r))
[print("   !! leftover demo gateway:",g["name"]) for g in r if "f5e2e" in g.get("name","")]'

(( LEFTOVERS )) && { say "teardown INCOMPLETE — see the warnings above"; exit 1; }
say "teardown complete"
