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
# .env is sourced AFTER the caller's environment, so `set -a; . .env` clobbers any
# plain variable an operator exported — TRANSIT_GATEWAY and PREFIX both silently
# reverted to the demo estate's values while the banner still read like the
# override had taken. Dedicated E2E_* names cannot collide with .env.
CLUSTER="${E2E_V3_CLUSTER:-$CLUSTER_NAME}"
PREFIX_V3="${E2E_V3_PREFIX:-$PREFIX}"
TGW_V3="${E2E_V3_TGW:-$TRANSIT_GATEWAY}"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"

if [[ "$ACTION" == "down" ]]; then
  e2e_teardown "$PROJECT"; exit $?
fi

e2e_head "Variant 3 — EXISTING cluster, connected"
e2e_say "adopts $CLUSTER over Transit Gateway $TGW_V3 (prefix $PREFIX_V3); creates no infrastructure"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

# Record what exists BEFORE, so we can prove the adopt path created nothing.
# Cluster identity via roksbnkctl, not the ibmcloud CLI.
CLUSTER_ID_BEFORE=$(roksbnkctl -w "${E2E_WS:-e2e}" ibmcloud ks cluster get --cluster "$CLUSTER" --output json 2>/dev/null \
                    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)

VARS=$(E2E_PREFIX="$PREFIX_V3" E2E_CLUSTER="$CLUSTER" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
       E2E_TGW="$TGW_V3" \
       E2E_COSI="$COS_INSTANCE" E2E_COSB="$COS_BUCKET" E2E_COSR="$COS_REGION" \
       E2E_FAR="$FAR_AUTH_FILE" E2E_JWT="$SUBSCRIPTION_JWT_FILE" E2E_MV="$MANIFEST_VERSION" \
       E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
       E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "cluster_name":e["E2E_CLUSTER"], "region":e["E2E_REGION"],
 "resource_group":e["E2E_RG"], "existing_transit_gateway":e["E2E_TGW"],
 "cos_instance":e["E2E_COSI"], "cos_bucket":e["E2E_COSB"], "cos_region":e["E2E_COSR"],
 "far_auth_file":e["E2E_FAR"], "subscription_jwt_file":e["E2E_JWT"],
 "manifest_version":e["E2E_MV"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"]}))')

export E2E_CLUSTER_UNDER_TEST="$CLUSTER"
e2e_deploy "$BP_DIR" "$REL" "$PROJECT" "$VARS"

e2e_head "Verify"
e2e_kubeconfig "$CLUSTER" || die "cluster $CLUSTER unreachable — nothing to verify"
e2e_assert    "license is Active"            "$(e2e_license_state)"       "Active"
e2e_assert_ge "f5 pods Running"              "$(e2e_f5_pods_running)"     30
e2e_wait_pods_settled 300 || true
e2e_assert    "no f5 pods stuck"             "$(e2e_f5_pods_not_running)" "0"
e2e_assert    "licensing is direct, not FLP" "$(e2e_license_mode)"        "connected"
e2e_assert    "no private mirror in use"     "$(e2e_containers_from_mirror "${HARBOR_IP:-10.243.0.4}")" "0"
e2e_assert    "every container from repo.f5.com" "$(e2e_containers_from_registry repo.f5.com)" "$(e2e_containers_total)"
e2e_assert    "every container from repo.f5.com" "$(e2e_containers_from_registry repo.f5.com)" "$(e2e_containers_total)"
# The adopt guarantee: same cluster id we started with. A new one would mean the
# blueprint created a cluster it promised never to create.
CLUSTER_ID_AFTER=$(roksbnkctl -w "${E2E_WS:-e2e}" ibmcloud ks cluster get --cluster "$CLUSTER" --output json 2>/dev/null \
                   | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
e2e_assert    "adopted the pre-existing cluster" "$CLUSTER_ID_AFTER" "$CLUSTER_ID_BEFORE"
e2e_summary
