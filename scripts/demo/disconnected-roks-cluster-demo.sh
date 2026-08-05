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
    if (t.get("provider") or "").lower()=="ibm":
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

# ── reading back what a deployment built ─────────────────────────────────────
# The opentofu modules publish floating IPs and VPC ids as terraform outputs, but
# whether Forge surfaces them over the API depends on the build. Resolve them from
# IBM Cloud instead: the modules name every resource deterministically off the
# prefix, so a lookup by name is exact and works on any Forge build.
ibm_ready() {
  ibmcloud is instances --output json >/dev/null 2>&1 && return 0
  [[ -n "${IBMCLOUD_API_KEY:-}" ]] || die "set IBMCLOUD_API_KEY (or run 'ibmcloud login') so the demo can read back module outputs"
  ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r "$REGION" -g "$RESOURCE_GROUP" >/dev/null 2>&1 \
    || die "ibmcloud login failed"
  ibmcloud target -r "$REGION" >/dev/null 2>&1
}

# vsi_field <name> <private|floating|vpc> — exact instance name, empty if absent
vsi_field() {
  ibmcloud is instances --output json 2>/dev/null | python3 -c '
import sys,json
name,want=sys.argv[1],sys.argv[2]
for i in json.load(sys.stdin):
    if i.get("name")!=name: continue
    n=(i.get("primary_network_interface") or i.get("network_interfaces",[{}])[0]) or {}
    if want=="private":  print(n.get("primary_ip",{}).get("address") or n.get("primary_ipv4_address") or "")
    elif want=="vpc":    print((i.get("vpc") or {}).get("id") or "")
    else:                print(((n.get("floating_ips") or [{}])[0]).get("address") or "")
    break' "$1" "$2" 2>/dev/null | tr -d '\r\n'
}

# fip_by_name <fip-name> — the module reserves it before the instance exists
fip_by_name() {
  ibmcloud is floating-ips --output json 2>/dev/null | python3 -c '
import sys,json
want=sys.argv[1]
for f in json.load(sys.stdin):
    if f.get("name")==want: print(f.get("address") or ""); break' "$1" 2>/dev/null | tr -d '\r\n'
}

# resolve <var> <description> <lookup-command...> — look it up, prompt only if that fails
resolve() {
  local var="$1" desc="$2"; shift 2
  local cur="${!var:-}" v=""
  [[ -n "$cur" ]] && return 0
  v="$("$@")"
  if [[ -n "$v" ]]; then printf -v "$var" '%s' "$v"; say "$desc = $v"; return 0; fi
  warn "could not resolve $desc from IBM Cloud — falling back to a prompt"
  ask "$var" "$desc"
}

# deploy <tag> <release-id> <project-name> <vars-json>  -> sets DEPLOY_PID / DEPLOY_MODS
#
# Resumable: a phase whose project id is already on disk is adopted rather than
# deployed again. The whole run takes over an hour, and a failure in a later phase
# should not mean rebuilding the VPC and the appliances that already came up
# clean — re-running the script simply continues from where it stopped.
# forge_wait_module returns immediately for a module that is already applied.
deploy() {
  local tag="$1" rel="$2" name="$3" vars="$4"
  local tmp="$STATE/.$tag.create"   # separate line: under `set -u`, expanding $tag
                                    # in the same `local` that declares it is unbound
  if [[ -s "$STATE/$tag.project" ]]; then
    DEPLOY_PID=$(cat "$STATE/$tag.project"); DEPLOY_MODS=$(cat "$STATE/$tag.modules")
    say "resuming $tag from project $DEPLOY_PID (delete $STATE/$tag.project to redeploy)"
    # Re-apply the first module that is not already applied. A resume after a
    # mid-chain failure has to restart the module that failed, not just wait on
    # it — waiting on an apply_failed module fails instantly. Re-applying the
    # earliest incomplete one lets Forge's dependency graph carry the rest.
    local m st
    for m in $DEPLOY_MODS; do
      st=$(forge_module_status "$m")
      if [[ "$st" != "applied" ]]; then
        say "$tag: module $m is '$st' — re-applying"
        forge_apply "$m"
        break
      fi
    done
  else
    DEPLOY_MODS=$(forge_create_project "$rel" "$name" "$REGION" \
                    "$FORGE_CREDENTIAL_TEMPLATE_ID" "$vars" 2> >(tee "$tmp" >&2)) \
      || die "could not create the $tag project"
    DEPLOY_PID=$(awk '/^PROJECT/{print $2}' "$tmp")
    [[ -n "$DEPLOY_PID" ]] || die "$tag project was created but returned no project id"
    echo "$DEPLOY_PID" > "$STATE/$tag.project"; echo "$DEPLOY_MODS" > "$STATE/$tag.modules"
    # Optional modules arrive disabled; this demo wants every module the
    # blueprint declares, and has supplied inputs for all of them.
    # NOTE: optional modules are left DISABLED. Enabling one here would also wipe
    # the blueprint's depends_on edges (update_module recomputes the whole
    # project's dependencies from library metadata), and the harbor blueprint's
    # optional mirror cannot work anyway: its registry host and CA are declared
    # `source: module`, and the container-engine path never runs the dependency
    # wiring that resolves those. The mirror runs as its own deployment below.
    # Apply the first module only; Forge's dependency graph triggers the rest as
    # each one's dependencies are met. Applying them all races the orchestrator.
    forge_apply "$(echo "$DEPLOY_MODS" | awk '{print $1}')"
  fi
  for m in $DEPLOY_MODS; do forge_wait_module "$m" "$tag" 5400; done
}

