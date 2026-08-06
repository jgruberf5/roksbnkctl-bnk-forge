#!/usr/bin/env bash
# VARIANT 2 — new VPC + cluster + Transit Gateway, BNK DISCONNECTED.
#
# Provisions a cluster whose workers have NO Internet egress
# (public_gateway=false, which needed roksbnkctl v1.38.0 to be reachable from a
# container module at all), then installs BNK entirely from a private mirror
# with licensing through an F5 License Proxy.
#
# PREREQUISITE: the Harbor + FAR-mirror and FLP blueprints must already be
# deployed. This script checks, and refuses rather than failing 40 minutes in.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-up}"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

BP_ID="ibm-roks-new-disconnected-bnk-roksbnkctl"
BP_DIR="roks-new-cluster-disconnected"
PROJECT="${E2E_V2_PROJECT:-f5e2e-v2-new-disco}"
CLUSTER="${E2E_V2_CLUSTER:-f5e2e-v2}"
PREFIX_V2="${E2E_V2_PREFIX:-f5e2e2}"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"

if [[ "$ACTION" == "down" ]]; then
  e2e_teardown "$PROJECT"; exit $?
fi

e2e_head "Variant 2 — NEW cluster, disconnected"
: "${HARBOR_IP:?set HARBOR_IP — deploy the Harbor + FAR-mirror blueprint first}"
: "${FLP_IP:?set FLP_IP — deploy the FLP blueprint first}"
: "${HARBOR_CA:?set HARBOR_CA (base64 PEM) — from the Harbor deploy}"
: "${FLP_CA:?set FLP_CA (base64 PEM) — from the FLP deploy}"
e2e_say "mirror $HARBOR_IP, licence proxy https://$FLP_IP:8443"

forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({
 "prefix":k[0],"cluster_name":k[1],"region":k[2],"resource_group":k[3],
 "openshift_version":k[4],"workers_per_zone":k[5],
 "registry_generic_host":k[6],"registry_repo_prefix":k[7],
 "registry_username":"admin","registry_password":k[8],
 "registry_ca_b64":k[9],"registry_ca_sha256":k[10],
 "flp_external_url":"https://%s:8443"%k[11],"flp_root_ca_b64":k[12],
 "cos_instance":k[13],"cos_bucket":k[14],"cos_region":k[15],
 "far_auth_file":k[16],"subscription_jwt_file":k[17],"manifest_version":k[18],
 "registry_cos_name":k[19],
 "bnkforge_url":k[20],"bnkforge_username":k[21],"bnkforge_password":k[22],
 "bnkforge_project":k[23],"bnkforge_insecure":k[24]}))' \
 "$PREFIX_V2" "$CLUSTER" "$REGION" "$RESOURCE_GROUP" \
 "${OPENSHIFT_VERSION:-4.18}" "${WORKERS_PER_ZONE:-2}" \
 "$HARBOR_IP" "$HARBOR_PROJECT" "$HARBOR_ADMIN_PASSWORD" "$HARBOR_CA" "$HARBOR_PIN" \
 "$FLP_IP" "$FLP_CA" "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" \
 "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE" "$MANIFEST_VERSION" "${REGISTRY_COS_NAME:-}" \
 "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD" "$PROJECT-reg" "${FORGE_INSECURE:+true}")

e2e_deploy "$BP_DIR" "$REL" "$PROJECT" "$VARS"

e2e_head "Verify"
e2e_kubeconfig "$CLUSTER" || die "cluster $CLUSTER unreachable — nothing to verify"
TOTAL=$(e2e_containers_total)
e2e_assert    "license is Active"              "$(e2e_license_state)"       "Active"
e2e_assert    "licensed via the F5 proxy"      "$(e2e_license_mode)"        "f5licenseproxy"
e2e_assert_ge "f5 pods Running"                "$(e2e_f5_pods_running)"     30
e2e_assert    "no f5 pods stuck"               "$(e2e_f5_pods_not_running)" "0"
# The assertion the whole variant exists for: every BNK container came from the
# mirror. One image off-mirror means the cluster reached the Internet.
e2e_assert    "every container from the mirror" "$(e2e_containers_from_mirror "$HARBOR_IP")" "$TOTAL"
e2e_summary
