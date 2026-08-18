#!/usr/bin/env bash
# Find IBM Cloud resources this catalog created that no BNK Forge project owns.
#
# READ-ONLY. It deletes nothing. Its whole job is to produce the inventory that
# orphan-reap consumes, so that the destructive half can only ever act on
# something this scan actually found.
#
# WHY REST AND NOT THE ibmcloud CLI
# The runner image ships only the container-service (ks) plugin — no `is` (VPC)
# and no `tg` (transit gateway). Those are exactly what is needed to find leaked
# VPCs and gateways, which is most of what leaks. Installing plugins at runtime
# would mutate the image and need egress to IBM's plugin repo on every run, so
# this talks to the IAM/VPC/TG/Containers REST APIs with curl + jq, both of which
# the image does have.
#
# WHY A PREFIX ALLOWLIST IS MANDATORY
# This account is shared. A scan run here sees 21 ROKS clusters across nine
# regions belonging to other teams, plus VPCs named ecosystems-*, tf-*, pqt-*,
# garuda-*, tc-harness-* and app-us-east-1. "Orphan" cannot mean "not in Forge" —
# almost nothing in this account is in Forge. It means "matches a prefix WE own
# AND no Forge project claims it". Refusing to run without a prefix is the single
# most important guard here.
set -uo pipefail

: "${ORPHAN_NAME_PREFIXES:?set ORPHAN_NAME_PREFIXES — refusing to scan the whole account}"
: "${IBMCLOUD_API_KEY:?set IBMCLOUD_API_KEY}"
: "${ORPHAN_REGION:?set ORPHAN_REGION}"
OUT="${ORPHAN_OUTPUTS_FILE:-/work/orphan-scan.json}"
API_VERSION="${ORPHAN_API_VERSION:-2026-01-01}"

say() { printf '%s\n' "$*" >&2; }

