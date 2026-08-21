#!/usr/bin/env bash
# Release a cluster's Forge REGISTRATION so the next project can adopt it.
#
#   ./release-registration.sh <cluster-name>
#
# This is the handover step CONSTRAINTS.md prescribes, and the step that made
# variants 3 and 4 unrunnable for as long as nobody performed it.
#
# What blocks the adopting variant is NOT that BNK is installed on the cluster --
# leaving BNK installed is fine. It is that the cluster is still registered to the
# PREVIOUS project. Since roksbnkctl v1.42.0 `bnkforge register` refuses a cluster
# another project holds (naming the owner) rather than silently moving it, so the
# adopting module dies at:
#
#     error: step 'bnkforge-register' failed (exit 1)
#
# which is exactly what module 32 and module 39 did here, and module 149 did on
# 2026-08-08. That one went apply_failed -> applied on re-apply after this
# release, with no other change.
#
# `bnk down` from a host workspace is NOT this step: the Forge container module
# owns roksbnkctl's state inside its deployment-scoped /work, so a host workspace
# has never seen the install and `bnk down` is a silent no-op.
#
# Note /api/clusters is a 404 -- the collection is /api/k8s/clusters.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
NAME="${1:?usage: release-registration.sh <cluster-name>}"
T=$(curl -sk --max-time 30 -X POST "$FORGE_URL/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token//empty')
[[ -n "$T" ]] || { echo "cannot authenticate to $FORGE_URL" >&2; exit 2; }

ID=$(curl -sk --max-time 40 "$FORGE_URL/api/k8s/clusters" -H "Authorization: Bearer $T" \
     | jq -r --arg n "$NAME" '(.clusters//.)[]?|select(.name==$n)|.id' | head -1)
if [[ -z "$ID" ]]; then
  echo "   $NAME: no Forge registration found — nothing to release"
  exit 0
fi
code=$(curl -sk --max-time 40 -o /dev/null -w '%{http_code}' \
       -X DELETE "$FORGE_URL/api/k8s/clusters/$ID" -H "Authorization: Bearer $T")
case "$code" in
  200|204) echo "   $NAME: Forge registration $ID released (HTTP $code)" ;;
  404)     echo "   $NAME: registration $ID already gone (HTTP 404)" ;;
  *)       echo "   $NAME: FAILED to release registration $ID (HTTP $code)" >&2; exit 1 ;;
esac

# Prove it, rather than trusting the status code: the adopting variant fails 45
# minutes downstream if this silently did not take.
sleep 2
STILL=$(curl -sk --max-time 40 "$FORGE_URL/api/k8s/clusters" -H "Authorization: Bearer $T" \
        | jq -r --arg n "$NAME" '(.clusters//.)[]?|select(.name==$n)|.id' | head -1)
[[ -n "$STILL" ]] && { echo "   $NAME: STILL registered as $STILL after delete" >&2; exit 1; }
echo "   $NAME: verified unregistered — ready to adopt"
