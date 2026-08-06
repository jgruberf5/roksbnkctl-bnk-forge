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
PREFIX_V2="${E2E_V2_PREFIX:-f5e2e2}"
# roksbnkctl names a NEW cluster after the prefix — there is no separate name.
CLUSTER="$PREFIX_V2"

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

VARS=$(E2E_PREFIX="$PREFIX_V2" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
       E2E_OCP="${OPENSHIFT_VERSION:-4.18}" E2E_WPZ="${WORKERS_PER_ZONE:-2}" \
       E2E_RHOST="$HARBOR_IP" E2E_RREPO="$HARBOR_PROJECT" E2E_RPASS="$HARBOR_ADMIN_PASSWORD" \
       E2E_RCA="$HARBOR_CA" E2E_RPIN="$HARBOR_PIN" E2E_FLPIP="$FLP_IP" E2E_FLPCA="$FLP_CA" \
       E2E_COSI="$COS_INSTANCE" E2E_COSB="$COS_BUCKET" E2E_COSR="$COS_REGION" \
       E2E_FAR="$FAR_AUTH_FILE" E2E_JWT="$SUBSCRIPTION_JWT_FILE" E2E_MV="$MANIFEST_VERSION" \
       E2E_RCOS="${REGISTRY_COS_NAME:-}" \
       E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
       E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "region":e["E2E_REGION"], "resource_group":e["E2E_RG"],
 "openshift_version":e["E2E_OCP"], "workers_per_zone":e["E2E_WPZ"],
 "registry_generic_host":e["E2E_RHOST"], "registry_repo_prefix":e["E2E_RREPO"],
 "registry_username":"admin", "registry_password":e["E2E_RPASS"],
 "registry_ca_b64":e["E2E_RCA"], "registry_ca_sha256":e["E2E_RPIN"],
 "flp_external_url":"https://%s:8443" % e["E2E_FLPIP"], "flp_root_ca_b64":e["E2E_FLPCA"],
 "cos_instance":e["E2E_COSI"], "cos_bucket":e["E2E_COSB"], "cos_region":e["E2E_COSR"],
 "far_auth_file":e["E2E_FAR"], "subscription_jwt_file":e["E2E_JWT"],
 "manifest_version":e["E2E_MV"], "registry_cos_name":e["E2E_RCOS"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"]}))')

export E2E_CLUSTER_UNDER_TEST="$CLUSTER"
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
