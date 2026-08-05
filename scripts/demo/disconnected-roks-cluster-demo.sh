#!/usr/bin/env bash
# disconnected-roks-cluster-demo.sh — drive the whole air-gapped BNK deployment
# through the BNK Forge REST API.
#
#   Harbor registry  →  FLP appliance  →  cluster registry → FAR mirror → BNK install
#
# Everything runs as BNK Forge deployments; this script only calls the API,
# waits, and carries the handoffs the API cannot (Harbor's CA and the FLP's root
# CA, both of which live on their VSIs and must be supplied out of band).
#
#   ./disconnected-roks-cluster-demo.sh            # run it
#   ./disconnected-roks-cluster-demo.sh teardown   # remove everything it created
#
# Prereqs: an EXISTING ROKS cluster with BNK not installed, an EXISTING Transit
# Gateway, an IBM credential template on the Forge, and an IBM Cloud VPC SSH key
# whose private half is on this host. See .env.example.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/forge-api.sh
source "$HERE/lib/forge-api.sh"

[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }

# ── inputs ───────────────────────────────────────────────────────────────────
ask()      { local v="$1" p="$2" d="${3:-}" cur="${!1:-}"; [[ -n "$cur" ]] && return 0
             read -r -p "   $p${d:+ [$d]}: " REPLY </dev/tty; printf -v "$v" '%s' "${REPLY:-$d}"; }
ask_secret() { local v="$1" p="$2" cur="${!1:-}"; [[ -n "$cur" ]] && return 0
             read -r -s -p "   $p: " REPLY </dev/tty; echo >&2; printf -v "$v" '%s' "$REPLY"; }

phase "BNK Forge credentials"
ask        FORGE_URL      "BNK Forge URL"        "https://localhost"
ask        FORGE_USER     "Username"             "admin"
ask_secret FORGE_PASSWORD "Password"
forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"
ok "authenticated to $FORGE_URL as $FORGE_USER"

if [[ -z "${FORGE_CREDENTIAL_TEMPLATE_ID:-}" ]]; then
  say "IBM credential templates on this Forge:"
  forge_api GET /api/credential-templates | python3 -c '
import sys,json
for t in json.load(sys.stdin):
    if (t.get("provider") or "")=="ibm":
        print(f"      {t[\"id\"]:>3}  {t[\"name\"]}  (region {t.get(\"region\")}, key set: {t.get(\"has_ibmcloud_api_key\")})")' >&2
  ask FORGE_CREDENTIAL_TEMPLATE_ID "Credential template id"
fi

phase "Target environment"
ask REGION               "IBM Cloud region"                    "us-east"
ask ZONE                 "Zone"                                "${REGION}-1"
ask RESOURCE_GROUP       "Resource group"                      "default"
ask PREFIX               "Resource prefix"                     "fdisco"
ask CLUSTER_NAME         "EXISTING cluster to adopt"           "$PREFIX"
ask TRANSIT_GATEWAY      "EXISTING Transit Gateway"            "bnkci-testing"
ask SSH_KEY_NAME         "IBM Cloud VPC SSH key name"
ask SSH_KEY_FILE         "…matching private key on this host"  "$HOME/.ssh/id_rsa"
ask SERVICES_SUBNET_CIDR "Services subnet CIDR"                "10.243.0.0/24"
ask SERVICES_SPARE_CIDR  "Spare services prefix"               "10.243.1.0/24"
ask COS_BUCKET           "COS bucket holding the FAR key + JWT"
ask BNKFORGE_PROJECT     "Forge project to register the cluster into" "roksbnkctl-existing-cluster"
ask_secret HARBOR_ADMIN_PASSWORD "Harbor admin password to set"

