#!/usr/bin/env bash
# Mirror the BNK supply chain into a JFrog Container Registry, driven entirely by
# BNK Forge.
#
#   ./artifactory-mirror-demo.sh [up|down|verify]
#
# WHAT IT SHOWS
# The same far-mirror module that fills a private Harbor also fills JFrog
# Artifactory: `registry_target: generic` points it at any Docker-v2 registry.
# Nothing here is Harbor-specific and nothing is copied by hand -- Forge pulls the
# entitled images from F5 using the FAR auth key and subscription JWT out of COS,
# and pushes them into the Artifactory repository you name.
#
# WHAT IT PROVES, at the Artifactory API rather than from the module's own log:
#   * the repository exists and is a LOCAL Docker repo
#   * images landed, and how many
#   * a sampled manifest's digest matches what the registry serves back
# A module reporting success is not evidence that a registry has the bits.
#
# CREDENTIALS
# Everything comes from .env (gitignored) or the environment. The token is a
# JFrog access token; the USERNAME is the account it was minted for, NOT the
# token itself. Artifactory accepts `Bearer <token>` and `-u <user>:<token>`, but
# `-u <token>:<token>` returns 401 -- a mistake that reads as an expired token.
# Decode the token's `sub` claim to find the user:
#   echo <jwt> | cut -d. -f2 | base64 -d | jq -r .sub    -> jfac@.../users/admin
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }
# shellcheck source=lib/forge-api.sh
source "$HERE/lib/forge-api.sh"
ACTION="${1:-up}"
STATE="$HERE/.demo-state"; mkdir -p "$STATE"

: "${ARTIFACTORY_HOST:=artifactory.grubernet.org}"
: "${ARTIFACTORY_REPO:=bnk-mirror}"
: "${ARTIFACTORY_USER:=}"
: "${ARTIFACTORY_TOKEN:?set ARTIFACTORY_TOKEN in scripts/demos/.env (a JFrog access token)}"
: "${REGION:?set REGION}"; : "${RESOURCE_GROUP:?set RESOURCE_GROUP}"
: "${COS_BUCKET:?set COS_BUCKET — the supply-chain bucket holding the FAR auth key and subscription JWT}"
PROJECT="${ARTIFACTORY_PROJECT:-f5demo-artifactory-mirror}"
BP_ID="artifactory-far-mirror-roksbnkctl"

# Derive the username from the token rather than making the operator supply it.
# The sub claim is jfac@<instance>/users/<name>; the trailing element is the user.
if [[ -z "$ARTIFACTORY_USER" ]]; then
  ARTIFACTORY_USER=$(printf '%s' "$ARTIFACTORY_TOKEN" | cut -d. -f2 \
    | python3 -c 'import sys,base64,json;p=sys.stdin.read().strip();p+="="*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p))["sub"].rsplit("/",1)[-1])' 2>/dev/null) \
    || die "could not decode the token's sub claim — set ARTIFACTORY_USER explicitly"
fi
AUTH=(-u "$ARTIFACTORY_USER:$ARTIFACTORY_TOKEN")
BASE="https://$ARTIFACTORY_HOST/artifactory"

# ── verification, straight at the Artifactory API ────────────────────────────
# GET /api/repositories/<key> is ARTIFACTORY PRO ONLY -- on OSS it returns
# HTTP 400 "This REST API is available only in Artifactory Pro", which reads as
# a missing repository. The LIST endpoint works on every edition, so filter it.
art_repo_type() {
  curl -sk --max-time 40 "${AUTH[@]}" "$BASE/api/repositories" 2>/dev/null \
    | jq -r --arg k "$ARTIFACTORY_REPO" '(.[] | select(.key==$k) | .type + "/" + (.packageType // "?")) // empty'
}
art_images() { curl -sk --max-time 60 "${AUTH[@]}" "$BASE/api/docker/$ARTIFACTORY_REPO/v2/_catalog" 2>/dev/null | jq -r '.repositories // [] | length'; }
art_tags()   { curl -sk --max-time 60 "${AUTH[@]}" "$BASE/api/docker/$ARTIFACTORY_REPO/v2/$1/tags/list" 2>/dev/null | jq -r '.tags // [] | join(",")'; }

