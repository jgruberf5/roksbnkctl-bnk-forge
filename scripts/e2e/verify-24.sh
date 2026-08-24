#!/usr/bin/env bash
# Check a cluster against F5's approved BNK 2.4 reference.
#
#   KUBECONFIG=<file> ./verify-24.sh [cluster-name-for-flavour-check]
#
# The expected values are not invented: they were read from
# staging-small-8c-20g, the cluster engineering approved as the reference, and
# they match what roksbnkctl's support_matrix.yaml records for 2.4.0-EA.
#
#   manifestVersion 2.4.0-EA   deploymentSize Tiny   tmmReplicas 3
#   watchNamespaces ["All"]    product.gatewayAPI true   18/18 conditions True
#
# Two traps this encodes, both found by checking the reference rather than
# assuming:
#   * `.spec.version` is EMPTY on a real 2.4 cluster — the field is
#     `.spec.manifestVersion`. Asserting on .spec.version fails a healthy cluster.
#   * `ibmcloud ks worker ls` reports the profile as `.flavor`, not
#     `.machineType`; the latter reads empty and makes a correct cluster look wrong.
set -uo pipefail
CLUSTER="${1:-}"
PASS=0; FAIL=0
ok(){   printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31mFAIL\033[0m  %-34s got %s, want %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
cmp_(){ [[ "$2" == "$3" ]] && ok "$1" "$2" || bad "$1" "$2" "$3"; }

CNE=$(timeout 90 kubectl get cneinstance -A -o json 2>/dev/null)
[[ -z "$CNE" || "$(jq -r '.items|length' <<<"$CNE" 2>/dev/null)" == "0" ]] && { echo "  no CNEInstance found — BNK is not installed"; exit 1; }
S=$(jq -r '.items[0].spec' <<<"$CNE")

cmp_ "manifestVersion 2.4"  "$(jq -r '.manifestVersion // "-"' <<<"$S")"        "2.4.0-EA"
cmp_ "deploymentSize"       "$(jq -r '.deploymentSize // "-"' <<<"$S")"         "Tiny"
cmp_ "tmmReplicas"          "$(jq -r '.tmmReplicas // "-"' <<<"$S")"            "3"
cmp_ "watchNamespaces"      "$(jq -c '.watchNamespaces // "-"' <<<"$S")"        '["All"]'
cmp_ "product.gatewayAPI"   "$(jq -r '.product.gatewayAPI // "-"' <<<"$S")"     "true"

TOT=$(jq -r '.items[0].status.conditions // [] | length' <<<"$CNE")
TRU=$(jq -r '.items[0].status.conditions // [] | map(select(.status=="True")) | length' <<<"$CNE")
cmp_ "CNEInstance conditions" "$TRU/$TOT" "18/18"

# 2.4 NADs: the product supplies macvlan-internal and roksbnkctl must NOT
# advertise macvlan-conf, which is the pre-2.4 name (roksbnkctl line_gating_test).
NADS=$(timeout 60 kubectl get net-attach-def -A --no-headers 2>/dev/null)
cmp_ "no macvlan-conf (pre-2.4)" "$(grep -c 'macvlan-conf' <<<"$NADS" || true)" "0"
cmp_ "product macvlan-internal"  "$(grep -c 'macvlan-internal' <<<"$NADS" || true)" "1"

STUCK=$(timeout 90 kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^f5-/ && $4!="Running" && $4!="Completed"' | wc -l)
cmp_ "no f5 pods stuck" "$STUCK" "0"
TMM=$(timeout 90 kubectl get pods -n f5-bnk --no-headers 2>/dev/null | grep -c 'f5-tmm' || true)
cmp_ "f5-tmm pods" "$TMM" "3"

if [[ -n "$CLUSTER" ]]; then
  FL=$(timeout 120 ibmcloud ks worker-pool ls --cluster "$CLUSTER" 2>/dev/null | awk 'NR==3{print $3}')
  cmp_ "worker profile" "${FL:-unknown}" "cx3d.8x20"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
