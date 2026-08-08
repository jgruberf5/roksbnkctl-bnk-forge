#!/usr/bin/env bash
# Build a ROKS cluster with NO BNK on it — the precondition variants 3 and 4
# actually need, and the one `run-all.sh` never produced.
#
# Variants 3 and 4 adopt an EXISTING cluster and install BNK onto it. Handing
# them the preceding variant's cluster does not work: that cluster already has
# BNK, and the adopting project gets a FRESH deployment-scoped /work, so its
# terraform state is empty and `bnk up` plans a full install (64 resources) over
# an install that is already there. It runs for ~13 minutes and exits 1.
#
# BNK also cannot be stripped from a cluster afterwards. Destroying the
# `bnk-install` module cascades into `cluster-create` and destroys the cluster
# with it — confirmed 2026-08-08: module 145 reached `destroyed`, then module 144
# went `destroying` and the cluster went to `state=deleting`.
#
# So the only way to get a BNK-free cluster is to deploy a NEW-cluster blueprint
# and apply ONLY its cluster-create module, never dispatching bnk-install. That
# is what this does.
#
#   ./make-bare-cluster.sh connected     [prefix] [cidr]
#   ./make-bare-cluster.sh disconnected  [prefix] [cidr]
#
# Prints the cluster name on stdout. Disconnected needs HARBOR_IP/HARBOR_CA/
# HARBOR_PIN/FLP_IP/FLP_CA in the environment, exactly as v2 and v4 do.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-connected}"
set -a; . "$HERE/../demo/.env"; set +a
source "$HERE/e2e-lib.sh"

case "$MODE" in
  connected)
    BP_ID="ibm-roks-new-bnk-roksbnkctl"; BP_DIR="roks-new-cluster"
    PREFIX="${2:-f5e2e3}"; CIDR="${3:-10.244.0.0/16}"
    PROJECT="${BARE_PROJECT:-f5e2e-bare-connected}" ;;
  disconnected)
    BP_ID="ibm-roks-new-disconnected-bnk-roksbnkctl"; BP_DIR="roks-new-cluster-disconnected"
    PREFIX="${2:-f5e2e4}"; CIDR="${3:-10.246.0.0/16}"
    PROJECT="${BARE_PROJECT:-f5e2e-bare-disconnected}"
    : "${HARBOR_IP:?set HARBOR_IP}"; : "${HARBOR_CA:?set HARBOR_CA}"
    : "${HARBOR_PIN:?set HARBOR_PIN}"; : "${FLP_IP:?set FLP_IP}"; : "${FLP_CA:?set FLP_CA}" ;;
  *) echo "usage: $0 [connected|disconnected] [prefix] [cidr]" >&2; exit 2 ;;
esac

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state-bare-$MODE}"; mkdir -p "$STATE"

e2e_head "Bare cluster ($MODE) — $PREFIX, VPC $CIDR, NO BNK"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

if [[ "$MODE" == "connected" ]]; then
  VARS=$(E2E_PREFIX="$PREFIX" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
    E2E_OCP="${OPENSHIFT_VERSION:-4.20}" E2E_WPZ="${WORKERS_PER_ZONE:-2}" E2E_CIDR="$CIDR" \
    E2E_COSI="$COS_INSTANCE" E2E_COSB="$COS_BUCKET" E2E_COSR="$COS_REGION" \
    E2E_FAR="$FAR_AUTH_FILE" E2E_JWT="$SUBSCRIPTION_JWT_FILE" E2E_MV="$MANIFEST_VERSION" \
    E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
    E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
  python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "region":e["E2E_REGION"], "resource_group":e["E2E_RG"],
 "openshift_version":e["E2E_OCP"], "workers_per_zone":e["E2E_WPZ"],
 "cluster_vpc_cidr":e["E2E_CIDR"],
 "cos_instance":e["E2E_COSI"], "cos_bucket":e["E2E_COSB"], "cos_region":e["E2E_COSR"],
 "far_auth_file":e["E2E_FAR"], "subscription_jwt_file":e["E2E_JWT"],
 "manifest_version":e["E2E_MV"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"]}))')
else
  VARS=$(E2E_PREFIX="$PREFIX" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
    E2E_OCP="${OPENSHIFT_VERSION:-4.20}" E2E_WPZ="${WORKERS_PER_ZONE:-2}" \
    E2E_TGW="$TRANSIT_GATEWAY" E2E_CIDR="$CIDR" \
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
 "existing_transit_gateway":e["E2E_TGW"], "cluster_vpc_cidr":e["E2E_CIDR"],
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
fi

forge_import_release "$REL" || die "release $REL is not deployable"
TMP="$STATE/.bare.create"
MODS=$(forge_create_project "$REL" "$PROJECT" "$REGION" \
         "$FORGE_CREDENTIAL_TEMPLATE_ID" "$VARS" 2> >(tee "$TMP" >&2)) \
  || die "could not create project '$PROJECT'"
PID=$(awk '/^PROJECT/{print $2}' "$TMP")
[[ -n "$PID" ]] || die "project created but no id returned"
echo "$PID" > "$STATE/bare.project"; echo "$MODS" > "$STATE/$PID.modules"
e2e_say "project $PID, modules: $MODS"

FIRST=$(echo "$MODS" | awk '{print $1}')
REST=$(echo "$MODS" | cut -d' ' -f2-)

# Enable ONLY cluster-create, and leave every downstream module DISABLED.
#
# Not dispatching bnk-install is not enough. Forge's dependency graph dispatches
# a module as soon as its dependencies are satisfied — `e2e_deploy` relies on
# exactly that ("Apply the first module only; Forge's dependency graph triggers
# the rest"). An earlier version of this script enabled every module and applied
# only the first, and Forge started bnk-install by itself the moment
# cluster-create finished: project 99 ran m158 bnk-install 14:47→14:52 with
# nobody asking, and it collided with the v3 run's own bnk-install on the SAME
# cluster (14:48:44→15:02:14). The cluster was not bare, and the variant under
# test was racing another install.
#
# Leaving them disabled is what actually holds them back. Forge treats a disabled
# module as not-to-be-run rather than not-yet-runnable.
forge_enable_module "$FIRST"
for m in $REST; do
  forge_api PUT "/api/project-modules/$m" '{"enabled":false}' >/dev/null \
    && e2e_say "module $m left DISABLED (no BNK on this cluster)"
done
forge_restore_dependencies "$HERE/../../blueprints/$BP_DIR/forge-blueprint.json" $MODS
forge_api PUT "/api/projects/$PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null
# restore_dependencies goes through update_module, which can re-enable; re-assert.
for m in $REST; do forge_api PUT "/api/project-modules/$m" '{"enabled":false}' >/dev/null; done

e2e_say "applying ONLY $FIRST (cluster-create); downstream modules are disabled"
forge_apply "$FIRST"
forge_wait_module "$FIRST" "bare-$MODE" 5400 || die "cluster-create failed"

# Prove it: a downstream module that quietly ran would defeat the whole point.
for m in $REST; do
  st=$(forge_module_status "$m")
  [[ "$st" == "applied" || "$st" == "applying" ]] \
    && die "module $m is '$st' — it was dispatched despite being disabled; the cluster is NOT bare"
done
e2e_say "verified: no downstream module ran — cluster has no BNK"

e2e_head "Bare cluster ready"
e2e_say "cluster: $PREFIX   project: $PID"
e2e_say "release its Forge registration before v3/v4 adopts it (see CONSTRAINTS.md)"
echo "$PREFIX"
