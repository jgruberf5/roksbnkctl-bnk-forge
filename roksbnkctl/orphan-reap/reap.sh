#!/usr/bin/env bash
# Delete the orphans that orphan-scan found. DESTRUCTIVE.
#
# It acts only on an inventory produced by orphan-scan, and re-checks every name
# against the prefix allowlist before touching it. That re-check is deliberate
# duplication: the inventory arrives through Forge's module-output wiring, and a
# deleter should not take its target list entirely on trust from the layer that
# hands it over.
#
# WHY THE CONFIRMATION IS CHECKED HERE AND NOT LEFT TO `enabled: false`
# The obvious design ships this module optional-and-disabled and lets the
# operator enable it. bnk-forge#120 is exactly the bug where Forge dispatched a
# module that was explicitly enabled:false, and neither cancel nor deleting the
# project stopped the container — that is how cluster f5e2e5 came to exist with
# nothing in Forge representing it. A cluster-deleting module must not stake
# safety on the orchestration layer's opinion about whether to call it. So the
# guard is in-band: a spurious dispatch finds ORPHAN_CONFIRM unset and exits 0
# having done nothing.
set -uo pipefail

say() { printf '%s\n' "$*" >&2; }

CONFIRM="${ORPHAN_CONFIRM:-}"
if [[ "$CONFIRM" != "DELETE" ]]; then
  say "== orphan-reap: ORPHAN_CONFIRM is not 'DELETE' (got ${CONFIRM:-<empty>}) — nothing will be deleted"
  say "== this is the safe default. Set it to DELETE only when you mean it."
  exit 0
fi

: "${ORPHAN_NAME_PREFIXES:?set ORPHAN_NAME_PREFIXES — refusing to reap without an allowlist}"
: "${IBMCLOUD_API_KEY:?set IBMCLOUD_API_KEY}"
: "${ORPHAN_REGION:?set ORPHAN_REGION}"
API_VERSION="${ORPHAN_API_VERSION:-2026-01-01}"

PREFIX_RE=$(printf '%s' "$ORPHAN_NAME_PREFIXES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | paste -sd'|' -)
[[ -n "$PREFIX_RE" ]] || { say "ORPHAN_NAME_PREFIXES contained no usable prefix"; exit 2; }

CLUSTERS="${ORPHAN_CLUSTER_NAMES:-}"
VPCS="${ORPHAN_VPC_IDS:-}"
GWS="${ORPHAN_GATEWAY_IDS:-}"
if [[ -z "$CLUSTERS$VPCS$GWS" ]]; then
  say "== nothing in the inventory — orphan-scan found no orphans. Done."
  exit 0
fi

TOKEN=$(curl -s --max-time 60 -X POST https://iam.cloud.ibm.com/identity/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' \
  --data-urlencode "apikey=$IBMCLOUD_API_KEY" | jq -r '.access_token // empty')
[[ -n "$TOKEN" ]] || { say "could not get an IAM token"; exit 1; }
iam() { curl -s --max-time 120 -H "Authorization: Bearer $TOKEN" "$@"; }
VPCBASE="https://${ORPHAN_REGION}.iaas.cloud.ibm.com/v1"
Q="version=${API_VERSION}&generation=2"

FAILED=0
guard() {  # guard <name> — refuse anything outside the allowlist
  if [[ ! "$1" =~ ^(${PREFIX_RE}) ]]; then
    say "   REFUSING $1 — does not match the allowlist ($PREFIX_RE)"
    FAILED=1; return 1
  fi
  return 0
}

# Clusters first: a VPC cannot be deleted while a cluster still lives in it.
IFS=',' read -ra CL <<< "$CLUSTERS"
SUBMITTED=()
for name in "${CL[@]}"; do
  [[ -z "$name" ]] && continue
  guard "$name" || continue
  say "== deleting cluster $name"
  SUBMITTED+=("$name")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "https://containers.cloud.ibm.com/global/v1/clusters/${name}?deleteResources=true")
  case "$code" in 200|201|202|204|404) say "   accepted (HTTP $code)";; *) say "   FAILED (HTTP $code)"; FAILED=1;; esac
