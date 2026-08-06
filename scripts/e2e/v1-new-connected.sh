#!/usr/bin/env bash
# VARIANT 1 — new VPC + cluster + Transit Gateway, BNK connected.
#
# Nothing pre-exists: this blueprint provisions the cluster, its VPC and its
# gateway, then installs BNK straight from F5's registry with direct licensing.
# No Harbor, no FAR mirror, no License Proxy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-up}"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

BP_ID="ibm-roks-new-bnk-roksbnkctl"
BP_DIR="roks-new-cluster"
PROJECT="${E2E_V1_PROJECT:-f5e2e-v1-new-connected}"
PREFIX_V1="${E2E_V1_PREFIX:-f5e2e1}"
# roksbnkctl names a NEW cluster after the prefix — there is no separate name.
CLUSTER="$PREFIX_V1"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"

if [[ "$ACTION" == "down" ]]; then
  e2e_teardown "$PROJECT"; exit $?
fi

e2e_head "Variant 1 — NEW cluster, connected"
e2e_say "creates VPC + ROKS + Transit Gateway, installs BNK with public egress"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

VARS=$(E2E_PREFIX="$PREFIX_V1" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
       E2E_OCP="${OPENSHIFT_VERSION:-4.18}" E2E_WPZ="${WORKERS_PER_ZONE:-2}" \
       E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
       E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "region":e["E2E_REGION"], "resource_group":e["E2E_RG"],
 "openshift_version":e["E2E_OCP"], "workers_per_zone":e["E2E_WPZ"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"]}))')

e2e_deploy "$BP_DIR" "$REL" "$PROJECT" "$VARS"

e2e_head "Verify"
e2e_kubeconfig "$CLUSTER" || die "cluster $CLUSTER unreachable — nothing to verify"
e2e_assert    "license is Active"            "$(e2e_license_state)"       "Active"
e2e_assert_ge "f5 pods Running"              "$(e2e_f5_pods_running)"     30
e2e_assert    "no f5 pods stuck"             "$(e2e_f5_pods_not_running)" "0"
# The distinguishing assertion: a CONNECTED install must NOT be licensed
# through a proxy, and its images come from F5, not a mirror.
e2e_assert    "licensing is direct, not FLP" "$(e2e_license_mode)"        "jwt"
e2e_assert_ge "containers pulled from F5"    "$(e2e_containers_total)"    30
e2e_assert    "no private mirror in use"     "$(e2e_containers_from_mirror "${HARBOR_IP:-10.243.0.4}")" "0"
e2e_summary
