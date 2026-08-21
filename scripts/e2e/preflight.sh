#!/usr/bin/env bash
# Executable form of CONSTRAINTS.md. Run before a cycle; exits non-zero on any
# blocker.
#
# WHY: every failure in the 2026-08-21 run was a documented precondition that
# nothing checked. The answers were in CONSTRAINTS.md and in make-bare-cluster.sh's
# own output, and were read only after each failure -- three times, at roughly 45
# minutes each. A constraint that lives only in prose gets skipped; one that exits
# non-zero does not.
#
#   ./preflight.sh [bare-conn-cidr] [bare-disc-cidr]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
CONN_CIDR="${1:-${BARE_CONN_CIDR:-10.249.0.0/16}}"
DISC_CIDR="${2:-${BARE_DISC_CIDR:-10.250.0.0/16}}"
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

echo "── Preflight ─────────────────────────────────────────"

# 1. Forge reachable, with retry: a single failed login is not evidence of a
#    broken Forge, and treating it as one cost a cycle (release-registration rc=2).
T=""
for _t in 1 2 3; do
  T=$(curl -sk --max-time 30 -X POST "$FORGE_URL/api/auth/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" 2>/dev/null | jq -r '.token//empty')
  [[ -n "$T" ]] && break; command sleep 5
done
[[ -n "$T" ]] && ok "Forge auth at $FORGE_URL" || { bad "cannot authenticate to $FORGE_URL"; exit 1; }

# 2. Catalog self-consistency. A blueprint pinning a module version that does not
#    exist fails at the API with "Required modules missing from catalog", and a
#    blueprint wiring an input the pinned version lacks has it SILENTLY DROPPED.
if python3 "$HERE/../check-catalog.py" >/tmp/pf-cat.$$ 2>&1; then
  ok "catalog consistent — $(tail -1 /tmp/pf-cat.$$ | cut -c1-60)"
else
  bad "catalog inconsistent:"; sed 's/^/        /' /tmp/pf-cat.$$
fi
rm -f /tmp/pf-cat.$$

# 3. Lab prerequisites. The disconnected variants die on their own ${HARBOR_IP:?}
#    guard within a second if this handoff is missing.
PRE="$HERE/../demos/.demo-state/prereq.env"
if [[ -f "$PRE" ]]; then
  miss=""
  for k in HARBOR_IP HARBOR_CA HARBOR_PIN FLP_IP FLP_CA; do grep -q "^$k=" "$PRE" || miss+="$k "; done
  [[ -z "$miss" ]] && ok "prereq.env complete (Harbor + FLP handoff)" || bad "prereq.env missing: $miss"
else
  bad "no $PRE — run the demo through 'up flp' first (SKIP_PREREQ=0)"
fi
projs=$(curl -sk --max-time 40 "$FORGE_URL/api/projects" -H "Authorization: Bearer $T" | jq -r '(.projects//.)[]|"\(.id):\(.name)"')
grep -q 'harbor' <<<"$projs" && ok "Harbor project standing" || bad "no Harbor project — UC2/UC4 cannot run"
grep -q 'flp'    <<<"$projs" && ok "FLP project standing"    || bad "no FLP project — UC2/UC4 cannot run"

# 4. Transit Gateway headroom. Quota is 10 and shared with other sessions; a cycle
#    needs one for UC1 and later one for UC2 (never both at once).
gws=$(timeout 120 ibmcloud tg gateways --output json 2>/dev/null \
      | jq -r 'if type=="array" then . else .transit_gateways end|.[].name')
n=$(grep -c . <<<"$gws")
if   (( n <= 8 )); then ok "Transit Gateways ${n}/10 — room for the cycle"
elif (( n == 9 )); then warn "Transit Gateways 9/10 — one spare; a failed teardown will wall the next create"
else bad "Transit Gateways ${n}/10 — no room to create one"; fi

# 5. CIDR collisions. An overlapping prefix on the shared gateway does NOT fail
#    cleanly: pulls succeed and time out at random on every node, so it reads as a
#    flaky registry rather than a routing conflict.
live=$(timeout 150 ibmcloud is vpcs --output json 2>/dev/null | jq -r '.[]|"\(.name)\t\(.id)"')
allpfx=""
while IFS=$'\t' read -r vn vid; do
  [[ -z "$vid" ]] && continue
  for c in $(timeout 60 ibmcloud is vpc-address-prefixes "$vid" --output json 2>/dev/null | jq -r '.[].cidr'); do
    allpfx+="$c|$vn"$'\n'
  done
done <<<"$live"
for want in "$CONN_CIDR" "$DISC_CIDR"; do
  oct=$(cut -d. -f2 <<<"$want")
  hit=$(grep -E "^10\.$oct\." <<<"$allpfx" | head -1)
  [[ -n "$hit" ]] && bad "$want collides with ${hit##*|} (${hit%%|*})" || ok "$want free"
done

# 6. Stale registrations. `bnkforge register` REFUSES a cluster another project
#    holds (roksbnkctl v1.42.0+), so a leftover registration fails the adopting
#    variant 45 minutes downstream at step 'bnkforge-register'.
regs=$(curl -sk --max-time 40 "$FORGE_URL/api/k8s/clusters" -H "Authorization: Bearer $T" | jq -r '(.clusters//.)[]?.name')
for c in f5e2e3 f5e2e4; do
  grep -qx "$c" <<<"$regs" && bad "$c still registered — release it (./release-registration.sh $c)" || ok "$c unregistered"
done

# 7. Leftover projects that would collide by name.
for pn in f5e2e-bare-connected f5e2e-bare-disconnected f5e2e-v3-existing-conn f5e2e-v4-existing-disco; do
  grep -q "$pn" <<<"$projs" && warn "project $pn already exists — the cycle will adopt or collide with it"
done

echo "──────────────────────────────────────────────────────"
(( FAIL )) && { echo "preflight FAILED — fix the above before spending 45 minutes on a cluster"; exit 1; }
echo "preflight OK"