done

# A cluster delete is asynchronous. Deleting its VPC while the workers are still
# going away fails on vpc_in_use, so wait for the clusters to actually disappear
# before touching any network. Verified BY NAME: the cluster list endpoint has
# reported count:0 over demonstrably running clusters in this account.
# Wait only on clusters actually SUBMITTED for deletion. Waiting on the raw
# inventory meant one refused name sent this into a 30-minute poll for a cluster
# nothing had asked to delete.
if (( ${#SUBMITTED[@]} )); then
  say "== waiting for ${#SUBMITTED[@]} cluster(s) to go"
  for _ in $(seq 1 90); do
    left=0
    for name in "${SUBMITTED[@]}"; do
      [[ -z "$name" ]] && continue
      c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "Authorization: Bearer $TOKEN" \
          "https://containers.cloud.ibm.com/global/v2/getCluster?cluster=${name}")
      [[ "$c" == "200" ]] && left=$((left+1))
    done
    (( left == 0 )) && { say "   all gone"; break; }
    sleep 20
  done
fi

# VPC contents before the VPC: subnets and public gateways hold it open.
IFS=',' read -ra VP <<< "$VPCS"
for vid in "${VP[@]}"; do
  [[ -z "$vid" ]] && continue
  vname=$(iam "$VPCBASE/vpcs/$vid?$Q" | jq -r '.name // empty')
  [[ -n "$vname" ]] || { say "== vpc $vid already gone"; continue; }
  guard "$vname" || continue
  say "== emptying vpc $vname"
  for sid in $(iam "$VPCBASE/subnets?$Q&limit=100" | jq -r --arg v "$vid" '.subnets[]|select(.vpc.id==$v)|.id'); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "Authorization: Bearer $TOKEN" "$VPCBASE/subnets/$sid?$Q")
    say "   subnet $sid -> HTTP $c"
  done
  for gid in $(iam "$VPCBASE/public_gateways?$Q&limit=100" | jq -r --arg v "$vid" '.public_gateways[]|select(.vpc.id==$v)|.id'); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "Authorization: Bearer $TOKEN" "$VPCBASE/public_gateways/$gid?$Q")
    say "   public gateway $gid -> HTTP $c"
  done
  sleep 15
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "Authorization: Bearer $TOKEN" "$VPCBASE/vpcs/$vid?$Q")
  case "$code" in 200|202|204|404) say "   vpc $vname deleted (HTTP $code)";; *) say "   vpc $vname FAILED (HTTP $code)"; FAILED=1;; esac
done

# Gateways last: their connections must go first, and a cluster VPC may still
# have been attached until a moment ago.
IFS=',' read -ra GW <<< "$GWS"
for gid in "${GW[@]}"; do
  [[ -z "$gid" ]] && continue
  gname=$(iam "https://transit.cloud.ibm.com/v1/transit_gateways/$gid?version=$API_VERSION" | jq -r '.name // empty')
  [[ -n "$gname" ]] || { say "== gateway $gid already gone"; continue; }
  guard "$gname" || continue
  say "== deleting gateway $gname"
  for cid in $(iam "https://transit.cloud.ibm.com/v1/transit_gateways/$gid/connections?version=$API_VERSION" | jq -r '.connections[]?.id'); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "Authorization: Bearer $TOKEN" \
        "https://transit.cloud.ibm.com/v1/transit_gateways/$gid/connections/$cid?version=$API_VERSION")
    say "   connection $cid -> HTTP $c"
  done
  sleep 20
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "Authorization: Bearer $TOKEN" \
      "https://transit.cloud.ibm.com/v1/transit_gateways/$gid?version=$API_VERSION")
  case "$code" in 200|202|204|404) say "   gateway $gname deleted (HTTP $code)";; *) say "   gateway $gname FAILED (HTTP $code)"; FAILED=1;; esac
done

(( FAILED )) && { say "== orphan-reap finished WITH FAILURES — re-run the scan to see what is left"; exit 1; }
say "== orphan-reap complete"
