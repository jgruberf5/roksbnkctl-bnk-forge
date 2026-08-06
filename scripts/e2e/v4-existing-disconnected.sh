#!/usr/bin/env bash
# VARIANT 4 — EXISTING VPC + cluster + Transit Gateway, BNK DISCONNECTED.
#
# The cluster and gateway already exist and are adopted, never created. BNK
# installs entirely from a private mirror, licensed through an F5 License Proxy.
# This is the path the demo script has proven repeatedly; the script exists so
# all four variants are exercised the same way and compared on the same numbers.
#
# PREREQUISITE: Harbor + FAR-mirror and FLP blueprints already deployed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-up}"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

BP_ID="ibm-roks-disconnected-bnk-roksbnkctl"
BP_DIR="roks-disconnected"
PROJECT="${E2E_V4_PROJECT:-f5e2e-v4-existing-disco}"
CLUSTER="${E2E_V4_CLUSTER:-$CLUSTER_NAME}"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"

if [[ "$ACTION" == "down" ]]; then
  e2e_teardown "$PROJECT"; exit $?
fi

e2e_head "Variant 4 — EXISTING cluster, disconnected"
: "${HARBOR_IP:?set HARBOR_IP — deploy the Harbor + FAR-mirror blueprint first}"
: "${FLP_IP:?set FLP_IP — deploy the FLP blueprint first}"
e2e_say "adopts $CLUSTER; mirror $HARBOR_IP, licence proxy https://$FLP_IP:8443"

forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

CLUSTER_ID_BEFORE=$(ibmcloud ks cluster get -c "$CLUSTER" --output json 2>/dev/null \
                    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)

VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({
 "prefix":k[0],"cluster_name":k[1],"region":k[2],"resource_group":k[3],
 "existing_transit_gateway":k[4],"registry_cos_name":k[5],
 "registry_generic_host":k[6],"registry_repo_prefix":k[7],
 "registry_username":"admin","registry_password":k[8],
 "registry_ca_b64":k[9],"registry_ca_sha256":k[10],
 "flp_external_url":"https://%s:8443"%k[11],"flp_root_ca_b64":k[12],
 "cos_instance":k[13],"cos_bucket":k[14],"cos_region":k[15],
 "far_auth_file":k[16],"subscription_jwt_file":k[17],"manifest_version":k[18],
 "bnkforge_url":k[19],"bnkforge_username":k[20],"bnkforge_password":k[21],
 "bnkforge_project":k[22],"bnkforge_insecure":k[23]}))' \
 "$PREFIX" "$CLUSTER" "$REGION" "$RESOURCE_GROUP" "$TRANSIT_GATEWAY" "${REGISTRY_COS_NAME:-}" \
 "$HARBOR_IP" "$HARBOR_PROJECT" "$HARBOR_ADMIN_PASSWORD" "$HARBOR_CA" "$HARBOR_PIN" \
 "$FLP_IP" "$FLP_CA" "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" \
 "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE" "$MANIFEST_VERSION" \
 "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD" "$PROJECT" "${FORGE_INSECURE:+true}")

e2e_deploy "$BP_DIR" "$REL" "$PROJECT" "$VARS"

e2e_head "Verify"
e2e_kubeconfig "$CLUSTER" || die "cluster $CLUSTER unreachable — nothing to verify"
TOTAL=$(e2e_containers_total)
e2e_assert    "license is Active"               "$(e2e_license_state)"       "Active"
e2e_assert    "licensed via the F5 proxy"       "$(e2e_license_mode)"        "f5licenseproxy"
e2e_assert_ge "f5 pods Running"                 "$(e2e_f5_pods_running)"     30
e2e_assert    "no f5 pods stuck"                "$(e2e_f5_pods_not_running)" "0"
e2e_assert    "every container from the mirror" "$(e2e_containers_from_mirror "$HARBOR_IP")" "$TOTAL"
CLUSTER_ID_AFTER=$(ibmcloud ks cluster get -c "$CLUSTER" --output json 2>/dev/null \
                   | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
e2e_assert    "adopted the pre-existing cluster" "$CLUSTER_ID_AFTER" "$CLUSTER_ID_BEFORE"
e2e_summary