# ── teardown ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "teardown" ]]; then
  phase "Teardown"
  for f in disco flp mirror harbor; do            # reverse of creation order
    [[ -f "$STATE/$f.project" ]] || continue
    pid=$(cat "$STATE/$f.project")
    say "destroying project $pid ($f) …"
    forge_destroy_project "$pid" || warn "destroy-all returned non-zero for $pid"
    # Wait for "destroyed", not merely a terminal state — see forge_wait_module.
    # The project must not be deleted while any module still holds resources: the
    # delete abandons the in-flight destroys and orphans whatever they owned.
    local_ok=1
    for mid in $(cat "$STATE/$f.modules" 2>/dev/null); do
      forge_wait_module "$mid" "module $mid" 3600 destroyed || local_ok=0
    done
    if [[ $local_ok == 1 ]]; then
      forge_delete_project "$pid"; rm -f "$STATE/$f.project" "$STATE/$f.modules"
    else
      warn "project $pid still has modules that did not destroy — leaving it in place"
    fi
  done
  ok "teardown complete — the adopted cluster and the Transit Gateway are left intact"
  exit 0
fi

# ── 1. catalog ───────────────────────────────────────────────────────────────
phase "1/5  Sync the module + blueprint catalog"
forge_sync_source "roksbnkctl-bnk-forge"
HARBOR_REL=$(forge_latest_release "ibm-harbor-registry") || die "no valid Harbor blueprint release found"
DISCO_REL=$(forge_latest_release "ibm-roks-disconnected-bnk-roksbnkctl") || die "no valid disconnected blueprint release found"
FLP_REL=$(forge_latest_release "ibm-flp-vsi-roksbnkctl") || die "no valid FLP blueprint release found"
MIRROR_REL=$(forge_latest_release "ibm-far-mirror") || die "no valid FAR mirror blueprint release found"
for r in "$HARBOR_REL" "$MIRROR_REL" "$FLP_REL" "$DISCO_REL"; do forge_import_release "$r"; done
ok "releases imported — harbor=$HARBOR_REL mirror=$MIRROR_REL flp=$FLP_REL disconnected=$DISCO_REL"

