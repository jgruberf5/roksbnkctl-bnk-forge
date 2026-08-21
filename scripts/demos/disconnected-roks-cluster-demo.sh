#!/usr/bin/env bash
# disconnected-roks-cluster-demo.sh — drive the whole air-gapped BNK deployment
# through the BNK Forge REST API.
#
#   Harbor registry + FAR mirror  →  FLP appliance  →  cluster registry → BNK install
#
# Everything runs as BNK Forge deployments; this script only calls the API,
# waits, and carries the handoffs the API cannot (Harbor's CA and the FLP's root
# CA, both of which live on their VSIs and must be supplied out of band).
#
#   ./disconnected-roks-cluster-demo.sh up      # deploy (default with no argument)
#   ./disconnected-roks-cluster-demo.sh down    # destroy it all and delete the projects
#
# `down` removes the resources and the Forge projects, and stops there — the
# module source, its modules and the blueprint releases are untouched, so a
# later `up` deploys from the same catalog with nothing to re-register.
#
# Prereqs: an EXISTING ROKS cluster with BNK not installed, an EXISTING Transit
# Gateway, an IBM credential template on the Forge, and an IBM Cloud VPC SSH key
# whose private half is on this host. See .env.example.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/forge-api.sh
source "$HERE/lib/forge-api.sh"

# Parsed before anything prompts: a typo should not cost you a password first.
ACTION="${1:-up}"
# Optional second argument: stop after this phase. Useful when iterating on one
# blueprint — there is no sense rebuilding the FLP and reinstalling BNK to test a
# change to Harbor.
STOP_AFTER="${2:-all}"
case "$STOP_AFTER" in all|harbor|flp|disco) ;; *) printf 'unknown phase %q (all|harbor|flp|disco)\n' "$STOP_AFTER" >&2; exit 2 ;; esac
case "$ACTION" in
  up|down) ;;
  *) printf 'usage: %s [up|down]\n  up    deploy (default)\n  down  destroy what it built and delete the projects (catalog untouched)\n\noptional 2nd arg: all (default) | harbor | flp | disco — stop after that phase\n' \
       "$(basename "$0")" >&2; exit 2 ;;
esac

[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }

# ── inputs ───────────────────────────────────────────────────────────────────
# A prompt is only an answer when someone is there to type one. Unattended (no
# controlling terminal — nohup, CI, an agent), reading /dev/tty fails and the
# old code then accepted the EMPTY string as the answer and carried on. That is
# how a run once wrote an empty harbor.fip and spent the next half hour waiting
# for cloud-init on a host with no address. Refusing loudly beats guessing.
interactive() { [[ -r /dev/tty && -t 0 ]]; }
ask()      { local v="$1" p="$2" d="${3:-}" cur="${!1:-}"; [[ -n "$cur" ]] && return 0
             if ! interactive; then
               [[ -n "$d" ]] && { printf -v "$v" '%s' "$d"; say "$p: using default '$d' (no terminal)"; return 0; }
               die "$p is required and there is no terminal to ask on — set ${v} in the environment or .env"
             fi
             read -r -p "   $p${d:+ [$d]}: " REPLY </dev/tty; printf -v "$v" '%s' "${REPLY:-$d}"; }
