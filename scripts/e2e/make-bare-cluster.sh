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
set -a; . "$HERE/../demos/.env"; set +a
source "$HERE/e2e-lib.sh"

case "$MODE" in
  connected)    PUBGW=true;  PREFIX="${2:-f5e2e3}"; CIDR="${3:-10.249.0.0/16}"
                PROJECT="${BARE_PROJECT:-f5e2e-bare-connected}" ;;
  disconnected) PUBGW=false; PREFIX="${2:-f5e2e4}"; CIDR="${3:-10.250.0.0/16}"
                PROJECT="${BARE_PROJECT:-f5e2e-bare-disconnected}" ;;
  *) echo "usage: $0 [connected|disconnected] [prefix] [cidr]" >&2; exit 2 ;;
esac
# ONE blueprint for both modes. The connected and disconnected cluster-create
# configurations are byte-identical except public_gateway, so the mode is that
# flag and nothing else. The disconnected variant no longer needs HARBOR_*/FLP_*
# either: those are bnk-install inputs, and this blueprint has no bnk-install.
BP_ID="ibm-roks-bare-cluster-roksbnkctl"; BP_DIR="roks-bare-cluster"

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
STATE="${STATE:-$HERE/.e2e-state-bare-$MODE}"; mkdir -p "$STATE"

e2e_head "Bare cluster ($MODE) — $PREFIX, VPC $CIDR, NO BNK"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID"
e2e_say "blueprint release $REL"

VARS=$(E2E_PREFIX="$PREFIX" E2E_REGION="$REGION" E2E_RG="$RESOURCE_GROUP" \
  E2E_OCP="${OPENSHIFT_VERSION:-4.20}" E2E_WPZ="${WORKERS_PER_ZONE:-2}" E2E_CIDR="$CIDR" \
  E2E_TGW="$TRANSIT_GATEWAY" E2E_PUBGW="$PUBGW" \
  E2E_FURL="$FORGE_URL" E2E_FUSER="$FORGE_USER" E2E_FPASS="$FORGE_PASSWORD" \
  E2E_FPROJ="$PROJECT" E2E_FINSEC="${FORGE_INSECURE:+true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "prefix":e["E2E_PREFIX"], "region":e["E2E_REGION"], "resource_group":e["E2E_RG"],
 "openshift_version":e["E2E_OCP"], "workers_per_zone":e["E2E_WPZ"],
 "cluster_vpc_cidr":e["E2E_CIDR"], "existing_transit_gateway":e["E2E_TGW"],
 "public_gateway":e["E2E_PUBGW"],
 "bnkforge_url":e["E2E_FURL"], "bnkforge_username":e["E2E_FUSER"],
 "bnkforge_password":e["E2E_FPASS"], "bnkforge_project":e["E2E_FPROJ"],
 "bnkforge_insecure":e["E2E_FINSEC"]}))')

forge_import_release "$REL" || die "release $REL is not deployable"
TMP="$STATE/.bare.create"
MODS=$(forge_create_project "$REL" "$PROJECT" "$REGION" \
         "$FORGE_CREDENTIAL_TEMPLATE_ID" "$VARS" 2> >(tee "$TMP" >&2)) \
  || die "could not create project '$PROJECT'"
PID=$(awk '/^PROJECT/{print $2}' "$TMP")
[[ -n "$PID" ]] || die "project created but no id returned"
echo "$PID" > "$STATE/bare.project"; echo "$MODS" > "$STATE/$PID.modules"
e2e_say "project $PID, modules: $MODS"

# The blueprint carries exactly ONE module, so there is nothing to disable and
# nothing Forge's dependency graph can dispatch behind our back.
#
# The old approach deployed a full new-cluster blueprint and switched bnk-install
# off. That was fragile in two directions: enabling a module recomputes
# depends_on from library metadata and wipes the restored edges, and a module
# merely left undispatched is still RUNNABLE -- Forge started bnk-install by
# itself the moment cluster-create finished (project 99, m158, 14:47-14:52) and
# it collided with the v3 run's own install on the same cluster. Structure beats
# a flag: a module that does not exist cannot be dispatched.
FIRST=$(echo "$MODS" | awk '{print $1}')
# Count WORDS, do not try to slice a tail off. `cut -d' ' -f2-` returns the WHOLE
# string when the delimiter is absent -- without -s, cut prints unmatched lines
# entire -- so a correct single-module result ("85") produced REST="85" and this
# guard rejected every valid bare blueprint. Five consecutive cycles died here in
# under 8 seconds, each after ~50 minutes of UC1, before anyone read the message.
NMODS=$(wc -w <<<"$MODS")
(( NMODS == 1 )) || die "bare blueprint returned $NMODS modules ($MODS) - it must carry only cluster-create"

forge_enable_module "$FIRST"
forge_api PUT "/api/projects/$PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null

e2e_say "applying $FIRST (cluster-create); this blueprint has no bnk-install"
forge_apply "$FIRST"
forge_wait_module "$FIRST" "bare-$MODE" 5400 || die "cluster-create failed"
e2e_say "verified: blueprint carries no BNK module - cluster is bare by construction"

e2e_head "Bare cluster ready"
e2e_say "cluster: $PREFIX   project: $PID"
e2e_say "release its Forge registration before v3/v4 adopts it (see CONSTRAINTS.md)"
echo "$PREFIX"