verify() {
  phase "Verify at the Artifactory API"
  local kind n img tag dig
  kind=$(art_repo_type)
  [[ "$kind" == LOCAL/Docker || "$kind" == local/docker ]] \
    && ok "repository $ARTIFACTORY_REPO is $kind" \
    || warn "repository $ARTIFACTORY_REPO is '$kind' — a mirror target must be a LOCAL Docker repo"
  n=$(art_images); say "images in $ARTIFACTORY_REPO: ${n:-0}"
  (( ${n:-0} > 0 )) || { warn "no images — the mirror did not land anything"; return 1; }

  # Digest-match one image: ask for the manifest and compare the digest the
  # registry reports in the header against the one it computes over the body.
  img=$(curl -sk --max-time 60 "${AUTH[@]}" "$BASE/api/docker/$ARTIFACTORY_REPO/v2/_catalog" | jq -r '.repositories[0] // empty')
  tag=$(art_tags "$img" | cut -d, -f1)
  dig=$(curl -sk --max-time 60 -D- -o /tmp/man.$$ "${AUTH[@]}" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json' \
        "$BASE/api/docker/$ARTIFACTORY_REPO/v2/$img/manifests/$tag" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  local calc; calc="sha256:$(sha256sum /tmp/man.$$ 2>/dev/null | cut -d' ' -f1)"; rm -f /tmp/man.$$
  if [[ -n "$dig" && "$dig" == "$calc" ]]; then
    ok "digest verified for $img:$tag  ${dig:0:23}…"
  else
    warn "digest mismatch for $img:$tag — served=${dig:-none} computed=$calc"
    return 1
  fi
  ok "mirror verified: ${n} images, digest-matched"
}

# ── preflight: fail in seconds, not after a deploy ───────────────────────────
preflight() {
  phase "Preflight"
  local code
  code=$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$BASE/api/system/ping")
  [[ "$code" == "200" ]] || die "Artifactory ping returned $code as '$ARTIFACTORY_USER' — check the token and that the username is the token's sub, not the token"
  ok "authenticated to $ARTIFACTORY_HOST as $ARTIFACTORY_USER"
  local kind; kind=$(art_repo_type)
  [[ -n "$kind" ]] || die "repository '$ARTIFACTORY_REPO' is not in the repository list — create it as a LOCAL Docker repo first"
  [[ "$kind" == LOCAL/Docker ]] || die "repository '$ARTIFACTORY_REPO' is $kind — the mirror target must be a LOCAL Docker repo"
  ok "repository $ARTIFACTORY_REPO is $kind"
  say "images before the run: $(art_images)"
}

forge_login "$FORGE_URL" "$FORGE_USER" "$FORGE_PASSWORD"

case "$ACTION" in
  verify) preflight; verify; exit $? ;;
  down)
    phase "Teardown"
    PID=$(cat "$STATE/artifactory.project" 2>/dev/null)
    [[ -z "$PID" ]] && { say "no recorded project — nothing to tear down"; exit 0; }
    forge_destroy_project "$PID" || warn "destroy-all returned non-zero"
    for m in $(cat "$STATE/$PID.modules" 2>/dev/null); do forge_wait_module "$m" "module $m" 3600 destroyed || exit 1; done
    forge_delete_project "$PID"; rm -f "$STATE/artifactory.project" "$STATE/$PID.modules"
    ok "project $PID destroyed and deleted"
    say "images left in $ARTIFACTORY_REPO: $(art_images)  (0 only if delete_artifacts_on_destroy was true)"
    exit 0 ;;
esac

preflight

phase "Sync the catalog"
forge_sync_source roksbnkctl >/dev/null
REL=$(forge_latest_release "$BP_ID") || die "no release for $BP_ID — is the blueprint imported?"
forge_import_release "$REL" || die "release $REL is not deployable"
ok "blueprint release $REL"

phase "Deploy the mirror"
VARS=$(A_HOST="$ARTIFACTORY_HOST" A_REPO="$ARTIFACTORY_REPO" A_USER="$ARTIFACTORY_USER" \
  A_TOK="$ARTIFACTORY_TOKEN" A_REGION="$REGION" A_RG="$RESOURCE_GROUP" \
  A_COSB="$COS_BUCKET" A_COSI="${COS_INSTANCE:-}" A_COSR="${COS_REGION:-}" \
  A_MV="${MANIFEST_VERSION:-}" A_FAR="${FAR_AUTH_FILE:-}" A_JWT="${SUBSCRIPTION_JWT_FILE:-}" \
  A_CA="${ARTIFACTORY_CA_B64:-}" A_DEL="${DELETE_ARTIFACTS_ON_DESTROY:-true}" \
python3 -c '
import json, os
e = os.environ
print(json.dumps({
 "artifactory_host":e["A_HOST"], "artifactory_repo_prefix":e["A_REPO"],
 "artifactory_username":e["A_USER"], "artifactory_token":e["A_TOK"],
 "artifactory_ca_b64":e["A_CA"],
 "region":e["A_REGION"], "resource_group":e["A_RG"],
 "cos_bucket":e["A_COSB"], "cos_instance":e["A_COSI"], "cos_region":e["A_COSR"],
 "manifest_version":e["A_MV"], "far_auth_file":e["A_FAR"],
 "subscription_jwt_file":e["A_JWT"],
 "delete_artifacts_on_destroy":e["A_DEL"]}))')

TMP="$STATE/.artifactory.create"
MODS=$(forge_create_project "$REL" "$PROJECT" "$REGION" "$FORGE_CREDENTIAL_TEMPLATE_ID" "$VARS" 2> >(tee "$TMP" >&2)) \
  || die "could not create project '$PROJECT'"
PID=$(awk '/^PROJECT/{print $2}' "$TMP")
[[ -n "$PID" ]] || die "project created but no id returned"
echo "$PID" > "$STATE/artifactory.project"; echo "$MODS" > "$STATE/$PID.modules"
ok "project $PID, modules: $MODS"

for m in $MODS; do forge_enable_module "$m"; done
forge_api PUT "/api/projects/$PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null
FIRST=$(echo "$MODS" | awk '{print $1}')
forge_apply "$FIRST"
# The mirror pulls and pushes every entitled image; 20-40 minutes is normal.
forge_wait_module "$FIRST" "far-mirror" 5400 || die "the mirror module failed"

verify || die "the module reported success but the registry does not have the bits"
timing_summary
phase "Done"
say "  registry   https://$ARTIFACTORY_HOST/artifactory/$ARTIFACTORY_REPO"
say "  images     $(art_images)"
say "  teardown   ./artifactory-mirror-demo.sh down"