COS_INSTANCE="${COS_INSTANCE:-bnk-supply-chain}"
COS_REGION="${COS_REGION:-us-south}"
FAR_AUTH_FILE="${FAR_AUTH_FILE:-f5-far-auth-key.tgz}"
SUBSCRIPTION_JWT_FILE="${SUBSCRIPTION_JWT_FILE:-subscription.jwt}"
MANIFEST_VERSION="${MANIFEST_VERSION:-2.3.0-3.2598.3-0.0.170}"
HARBOR_PROJECT="${HARBOR_PROJECT:-bnk-mirror}"
REGISTRY_COS_NAME="${REGISTRY_COS_NAME:-}"
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$SSH_KEY_FILE")
STATE="$HERE/.demo-state"; mkdir -p "$STATE"

# ── teardown ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  phase "Teardown"
  for f in disco flp harbor; do            # reverse of creation order
    [[ -f "$STATE/$f.project" ]] || continue
    pid=$(cat "$STATE/$f.project")
    say "destroying project $pid ($f) …"
    forge_destroy_project "$pid" || warn "destroy-all returned non-zero for $pid"
    for mid in $(cat "$STATE/$f.modules" 2>/dev/null); do
      forge_wait_module "$mid" "module $mid" 3600 || true
    done
    forge_delete_project "$pid"; rm -f "$STATE/$f.project" "$STATE/$f.modules"
  done
  ok "teardown complete — the adopted cluster and the Transit Gateway are left intact"
  exit 0
fi

# ── 1. catalog ───────────────────────────────────────────────────────────────
phase "1/5  Sync the module + blueprint catalog"
forge_sync_source "roksbnkctl-bnk-forge"
HARBOR_REL=$(forge_latest_release "Harbor")    || die "no valid Harbor blueprint release found"
DISCO_REL=$(forge_latest_release "disconnected") || die "no valid disconnected blueprint release found"
FLP_REL=$(forge_latest_release "License Proxy")  || die "no valid FLP blueprint release found"
for r in "$HARBOR_REL" "$FLP_REL" "$DISCO_REL"; do forge_import_release "$r"; done
ok "releases imported — harbor=$HARBOR_REL flp=$FLP_REL disconnected=$DISCO_REL"

# ── 2. Harbor ────────────────────────────────────────────────────────────────
phase "2/5  Private Harbor registry"
say "Creates the services VPC, attaches it to $TRANSIT_GATEWAY, and installs Harbor."
say "Harbor's hostname is its PRIVATE IP so the token realm is reachable from"
say "no-egress worker nodes; the cert SAN covers the floating IP too."
HARBOR_VARS=$(python3 -c '
import json,sys
k=dict(zip(["prefix","region","rg","zone","ssh","pw","tgw","cidr","spare","projects"],sys.argv[1:]))
print(json.dumps({"prefix":k["prefix"]+"-svc","region":k["region"],"resource_group":k["rg"],
 "zone":k["zone"],"ssh_key_name":k["ssh"],"harbor_admin_password":k["pw"],
 "transit_gateway":k["tgw"],"subnet_cidr":k["cidr"],"services_spare_cidr":k["spare"],
 "registry_projects":k["projects"],"create_vpc":True,"public_gateway":True}))' \
  "$PREFIX" "$REGION" "$RESOURCE_GROUP" "$ZONE" "$SSH_KEY_NAME" "$HARBOR_ADMIN_PASSWORD" \
  "$TRANSIT_GATEWAY" "$SERVICES_SUBNET_CIDR" "$SERVICES_SPARE_CIDR" "$HARBOR_PROJECT,bnk-status")
HARBOR_MODS=$(forge_create_project "$HARBOR_REL" "$PREFIX-harbor" "$REGION" "$FORGE_CREDENTIAL_TEMPLATE_ID" "$HARBOR_VARS" 2> >(tee /tmp/.hp >&2)) || die "could not create the Harbor project"
HARBOR_PID=$(awk '/^PROJECT/{print $2}' /tmp/.hp); echo "$HARBOR_PID" > "$STATE/harbor.project"; echo "$HARBOR_MODS" > "$STATE/harbor.modules"
for m in $HARBOR_MODS; do forge_apply "$m"; done
for m in $HARBOR_MODS; do forge_wait_module "$m" "harbor" 3600; done

HARBOR_FIP=$(ssh_harbor_fip() { :; }; forge_api GET "/api/projects/$HARBOR_PID/variables" >/dev/null; \
  python3 - "$STATE" <<'PY'
import sys,os
# The floating IP is a module output; read it back from the state file the
# apply step wrote if the outputs API is unavailable on this Forge build.
p=os.path.join(sys.argv[1],"harbor.fip")
print(open(p).read().strip() if os.path.exists(p) else "")
PY
)
if [[ -z "$HARBOR_FIP" ]]; then
  ask HARBOR_FIP "Harbor floating IP (from the module outputs in the UI)"
  echo "$HARBOR_FIP" > "$STATE/harbor.fip"
fi
say "waiting for Harbor's cloud-init to finish installing …"
for i in $(seq 1 90); do
  [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$HARBOR_FIP/api/v2.0/systeminfo")" == "200" ]] && break
  sleep 20