ask_secret() { local v="$1" p="$2" cur="${!1:-}"; [[ -n "$cur" ]] && return 0
             interactive || die "$p is required and there is no terminal to ask on — set ${v} in the environment or .env"
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
ask PREFIX               "IBM resource prefix"                 "f5demo"
ask CLUSTER_NAME         "EXISTING cluster to adopt"           "fdisco"
ask TRANSIT_GATEWAY      "EXISTING Transit Gateway"            "bnkci-testing"
ask SSH_KEY_NAME         "IBM Cloud VPC SSH key name"
ask SSH_KEY_FILE         "…matching private key on this host"  "$HOME/.ssh/id_rsa"
ask SERVICES_SUBNET_CIDR "Services subnet CIDR"                "10.243.0.0/24"
ask SERVICES_SPARE_CIDR  "Spare services prefix"               "10.243.1.0/24"
ask COS_BUCKET           "COS bucket holding the FAR key + JWT"
ask BNKFORGE_PROJECT     "Forge project to register the cluster into" "roksbnkctl-existing-cluster"
ask_secret HARBOR_ADMIN_PASSWORD "Harbor admin password to set"

# Forge project names. Deliberately not derived from PREFIX: PREFIX names IBM
# resources and has to stay short and DNS-safe, while these are labels a human
# reads in the UI and should say what they are.
PROJECT_HARBOR="${PROJECT_HARBOR:-f5demo-harbor-registry}"
PROJECT_FLP="${PROJECT_FLP:-f5demo-roksbnkctl-flp}"
PROJECT_DISCO="${PROJECT_DISCO:-f5demo-roksbnkctl-disconnected}"
# The Forge project the adopted cluster is REGISTERED into — the one whose
# Kubernetes page you watch while BNK installs.
BNKFORGE_PROJECT="${BNKFORGE_PROJECT:-f5demo-roksbnkctl-existing-cluster}"

# Forge validates project names as IBM Cloud resource names: lowercase letters,
# digits and '-', starting alphanumeric, 35 chars max. It rejects at POST time,
# which on a fresh run is after Harbor and the FAR mirror have already been
# built — twenty minutes spent to learn a name is one character too long. Check
# every name up front instead, and name the offender.
assert_project_names() {
  local bad=0 n
  for n in "$PROJECT_HARBOR" "$PROJECT_FLP" "$PROJECT_DISCO" "$BNKFORGE_PROJECT"; do
    if (( ${#n} > 35 )); then
      warn "project name '$n' is ${#n} chars; Forge allows 35"; bad=1
    elif [[ ! "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      warn "project name '$n' must be lowercase letters, digits and '-', starting alphanumeric"; bad=1
    fi
  done
  (( bad )) && die "fix the project names above before running"
  return 0
}

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
  # Resolution failures are almost never "the operator knows the value" — they are
  # the CLI pointed at the wrong region, an expired session, or a resource that
  # genuinely is not there. Prompting invited an empty answer; naming the region
  # points at the actual cause. The commonest one, by some distance, is a shell
  # whose `ibmcloud target` region is not the region being deployed into.
  warn "could not resolve $desc from IBM Cloud (region: ${REGION:-<unset>})"
  warn "  check: ibmcloud target -r ${REGION:-<region>}, and that the resource exists there"
  if ! interactive; then
    die "cannot resolve $desc and there is no terminal to ask on — set $var in the environment"
  fi
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
  # Blueprint directory for this phase — the dependency graph is read from the file
  # rather than the API, which serves catalog metadata only.
  local tag_bp
  case "$tag" in
    harbor) tag_bp="harbor-registry" ;;
    flp)    tag_bp="flp-vsi" ;;
    disco)  tag_bp="roks-disconnected" ;;
    mirror) tag_bp="far-mirror" ;;
    *)      tag_bp="$tag" ;;
  esac
  local tmp="$STATE/.$tag.create"   # separate line: under `set -u`, expanding $tag
                                    # in the same `local` that declares it is unbound
  # Stale state points at a project someone deleted in the UI. Adopting it means
  # re-applying module ids that no longer exist, which fails obscurely far from
  # the cause — so check the project is really there and fall through to a fresh
  # deploy if it is not.
  if [[ -s "$STATE/$tag.project" ]] && ! forge_api GET "/api/projects/$(cat "$STATE/$tag.project")" >/dev/null 2>&1; then
    warn "$tag state references project $(cat "$STATE/$tag.project"), which no longer exists — deploying fresh"
    rm -f "$STATE/$tag.project" "$STATE/$tag.modules"
  fi
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
    # Optional modules arrive DISABLED; this demo wants every module the blueprint
    # declares and has supplied inputs for all of them.
    for m in $DEPLOY_MODS; do forge_enable_module "$m"; done
    # Enabling still wipes the blueprint's depends_on edges — update_module
    # recomputes the whole project's dependencies from library metadata, and a
    # blueprint's edges live in the manifest. Put them back before anything is
    # dispatched, or the mirror races the Harbor it depends on.
    forge_restore_dependencies "$HERE/../../blueprints/$tag_bp/forge-blueprint.json" $DEPLOY_MODS
    # Apply the first module only; Forge's dependency graph triggers the rest as
    # each one's dependencies are met. Applying them all races the orchestrator.
    forge_apply "$(echo "$DEPLOY_MODS" | awk '{print $1}')"
  fi
  for m in $DEPLOY_MODS; do forge_wait_module "$m" "$tag" 5400; done
}

