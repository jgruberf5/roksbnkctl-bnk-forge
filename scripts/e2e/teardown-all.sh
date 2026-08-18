#!/usr/bin/env bash
# Tear down EVERYTHING these demos built, in the order the guide prescribes:
# cluster projects first, then the F5 License Proxy, then the Harbor registry.
#
# The order is not cosmetic. The FLP's VSI lives inside the services VPC that the
# Harbor blueprint created and owns, so destroying Harbor first fails on the subnet
# and VPC with `vpc_in_use` and leaves a half-removed deployment behind.
#
#   E2E_EXPECT_GONE="f5uc1 f5uc2 f5uc3 f5uc4" ./teardown-all.sh uc3src uc4src
#
# Idempotent: a project that is already gone is skipped, not an error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
source "$HERE/e2e-lib.sh"
# API/T are what forge-destroy-lib.sh polls with; e2e-lib owns the login.
API="$FORGE_URL"
# shellcheck source=forge-destroy-lib.sh
source "$HERE/forge-destroy-lib.sh"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"

# Set by any project left standing or any cluster that outlived its project, so
# an unattended run exits non-zero instead of reporting a clean estate.
LEFTOVERS=0

# destroy_project <id> <label>  — destroy-all, wait for every module, then delete.
destroy_project() {
  local pid="$1" label="$2" mods i rc=1
  if ! forge_api GET "/api/projects/$pid" >/dev/null 2>&1; then
    e2e_say "$label (project $pid) already gone"; return 0
  fi
  e2e_head "Destroying $label (project $pid)"
  forge_api POST "/api/projects/$pid/destroy-all" '{}' >/dev/null 2>&1 \
    || warn "$label: destroy-all returned non-zero, continuing to poll"
  # Poll the project rather than named modules: ids differ per project, and a
  # module that never deployed has nothing to destroy.
  #
  # The project SUMMARY cannot answer "is the teardown finished?", in two ways:
  #
  #   deployed_count = count(status in ["applied"])
  #   failed_count   = count(status in [... "destroy_failed" ...])
  #
  # A module in destroy_failed leaves deployed_count and lands in failed_count,
  # so reading deployed_count alone made a wholly FAILED destroy look clean —
  # that deleted project 112 in 22s with its cluster, VPC, 3 subnets and 3 public
  # gateways still live. Adding failed_count == 0 fixed that half.
  #
  # It does not fix the other half: a module in `destroying` is in NEITHER set,
  # so a teardown still RUNNING also reports 0/0. On 2026-08-17 that deleted
  # project 114 three seconds before its own in-flight destroy task died on the
  # cascade (PendingRollbackError: the Task row had been deleted), orphaning
  # f5e2e1 and f5e2e4 with their VPCs. See bnk-forge#125.
  #
  # So poll the MODULES and require each to be terminally cleared.
  for i in $(seq 1 180); do
    forge_project_destroyed "$pid"; rc=$?
    (( rc == 0 )) && { e2e_say "$label: every module terminally destroyed"; break; }
    sleep 20
  done
  if (( rc != 0 )); then
    warn "$label: destroy did not finish clean — $(forge_project_module_report "$pid")"
    warn "$label: NOT deleting the project — a delete now would cascade away any"
    warn "$label: in-flight destroy task and orphan whatever it still holds."
    warn "$label: inspect it, re-run the destroy, then re-run this script."
    LEFTOVERS=1
    return 1
  fi
  forge_api DELETE "/api/projects/$pid" >/dev/null 2>&1
  e2e_say "$label: project deleted"
}

# Discover projects rather than hardcoding ids — they change every rebuild, and a
# stale id silently skips a project that is still holding a cluster.
projects_json() { forge_api GET /api/projects 2>/dev/null; }
ids_matching() {  # ids_matching <python-predicate-on-name>
  projects_json | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('projects') or []:
    n = p.get('name') or ''
    if $1: print(p['id'], n)
"
}

e2e_head "PHASE 1 — cluster projects"
# Everything that is not the registry or the proxy. Clusters must go first: they
# attach to the Transit Gateway the registry sits on.
while read -r pid pname; do
  [[ -n "$pid" ]] && destroy_project "$pid" "$pname"
done < <(ids_matching "'harbor' not in n and 'flp' not in n")

e2e_head "PHASE 2 — F5 License Proxy (before Harbor: its VSI is in Harbor's VPC)"
while read -r pid pname; do
  [[ -n "$pid" ]] && destroy_project "$pid" "$pname"
done < <(ids_matching "'flp' in n")

e2e_head "PHASE 3 — Harbor registry"
while read -r pid pname; do
  [[ -n "$pid" ]] && destroy_project "$pid" "$pname"
done < <(ids_matching "'harbor' in n")

e2e_head "PHASE 4 — clusters built with the CLI, outside Forge"
# The adopting project's destroy removed BNK and detached the gateway, but the
# cluster itself belongs to the workspace that created it and Forge cannot reach it.
for WS in "$@"; do
  if [[ -d "$HOME/.roksbnkctl/$WS" ]]; then
    e2e_say "workspace $WS: tgw disconnect + cluster down"
    roksbnkctl -w "$WS" tgw disconnect --auto 2>&1 | tail -2
    roksbnkctl -w "$WS" cluster down --auto 2>&1 | tail -4
  else
    e2e_say "workspace $WS not present — skipping"
  fi
done

e2e_head "Remaining state"
# Check clusters BY NAME, never with `ibmcloud ks clusters`.
#
# That list endpoint reports `count: 0` while clusters are demonstrably running —
# it did so over a live f5uc2 (6 workers, state=warning) immediately after this
# script had reported the estate clean. `cluster get --cluster <name>` has been
# right every time. A teardown that trusts the list will tell you it removed
# everything while leaving a cluster billing.
#
# Pass the cluster names to check via E2E_EXPECT_GONE.
for C in ${E2E_EXPECT_GONE:-}; do
  if timeout 90 ibmcloud ks cluster get --cluster "$C" >/dev/null 2>&1; then
    st=$(timeout 90 ibmcloud ks cluster get --cluster "$C" --output json 2>/dev/null \
         | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("state"),d.get("workerCount"),"workers")')
    warn "cluster $C STILL PRESENT: $st"
    warn "  a module's destroy failed and the cluster outlived its project."
    warn "  remove it with: ibmcloud ks cluster rm --cluster $C --force-delete-storage -f"
    warn "  then check for a leaked VPC: ibmcloud is vpcs | grep $C"
    LEFTOVERS=1
  else
    e2e_say "cluster $C: gone"
  fi
done
timeout 120 ibmcloud tg gateways --output json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin);r=d if isinstance(d,list) else d.get("transit_gateways",[])
print("  gateways:",len(r),"/10")
[print("   ",g["name"]) for g in r if "f5e2e" in g["name"]]' || true
if (( LEFTOVERS )); then
  warn "teardown INCOMPLETE — see the warnings above"
  exit 1
fi
e2e_say "teardown script complete"
