#!/usr/bin/env bash
# VARIANT 3 — EXISTING VPC + cluster + Transit Gateway, BNK connected.
#
# The cluster and the gateway already exist and are never created or destroyed
# here; roksbnkctl adopts them. BNK installs from F5's registry with direct
# licensing — no Harbor, no mirror, no License Proxy.
#
# This is the variant that had a blueprint but had never once been run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-up}"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

BP_ID="ibm-roks-existing-bnk-roksbnkctl"
BP_DIR="roks-existing-cluster"
PROJECT="${E2E_V3_PROJECT:-f5e2e-v3-existing-conn}"
CLUSTER="${E2E_V3_CLUSTER:-$CLUSTER_NAME}"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"

if [[ "$ACTION" == "down" ]]; then
  e2e_teardown "$PROJECT"; exit $?
fi

e2e_head "Variant 3 — EXISTING cluster, connected"
e2e_say "adopts $CLUSTER over Transit Gateway $TRANSIT_GATEWAY; creates no infrastructure"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

# Record what exists BEFORE, so we can prove the adopt path created nothing.
CLUSTER_ID_BEFORE=$(ibmcloud ks cluster get -c "$CLUSTER" --output json 2>/dev/null \
                    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)

VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({
 "prefix":k[0],"cluster_name":k[1],"region":k[2],"resource_group":k[3],
 "existing_transit_gateway":k[4],
 "bnkforge_url":k[5],"bnkforge_username":k[6],"bnkforge_password":k[7],
 "bnkforge_project":k[8],"bnkforge_insecure":k[9]}))' \
 "$PREFIX" "$CLUSTER" "$REGION" "$RESOURCE_GROUP" "$TRANSIT_GATEWAY" \
 "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD" "$PROJECT" "${FORGE_INSECURE:+true}")

e2e_deploy "$BP_DIR" "$REL" "$PROJECT" "$VARS"

e2e_head "Verify"
e2e_kubeconfig "$CLUSTER" || die "cluster $CLUSTER unreachable — nothing to verify"
e2e_assert    "license is Active"            "$(e2e_license_state)"       "Active"
e2e_assert_ge "f5 pods Running"              "$(e2e_f5_pods_running)"     30
e2e_assert    "no f5 pods stuck"             "$(e2e_f5_pods_not_running)" "0"
e2e_assert    "licensing is direct, not FLP" "$(e2e_license_mode)"        "jwt"
e2e_assert    "no private mirror in use"     "$(e2e_containers_from_mirror "${HARBOR_IP:-10.243.0.4}")" "0"
# The adopt guarantee: same cluster id we started with. A new one would mean the
# blueprint created a cluster it promised never to create.
CLUSTER_ID_AFTER=$(ibmcloud ks cluster get -c "$CLUSTER" --output json 2>/dev/null \
                   | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
e2e_assert    "adopted the pre-existing cluster" "$CLUSTER_ID_AFTER" "$CLUSTER_ID_BEFORE"
e2e_summary
