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

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"

# Set by any project left standing or any cluster that outlived its project, so
# an unattended run exits non-zero instead of reporting a clean estate.
LEFTOVERS=0

# destroy_project <id> <label>  — destroy-all, wait for every module, then delete.
destroy_project() {
  local pid="$1" label="$2" mods st i
  if ! forge_api GET "/api/projects/$pid" >/dev/null 2>&1; then
    e2e_say "$label (project $pid) already gone"; return 0
  fi
  e2e_head "Destroying $label (project $pid)"
  forge_api POST "/api/projects/$pid/destroy-all" '{}' >/dev/null 2>&1 \
    || warn "$label: destroy-all returned non-zero, continuing to poll"
  # Poll the project rather than named modules: ids differ per project, and a
  # module that never deployed has nothing to destroy.
  #
  # deployed_count alone is NOT a success signal: a module in destroy_failed
  # leaves deployed_count and moves to failed_count, so a wholly failed destroy
  # looks identical to a clean one. Reading only deployed_count is how project
  # 112 (v143-new-connected) got deleted in 22s with its ROKS cluster, VPC, 3
  # subnets and 3 public gateways still live. Require failed_count == 0 too, and
  # refuse to delete the project otherwise — a project still holding cloud
  # resources is recoverable, a deleted one orphans them with no way to retry.
  for i in $(seq 1 180); do
    st=$(forge_api GET "/api/projects/$pid" 2>/dev/null \
         | python3 -c 'import sys,json
d=json.load(sys.stdin)
print("%s/%s"%(d.get("deployed_count") or 0,d.get("failed_count") or 0))' 2>/dev/null)
    [[ "$st" == "0/0" ]] && { e2e_say "$label: all modules destroyed"; break; }
    sleep 20
  done
  if [[ "$st" != "0/0" ]]; then
    warn "$label: destroy did not finish clean (deployed/failed = ${st:-unknown})"
    warn "$label: NOT deleting the project — it still owns cloud resources."
    warn "$label: inspect it, destroy the failed modules, then re-run this script."
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