# ── 2. Harbor ────────────────────────────────────────────────────────────────
phase "2/5  Private Harbor registry"
say "Creates the services VPC, attaches it to $TRANSIT_GATEWAY, installs Harbor, and"
say "replicates the BNK supply chain into it — the mirror module takes the registry"
say "address and CA straight from the harbor module's outputs."
say "Harbor's hostname is its PRIVATE IP so the token realm is reachable from"
say "no-egress worker nodes; the cert SAN covers the floating IP too."
HARBOR_VARS=$(python3 -c '
import json,sys
k=dict(zip(["prefix","region","rg","zone","ssh","pw","tgw","cidr","spare","projects",
            "repo","cosi","cosb","cosr","far","jwt","mv"],sys.argv[1:]))
print(json.dumps({"prefix":k["prefix"]+"-svc","region":k["region"],"resource_group":k["rg"],
 "zone":k["zone"],"ssh_key_name":k["ssh"],"harbor_admin_password":k["pw"],
 "transit_gateway":k["tgw"],"subnet_cidr":k["cidr"],"services_spare_cidr":k["spare"],
 "registry_projects":k["projects"],"create_vpc":True,"public_gateway":True,
 # the optional FAR-mirror module in this blueprint: it takes the registry address
 # and CA from the harbor module outputs, so only the supply chain is needed here
 "registry_repo_prefix":k["repo"],"cos_instance":k["cosi"],"cos_bucket":k["cosb"],
 "cos_region":k["cosr"],"far_auth_file":k["far"],"subscription_jwt_file":k["jwt"],
 "manifest_version":k["mv"]}))' \
  "$PREFIX" "$REGION" "$RESOURCE_GROUP" "$ZONE" "$SSH_KEY_NAME" "$HARBOR_ADMIN_PASSWORD" \
  "$TRANSIT_GATEWAY" "$SERVICES_SUBNET_CIDR" "$SERVICES_SPARE_CIDR" "$HARBOR_PROJECT,bnk-status" \
  "$HARBOR_PROJECT" "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" "$FAR_AUTH_FILE" \
  "$SUBSCRIPTION_JWT_FILE" "$MANIFEST_VERSION")
deploy harbor "$HARBOR_REL" "$PREFIX-harbor" "$HARBOR_VARS"
HARBOR_PID="$DEPLOY_PID"

ibm_ready
resolve HARBOR_FIP "Harbor floating IP" fip_by_name "$PREFIX-svc-harbor-fip"
echo "$HARBOR_FIP" > "$STATE/harbor.fip"
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

# ── 2b. mirror ───────────────────────────────────────────────────────────────
phase "2b/5  Mirror the BNK supply chain into Harbor"
say "Its own deployment, no cluster involved. Takes the registry address and the"
say "CA captured above, replicates every artifact out of FAR, then verifies each"
say "one by digest. Already-present artifacts are skipped, so a re-run is cheap."
MIRROR_VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({"prefix":k[0],"region":k[1],"resource_group":k[2],
 "registry_generic_host":k[3],"registry_repo_prefix":k[4],
 "registry_username":"admin","registry_password":k[5],
 "registry_ca_b64":k[6],"registry_ca_sha256":k[7],
 "cos_instance":k[8],"cos_bucket":k[9],"cos_region":k[10],
 "far_auth_file":k[11],"subscription_jwt_file":k[12],"manifest_version":k[13]}))' \
  "$PREFIX" "$REGION" "$RESOURCE_GROUP" "$HARBOR_IP" "$HARBOR_PROJECT" "$HARBOR_ADMIN_PASSWORD" \
  "$HARBOR_CA" "$HARBOR_PIN" "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" \
  "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE" "$MANIFEST_VERSION")
deploy mirror "$MIRROR_REL" "$PREFIX-far-mirror" "$MIRROR_VARS"

# ── 3. FLP ───────────────────────────────────────────────────────────────────
phase "3/5  F5 License Proxy appliance"
say "A standalone VSI in the services VPC — no cluster. The proxy is the only"
say "component needing egress to F5; the cluster reaches it privately."
resolve HARBOR_VPC "Services VPC id" vsi_field "$PREFIX-svc-harbor" vpc
echo "$HARBOR_VPC" > "$STATE/harbor.vpc"
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
deploy flp "$FLP_REL" "$PREFIX-flp" "$FLP_VARS"
FLP_PID="$DEPLOY_PID"

# roksbnkctl names the appliance "flp-vsi" unprefixed (terraform/modules/flp_vsi/
# main.tf), so the lookup is by that literal name — and only one can exist per region.
resolve FLP_IP "FLP private IP" vsi_field "flp-vsi" private
echo "$FLP_IP" > "$STATE/flp.ip"
# The proxy's root CA lives on the appliance (terraform writes it to /opt/flp/ca.crt
# and also publishes it as the flp_root_ca output). The FLP's :22 is on the private
# plane only, so reach it through Harbor with ProxyJump — which keeps the private key
# on THIS host. Copying the key onto the bastion would leave it there for the life of
# the VSI, readable by anyone who later gets on the box.
# ProxyCommand rather than ProxyJump: ProxyJump starts its own ssh to the bastion,
# and -i applies only to the final hop, so the jump authenticates with the default
# identities and is refused when the demo key is not one of them. Naming the key in
# the ProxyCommand makes both hops use it.
FLP_CA=$(ssh "${SSH_OPTS[@]}" \
  -o "ProxyCommand=ssh -i $SSH_KEY_FILE -o StrictHostKeyChecking=no -W %h:%p ubuntu@$HARBOR_FIP" \
  "ubuntu@$FLP_IP" "sudo base64 -w0 /opt/flp/ca.crt" 2>/dev/null | tr -d '\r\n')
[[ -n "$FLP_CA" ]] || die "could not read the FLP root CA (jumped via $HARBOR_FIP)"
ok "FLP at https://$FLP_IP:8443 — root CA captured"

# ── 4+5. the disconnected chain ──────────────────────────────────────────────
phase "4/5  Register the cluster, install BNK"
say "Two modules. Registration runs FIRST so the cluster is on Forge's Kubernetes"
say "page and watchable while BNK installs onto it. The mirror is already populated."
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
deploy disco "$DISCO_REL" "$PREFIX-disconnected" "$DISCO_VARS"
DISCO_PID="$DEPLOY_PID"; DISCO_MODS="$DEPLOY_MODS"


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