done
ok "Harbor serving on https://$HARBOR_FIP/"

# The CA and its pin are the out-of-band trust v1.35.0 requires: `registry
# replicate` refuses to adopt a self-signed mirror's CA off the wire.
HARBOR_CA=$(ssh "${SSH_OPTS[@]}" "ubuntu@$HARBOR_FIP" "sudo base64 -w0 /opt/harbor/certs/harbor.crt" 2>/dev/null | tr -d '\r\n')
HARBOR_PIN=$(ssh "${SSH_OPTS[@]}" "ubuntu@$HARBOR_FIP" "sudo openssl x509 -in /opt/harbor/certs/harbor.crt -noout -fingerprint -sha256" 2>/dev/null \
             | sed 's/.*=//' | tr -d ':\r\n' | tr 'A-F' 'a-f')
[[ -n "$HARBOR_CA" && -n "$HARBOR_PIN" ]] || die "could not read Harbor's CA over SSH (check SSH_KEY_FILE)"
HARBOR_IP=$(ssh "${SSH_OPTS[@]}" "ubuntu@$HARBOR_FIP" "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\r\n')
ok "mirror at $HARBOR_IP (private) — CA captured, pin ${HARBOR_PIN:0:16}…"

# ── 3. FLP ───────────────────────────────────────────────────────────────────
phase "3/5  F5 License Proxy appliance"
say "A standalone VSI in the services VPC — no cluster. The proxy is the only"
say "component needing egress to F5; the cluster reaches it privately."
HARBOR_VPC=$(ssh "${SSH_OPTS[@]}" "ubuntu@$HARBOR_FIP" "true" 2>/dev/null; \
             cat "$STATE/harbor.vpc" 2>/dev/null)
if [[ -z "$HARBOR_VPC" ]]; then
  ask HARBOR_VPC "Services VPC id (Harbor module output vpc_id)"
  echo "$HARBOR_VPC" > "$STATE/harbor.vpc"
fi
FLP_VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({"prefix":k[0]+"-flp","region":k[1],"resource_group":k[2],"flp_vsi_vpc":k[3],
 "flp_vsi_zone":k[4],"flp_vsi_ssh_key":k[5],"flp_vsi_floating_ip":True,
 "far_auth_local_file":"","subscription_jwt_local_file":"",
 "cos_instance":k[6],"cos_bucket":k[7],"cos_region":k[8],
 "far_auth_file":k[9],"subscription_jwt_file":k[10]}))' \
  "$PREFIX" "$REGION" "$RESOURCE_GROUP" "$HARBOR_VPC" "$ZONE" "$SSH_KEY_NAME" \
  "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE")