# ── down ─────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "down" ]]; then
  phase "Down"
  say "Destroys everything this demo built, in reverse order, and deletes the"
  say "Forge projects. It stops there: the module source, the modules and the"
  say "blueprint releases are left alone, so a later 'up' deploys from the same"
  say "catalog without re-registering anything."
  say "The adopted cluster and the Transit Gateway are never touched."
  for f in disco flp harbor; do            # reverse of creation order
    [[ -f "$STATE/$f.project" ]] || continue
    pid=$(cat "$STATE/$f.project")
    say "destroying project $pid ($f) …"
    forge_destroy_project "$pid" || warn "destroy-all returned non-zero for $pid"
    # Wait for "destroyed", not merely a terminal state — see forge_wait_module.
    # A module that has not STARTED destroying still reads "applied", and treating
    # that as done is how a teardown walks away from live resources.
    down_ok=1
    for mid in $(cat "$STATE/$f.modules" 2>/dev/null); do
      forge_wait_module "$mid" "module $mid" 3600 destroyed || down_ok=0
    done
    if [[ $down_ok == 1 ]]; then
      forge_delete_project "$pid"; rm -f "$STATE/$f.project" "$STATE/$f.modules"
      ok "$f destroyed and project $pid deleted"
    else
      # Deleting now would abandon the in-flight destroys and orphan whatever
      # they still own, with no module left to describe them.
      warn "project $pid has modules that did not destroy — leaving it in place"
    fi
  done
  # The registration project is created by roksbnkctl inside the cluster-registry
  # module (`bnkforge register --project`), not by this script, so there is no
  # state file for it and the loop above cannot see it. As of roksbnkctl v1.37.0
  # the cluster-registry module unregisters the CLUSTER on destroy
  # (`bnkforge unregister`), but the PROJECT that held it is still left behind —
  # nothing owns it. Clean it up here: it did not exist before the demo ran, so
  # `down` should not leave it behind. Only when it is empty; a project someone
  # else put modules in is not ours to delete.
  if [[ -n "${BNKFORGE_PROJECT:-}" ]]; then
    reg_json=$(forge_api GET /api/projects 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
d = json.load(sys.stdin)
for p in (d if isinstance(d, list) else d.get("projects", [])):
    if p.get("name") == want:
        print(p["id"], p.get("module_count") or 0)
        break' "$BNKFORGE_PROJECT" 2>/dev/null)
    if [[ -n "$reg_json" ]]; then
      read -r reg_id reg_mods <<< "$reg_json"
      if [[ "$reg_mods" == "0" ]]; then
        forge_delete_project "$reg_id"
        ok "registration project '$BNKFORGE_PROJECT' ($reg_id) deleted"
      else
        warn "registration project '$BNKFORGE_PROJECT' has $reg_mods module(s) — left in place"
      fi
    fi
  fi
  timing_summary
  ok "down complete — resources destroyed, projects deleted, catalog untouched, cluster and Transit Gateway intact"
  exit 0
fi

# ── 1. catalog ───────────────────────────────────────────────────────────────
assert_project_names

phase "1/4  Sync the module + blueprint catalog"
forge_sync_source "roksbnkctl-bnk-forge"
HARBOR_REL=$(forge_latest_release "ibm-harbor-registry") || die "no valid Harbor blueprint release found"
DISCO_REL=$(forge_latest_release "ibm-roks-disconnected-bnk-roksbnkctl") || die "no valid disconnected blueprint release found"
FLP_REL=$(forge_latest_release "ibm-flp-vsi-roksbnkctl") || die "no valid FLP blueprint release found"
for r in "$HARBOR_REL" "$FLP_REL" "$DISCO_REL"; do forge_import_release "$r"; done
ok "releases imported — harbor=$HARBOR_REL flp=$FLP_REL disconnected=$DISCO_REL"

# ── 2. Harbor ────────────────────────────────────────────────────────────────
phase "2/4  Private Harbor registry + FAR mirror"
say "One deployment: the services VPC, the Transit Gateway attachment, Harbor, and"
say "the FAR mirror that fills it. Harbor's certificate is issued by terraform, so"
say "its CA is a module output and the mirror is wired to it directly — nothing is"
say "copied by hand, and nothing is fetched off the box."
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
deploy harbor "$HARBOR_REL" "$PROJECT_HARBOR" "$HARBOR_VARS"
HARBOR_PID="$DEPLOY_PID"

ibm_ready
resolve HARBOR_FIP "Harbor floating IP" fip_by_name "$PREFIX-svc-harbor-fip"
# Recorded for the operator (and for teardown by hand); NOT read back. Every run
# re-derives these from IBM Cloud, because a cached address from a previous
# instance is worse than no address at all — editing this file looks like it
# should fix a bad lookup and does nothing, which cost real time once.
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

if [[ "$STOP_AFTER" == "harbor" ]]; then
  timing_summary
  ok "stopped after the Harbor phase (--> $0 up to continue, $0 down to remove it)"
  exit 0
fi

# ── 3. FLP ───────────────────────────────────────────────────────────────────
phase "3/4  F5 License Proxy appliance"
say "A standalone VSI in the services VPC — no cluster. The proxy is the only"
say "component needing egress to F5; the cluster reaches it privately."
resolve HARBOR_VPC "Services VPC id" vsi_field "$PREFIX-svc-harbor" vpc
echo "$HARBOR_VPC" > "$STATE/harbor.vpc"   # informational; re-derived each run (see harbor.fip)
FLP_VARS=$(python3 -c '
import json,sys
k=sys.argv[1:]
print(json.dumps({"prefix":k[0]+"-flp","region":k[1],"resource_group":k[2],"flp_vsi_vpc":k[3],
 "flp_vsi_zone":k[4],"flp_vsi_ssh_key":k[5],"flp_vsi_floating_ip":True,
 "cos_instance":k[6],"cos_bucket":k[7],"cos_region":k[8],
 "far_auth_file":k[9],"subscription_jwt_file":k[10],
 "flp_vsi_name_prefix":k[11]}))' \
  "$PREFIX" "$REGION" "$RESOURCE_GROUP" "$HARBOR_VPC" "$ZONE" "$SSH_KEY_NAME" \
  "$COS_INSTANCE" "$COS_BUCKET" "$COS_REGION" "$FAR_AUTH_FILE" "$SUBSCRIPTION_JWT_FILE" \
  "${FLP_VSI_NAME_PREFIX:-}")
deploy flp "$FLP_REL" "$PROJECT_FLP" "$FLP_VARS"
FLP_PID="$DEPLOY_PID"

# The appliance's VSI name depends on whether a name prefix was set. roksbnkctl
# v1.47.0 (#88) made the names prefixable — "<prefix>-flp-vsi" — but left the
# default EMPTY on purpose, because renaming a resource replaces it, and an
# upgrade must not destroy a running proxy. So the unprefixed literal is still
# the default and still what this demo gets.
#
# Look for the prefixed name first anyway: the moment anyone sets
# FLP_VSI_NAME_PREFIX (to run a second proxy, or to make this one visible to the
# orphan-cleanup blueprints, which sweep by <prefix>-* and cannot see a bare
# flp-vsi), the old lookup would fail with "no VSI named flp-vsi" — which reads
# like the deploy failed rather than like the demo looked for the wrong name.
FLP_VSI_NAME="flp-vsi"
if [[ -n "${FLP_VSI_NAME_PREFIX:-}" ]]; then
  FLP_VSI_NAME="${FLP_VSI_NAME_PREFIX}-flp-vsi"
  say "FLP resource names are prefixed: looking for $FLP_VSI_NAME"
fi
resolve FLP_IP "FLP private IP" vsi_field "$FLP_VSI_NAME" private
echo "$FLP_IP" > "$STATE/flp.ip"           # informational; re-derived each run (see harbor.fip)
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

if [[ "$STOP_AFTER" == "flp" ]]; then
  timing_summary
  ok "stopped after the FLP phase"
  exit 0
fi

# ── 4+5. the disconnected chain ──────────────────────────────────────────────
phase "4/4  Register the cluster, install BNK"
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
# Keep the cluster's inventory fresh in Forge while BNK installs into it — the
# whole reason registration runs first. Forge scans once at registration and
# never again, so without this you watch an empty cluster for 40 minutes.
CLUSTER_WATCH_PID=$(forge_watch_cluster "$CLUSTER_NAME" 60)
say "rescanning $CLUSTER_NAME every 60s so BNK appears on the Kubernetes page as it installs"

deploy disco "$DISCO_REL" "$PROJECT_DISCO" "$DISCO_VARS"

[[ -n "${CLUSTER_WATCH_PID:-}" ]] && kill "$CLUSTER_WATCH_PID" 2>/dev/null
# One last scan so the finished state is what the page shows.
CID=$(forge_cluster_id_by_name "$CLUSTER_NAME")
[[ -n "$CID" ]] && forge_api PUT "/api/k8s/clusters/$CID" '{}' >/dev/null 2>&1 \
  && ok "final cluster rescan queued — the Kubernetes page reflects the installed BNK"
DISCO_PID="$DEPLOY_PID"; DISCO_MODS="$DEPLOY_MODS"


phase "Verify"
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
timing_summary
ok "disconnected deployment complete"
