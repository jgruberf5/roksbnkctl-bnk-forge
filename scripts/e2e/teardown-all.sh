#!/usr/bin/env bash
# Tear down EVERYTHING these demos built, in the order the guide prescribes:
# cluster projects first, then the F5 License Proxy, then the Harbor registry.
#
# The order is not cosmetic. The FLP's VSI lives inside the services VPC that the
# Harbor blueprint created and owns, so destroying Harbor first fails on the subnet
# and VPC with `vpc_in_use` and leaves a half-removed deployment behind.
#
#   ./teardown-all.sh
#
# Idempotent: a project that is already gone is skipped, not an error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"

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
  for i in $(seq 1 180); do
    st=$(forge_api GET "/api/projects/$pid" 2>/dev/null \
         | python3 -c 'import sys,json
d=json.load(sys.stdin)
print("%s/%s"%(d.get("deployed_count"),d.get("module_count")))' 2>/dev/null)
    [[ "${st%%/*}" == "0" ]] && { e2e_say "$label: all modules destroyed"; break; }
    sleep 20
  done
  forge_api DELETE "/api/projects/$pid" >/dev/null 2>&1
  e2e_say "$label: project deleted"
}

e2e_head "PHASE 1 — cluster projects"
destroy_project 103 "UC3 (f5e2e-v3-final)"
destroy_project 101 "UC4 (f5e2e-v4-bare)"
destroy_project 95  "UC2 (f5e2e-v2-new-disco)"
# 98 owns f5e2e4, which 101 only adopted — so it must go AFTER 101.
destroy_project 98  "bare disconnected cluster (f5e2e4)"
destroy_project 99  "bare connected cluster (already destroyed)"

e2e_head "PHASE 2 — F5 License Proxy (before Harbor: its VSI is in Harbor's VPC)"
destroy_project 94 "FLP (f5demo-roksbnkctl-flp)"

e2e_head "PHASE 3 — Harbor registry"
destroy_project 92 "Harbor (f5demo-harbor-registry)"

e2e_head "PHASE 4 — the CLI-built cluster (f5e2e6, workspace uc3src)"
if roksbnkctl -w uc3src cluster status >/dev/null 2>&1; then
  roksbnkctl -w uc3src tgw disconnect --auto 2>&1 | tail -2
  roksbnkctl -w uc3src cluster down --auto 2>&1 | tail -5
else
  e2e_say "uc3src workspace has no cluster state"
fi

e2e_head "Remaining state"
timeout 120 ibmcloud ks clusters --output json 2>/dev/null | python3 -c '
import sys,json
r=json.load(sys.stdin); print("  clusters listed:",len(r))
for c in r: print("   ",c.get("name"),c.get("state"))' || true
timeout 120 ibmcloud tg gateways --output json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin);r=d if isinstance(d,list) else d.get("transit_gateways",[])
print("  gateways:",len(r),"/10")
[print("   ",g["name"]) for g in r if "f5e2e" in g["name"]]' || true
e2e_say "teardown script complete"