# Empty or whitespace-only prefixes would match everything once turned into a
# regex alternation. Fail loudly instead.
PREFIX_RE=$(printf '%s' "$ORPHAN_NAME_PREFIXES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | paste -sd'|' -)
[[ -n "$PREFIX_RE" ]] || { say "ORPHAN_NAME_PREFIXES contained no usable prefix"; exit 2; }
say "== scanning region $ORPHAN_REGION for names matching: $PREFIX_RE"

TOKEN=$(curl -s --max-time 60 -X POST https://iam.cloud.ibm.com/identity/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' \
  --data-urlencode "apikey=$IBMCLOUD_API_KEY" | jq -r '.access_token // empty')
[[ -n "$TOKEN" ]] || { say "could not get an IAM token from the supplied API key"; exit 1; }

iam()  { curl -s --max-time 120 -H "Authorization: Bearer $TOKEN" "$@"; }
vpcapi() { iam "https://${ORPHAN_REGION}.iaas.cloud.ibm.com/v1/$1?version=${API_VERSION}&generation=2&limit=100"; }

CLUSTERS_JSON=$(iam "https://containers.cloud.ibm.com/global/v2/vpc/getClusters")
VPCS_JSON=$(vpcapi vpcs)
TGWS_JSON=$(iam "https://transit.cloud.ibm.com/v1/transit_gateways?version=${API_VERSION}")
SUBNETS_JSON=$(vpcapi subnets)
PGWS_JSON=$(vpcapi public_gateways)

for pair in "clusters:$CLUSTERS_JSON" "vpcs:$VPCS_JSON" "gateways:$TGWS_JSON"; do
  [[ -n "${pair#*:}" ]] || { say "empty response listing ${pair%%:*} — refusing to report an empty inventory"; exit 1; }
done

# Which clusters does Forge still own? A cluster with a live project is BY
# DEFINITION not an orphan, however well its name matches. When Forge cannot be
# reached we abort rather than assume it owns nothing — assuming that turns every
# managed cluster into a deletion candidate.
CLAIMED=""
if [[ -n "${BNK_FORGE_URL:-}" ]]; then
  INSEC=""; [[ "${BNK_FORGE_INSECURE:-false}" == "true" ]] && INSEC="-k"
  FT=$(curl -s $INSEC --max-time 60 -X POST "$BNK_FORGE_URL/api/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${BNK_FORGE_USER:-}\",\"password\":\"${BNK_FORGE_PASSWORD:-}\"}" \
        | jq -r '.token // empty')
  [[ -n "$FT" ]] || { say "could not authenticate to BNK Forge at $BNK_FORGE_URL — aborting rather than treating every cluster as unclaimed"; exit 1; }
  CLAIMED=$(curl -s $INSEC --max-time 60 "$BNK_FORGE_URL/api/k8s/clusters" -H "Authorization: Bearer $FT" \
            | jq -r 'if type=="array" then .[] else (.clusters // [])[] end | .name' | sort -u)
  say "== Forge claims: ${CLAIMED:-nothing}"
else
  say "== no BNK_FORGE_URL given: every prefix match will be reported as unclaimed"
fi

is_claimed() { [[ -n "$CLAIMED" ]] && printf '%s\n' "$CLAIMED" | grep -qx -- "$1"; }

orphan_clusters=(); orphan_vpcs=(); orphan_gws=()

while IFS=$'\t' read -r name id state; do
  [[ -z "$name" ]] && continue
  if is_claimed "$name"; then say "   cluster $name — claimed by Forge, skipping"; continue; fi
  say "   cluster $name ($state) — ORPHAN"
  orphan_clusters+=("$(jq -nc --arg n "$name" --arg i "$id" --arg s "$state" '{name:$n,id:$i,state:$s}')")
done < <(printf '%s' "$CLUSTERS_JSON" | jq -r --arg re "^($PREFIX_RE)" '.[] | select(.name|test($re)) | [.name,.id,.state] | @tsv')

# A VPC is only an orphan once no cluster is left inside it. A matching VPC whose
# cluster is still running belongs to that cluster, and reaping it would fail on
# vpc_in_use anyway.
LIVE_VPCS=$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[] | .vpcs // [] | .[]' 2>/dev/null | sort -u)
while IFS=$'\t' read -r name id; do
  [[ -z "$name" ]] && continue
  if printf '%s\n' "$LIVE_VPCS" | grep -qx -- "$id"; then say "   vpc $name — still holds a cluster, skipping"; continue; fi
  sub=$(printf '%s' "$SUBNETS_JSON" | jq -r --arg v "$id" '[.subnets[]|select(.vpc.id==$v)]|length')
  pgw=$(printf '%s' "$PGWS_JSON"   | jq -r --arg v "$id" '[.public_gateways[]|select(.vpc.id==$v)]|length')
  say "   vpc $name — ORPHAN ($sub subnets, $pgw public gateways)"
  orphan_vpcs+=("$(jq -nc --arg n "$name" --arg i "$id" --argjson s "$sub" --argjson p "$pgw" '{name:$n,id:$i,subnets:$s,public_gateways:$p}')")
done < <(printf '%s' "$VPCS_JSON" | jq -r --arg re "^($PREFIX_RE)" '.vpcs[] | select(.name|test($re)) | [.name,.id] | @tsv')

while IFS=$'\t' read -r name id; do
  [[ -z "$name" ]] && continue
  conns=$(iam "https://transit.cloud.ibm.com/v1/transit_gateways/$id/connections?version=${API_VERSION}" | jq -r '[.connections // []]|flatten|length')
  say "   gateway $name — ORPHAN ($conns connections)"
  orphan_gws+=("$(jq -nc --arg n "$name" --arg i "$id" --argjson c "${conns:-0}" '{name:$n,id:$i,connections:$c}')")
done < <(printf '%s' "$TGWS_JSON" | jq -r --arg re "^($PREFIX_RE)" '.transit_gateways[] | select(.name|test($re)) | [.name,.id] | @tsv')

join() { local IFS=,; printf '[%s]' "$*"; }
TOTAL=$(( ${#orphan_clusters[@]} + ${#orphan_vpcs[@]} + ${#orphan_gws[@]} ))
mkdir -p "$(dirname "$OUT")"
jq -n \
  --argjson c "$(join "${orphan_clusters[@]+"${orphan_clusters[@]}"}")" \
  --argjson v "$(join "${orphan_vpcs[@]+"${orphan_vpcs[@]}"}")" \
  --argjson g "$(join "${orphan_gws[@]+"${orphan_gws[@]}"}")" \
  --arg region "$ORPHAN_REGION" --arg prefixes "$ORPHAN_NAME_PREFIXES" --argjson total "$TOTAL" \
  '{region:$region, prefixes:$prefixes, orphan_count:$total,
    orphan_clusters:$c, orphan_vpcs:$v, orphan_gateways:$g,
    orphan_cluster_names:($c|map(.name)|join(",")),
    orphan_vpc_ids:($v|map(.id)|join(",")),
    orphan_gateway_ids:($g|map(.id)|join(","))}' > "$OUT"

say "== $TOTAL orphan(s): ${#orphan_clusters[@]} cluster(s), ${#orphan_vpcs[@]} vpc(s), ${#orphan_gws[@]} gateway(s)"
say "== inventory written to $OUT"
cat "$OUT" >&2
