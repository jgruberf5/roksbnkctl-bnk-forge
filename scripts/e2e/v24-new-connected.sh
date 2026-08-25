#!/usr/bin/env bash
# BNK 2.4 on a NEW ROKS cluster, reproducing F5's approved reference.
#
#   ./v24-new-connected.sh [up|down]
#
# WHAT THIS PROVES
# That a Forge blueprint can express the same BNK 2.4 project the roksbnkctl CI
# demo expresses. Every 2.4 attribute below is passed THROUGH THE BLUEPRINT, not
# through the environment, so a pass means an operator can build this from the
# Forge UI without touching a shell.
#
# The values are F5's approved reference, as recorded in roksbnkctl's own
# support_matrix.yaml for 2.4.0-EA (re-verified 2026-08-23 against a cluster
# reproducing staging-small-8c-20g):
#
#   6 x cx3d.8x20, OCP 4.21, deploymentSize Tiny, tmmReplicas 3,
#   wholeCluster false with watchNamespaces ["All"], reference pod placement,
#   GATEWAY_API_VERSION 1.5.0, demoMode off.
#
# worker_flavor is load-bearing: auto-select only ever considers the bx2 family
# and cannot produce cx3d.8x20 at any minimum, so without it this is not the
# reference cluster whatever else matches.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-up}"
set -a; . "$HERE/../demos/.env"; set +a
source "$HERE/e2e-lib.sh"

BP_ID="ibm-roks-new-bnk-roksbnkctl"
PROJECT="${E2E_V24_PROJECT:-f5e2e-v24-bnk24}"
PREFIX="${E2E_V24_PREFIX:-f5e2e24}"
CIDR="${E2E_V24_CIDR:-10.244.0.0/16}"
TGW="${E2E_V24_TGW:-$TRANSIT_GATEWAY}"       # adopt; do not spend quota
MV_24="${E2E_MANIFEST_24:-2.4.0-EA}"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state}"; mkdir -p "$STATE"
[[ "$ACTION" == "down" ]] && { e2e_teardown "$PROJECT"; exit $?; }

e2e_head "BNK 2.4 — NEW cluster, connected, F5 reference conformance"
e2e_say "manifest $MV_24, flavour cx3d.8x20, Tiny, tmmReplicas 3, gateway API 1.5.0"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"
forge_import_release "$REL" || die "release $REL is not deployable"

VARS=$(E2E_PREFIX="$PREFIX" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
  E2E_OCP="${OPENSHIFT_VERSION_24:-4.21}" E2E_WPZ="${WORKERS_PER_ZONE_24:-2}" \
  E2E_COSI="$COS_INSTANCE" E2E_COSB="$COS_BUCKET" E2E_COSR="$COS_REGION" \
  E2E_FAR="${FAR_AUTH_FILE_24:-non-ga-prod-pull-key.tgz}" E2E_JWT="$SUBSCRIPTION_JWT_FILE" E2E_MV="$MV_24" \
  E2E_CIDR="$CIDR" E2E_TGW="$TGW" \
  E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
  E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "region":e["E2E_REGION"], "resource_group":e["E2E_RG"],
 "openshift_version":e["E2E_OCP"], "workers_per_zone":e["E2E_WPZ"],
 "cluster_vpc_cidr":e["E2E_CIDR"], "existing_transit_gateway":e["E2E_TGW"],
 "cos_instance":e["E2E_COSI"], "cos_bucket":e["E2E_COSB"], "cos_region":e["E2E_COSR"],
 "far_auth_file":e["E2E_FAR"], "subscription_jwt_file":e["E2E_JWT"],
 "manifest_version":e["E2E_MV"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"],
 # ---- the 2.4 surface under test, all via the blueprint ----
 "worker_flavor":"cx3d.8x20",
 "cneinstance_size":"Tiny",
 "tmm_replicas":"3",
 "whole_cluster":"false",
 "watch_namespaces":"All",
 "gateway_api_version":"1.5.0",
 "demo_mode":"false"}))')

TMP="$STATE/.v24.create"
MODS=$(forge_create_project "$REL" "$PROJECT" "$REGION" "$FORGE_CREDENTIAL_TEMPLATE_ID" "$VARS" 2> >(tee "$TMP" >&2)) \
  || die "could not create project '$PROJECT'"
PID=$(awk '/^PROJECT/{print $2}' "$TMP")
[[ -n "$PID" ]] || die "project created but no id returned"
echo "$PID" > "$STATE/$PROJECT.project"; echo "$MODS" > "$STATE/$PID.modules"
e2e_say "project $PID, modules: $MODS"

for m in $MODS; do forge_enable_module "$m"; done
forge_restore_dependencies "$HERE/../../blueprints/roks-new-cluster/forge-blueprint.json" $MODS
forge_api PUT "/api/projects/$PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null
for m in $MODS; do forge_enable_module "$m"; done

FIRST=$(echo "$MODS" | awk '{print $1}')
forge_apply "$FIRST"
for m in $MODS; do forge_wait_module "$m" "module $m" 7200; done

e2e_ws_init "$PREFIX"; e2e_kubeconfig "$PREFIX"
e2e_head "Verify 2.4 conformance"
e2e_wait_pods_settled 900 || true
# Delegate to verify-24.sh, whose expected values were READ FROM the approved
# reference cluster staging-small-8c-20g and which passes 10/10 against it. The
# assertions written here originally were wrong in two ways that would have
# failed a healthy cluster: `.spec.version` is empty on a real 2.4 install (the
# field is .spec.manifestVersion), and `ibmcloud ks worker ls` reports the
# profile as .flavor rather than .machineType.
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" "$HERE/verify-24.sh" "$PREFIX"