FLP_MODS=$(forge_create_project "$FLP_REL" "$PREFIX-flp" "$REGION" "$FORGE_CREDENTIAL_TEMPLATE_ID" "$FLP_VARS" 2> >(tee /tmp/.fp >&2)) || die "could not create the FLP project"
FLP_PID=$(awk '/^PROJECT/{print $2}' /tmp/.fp); echo "$FLP_PID" > "$STATE/flp.project"; echo "$FLP_MODS" > "$STATE/flp.modules"
for m in $FLP_MODS; do forge_apply "$m"; done
for m in $FLP_MODS; do forge_wait_module "$m" "flp" 3600; done

ask FLP_IP "FLP private IP (module output / `ibmcloud is instance flp-vsi`)"
# The proxy's root CA lives on the appliance; reach it by jumping through Harbor,
# since the FLP's :22 is restricted to the private plane.
scp "${SSH_OPTS[@]}" "$SSH_KEY_FILE" "ubuntu@$HARBOR_FIP:/home/ubuntu/.jump" >/dev/null 2>&1
FLP_CA=$(ssh "${SSH_OPTS[@]}" "ubuntu@$HARBOR_FIP" \
  "chmod 600 /home/ubuntu/.jump; ssh -o StrictHostKeyChecking=no -i /home/ubuntu/.jump ubuntu@$FLP_IP 'sudo base64 -w0 /opt/flp/ca.crt'" 2>/dev/null | tr -d '\r\n')
[[ -n "$FLP_CA" ]] || die "could not read the FLP root CA (jumped via $HARBOR_FIP)"
ok "FLP at https://$FLP_IP:8443 — root CA captured"

# ── 4+5. the disconnected chain ──────────────────────────────────────────────
phase "4/5  Register the cluster, mirror FAR, install BNK"
say "One deployment, three modules. Registration runs FIRST so the cluster is"
say "on Forge's Kubernetes page and watchable while BNK installs onto it."
DISCO_VARS=$(python3 -c '
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
  "$PREFIX" "$CLUSTER_NAME" "$REGION" "$RESOURCE_GROUP" "$TRANSIT_GATEWAY" "$REGISTRY_COS_NAME" \
  "$HARBOR_IP" "$HARBOR_PROJECT" "$HARBOR_ADMIN_PASSWORD" "$HARBOR_CA" "$HARBOR_PIN" \
  "$FLP_IP" "$FLP_CA" "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" \
  "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE" "$MANIFEST_VERSION" \
  "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD" "$BNKFORGE_PROJECT" "${FORGE_INSECURE:+true}")
DISCO_MODS=$(forge_create_project "$DISCO_REL" "$PREFIX-disconnected" "$REGION" "$FORGE_CREDENTIAL_TEMPLATE_ID" "$DISCO_VARS" 2> >(tee /tmp/.dp >&2)) || die "could not create the disconnected project"
DISCO_PID=$(awk '/^PROJECT/{print $2}' /tmp/.dp); echo "$DISCO_PID" > "$STATE/disco.project"; echo "$DISCO_MODS" > "$STATE/disco.modules"

# Apply the first module only: Forge's dependency graph auto-triggers the rest as
# each one's dependencies are satisfied. Applying them all here races the
# orchestrator and loses on the module lock.
FIRST=$(echo "$DISCO_MODS" | awk '{print $1}')
forge_apply "$FIRST"
for m in $DISCO_MODS; do forge_wait_module "$m" "module $m" 5400; done

phase "5/5  Verify"
say "BNK should be Active, licensed through the proxy, every image from the mirror."
cat <<EOF >&2

   Harbor UI    https://$HARBOR_FIP/         (admin / \$HARBOR_ADMIN_PASSWORD)
   FLP          https://$FLP_IP:8443
   Cluster      $CLUSTER_NAME — registered in Forge project "$BNKFORGE_PROJECT"

   Confirm on the cluster:
     ibmcloud ks cluster config -c $CLUSTER_NAME --admin
     kubectl -n f5-utils get licenses.k8s.f5net.com      # expect STATE=Active
     kubectl get pods -A | grep f5-

   Remove everything this demo created (the cluster and the Transit Gateway stay):
     $0 teardown
EOF
ok "disconnected deployment complete"
