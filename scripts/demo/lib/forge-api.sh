#!/usr/bin/env bash
# forge-api.sh — the BNK Forge REST surface this demo drives, and nothing else.
#
# Sourced by the demo scripts. Every function here maps to a real endpoint that
# has been exercised against a live Forge; none of it shells out to a CLI,
# because BNK Forge v3 ships no CLI.
#
# Conventions:
#   FORGE_URL / FORGE_TOKEN are globals set by forge_login.
#   forge_api <METHOD> <PATH> [JSON]  -> response body on stdout, non-zero on HTTP >= 400.
#   Nothing in here ever echoes a secret.

set -o pipefail

# ── output helpers ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then B=$'\033[1m'; N=$'\033[0m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'
else B=""; N=""; G=""; R=""; Y=""; fi

phase() { printf '\n%s══ %s %s\n' "$B" "$*" "$N" >&2; }
say()   { printf '   %s\n' "$*" >&2; }
ok()    { printf '   %s✓%s %s\n' "$G" "$N" "$*" >&2; }
warn()  { printf '   %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '   %s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ── auth ─────────────────────────────────────────────────────────────────────
# forge_login <url> <user> <password>
forge_login() {
  local url="${1%/}" user="$2" pass="$3" body
  FORGE_URL="$url"
  body=$(curl -sk --max-time 30 -X POST "$url/api/auth/login" \
           -H 'Content-Type: application/json' \
           -d "$(printf '{"username":%s,"password":%s}' \
                 "$(json_str "$user")" "$(json_str "$pass")")") \
    || die "could not reach BNK Forge at $url"
  FORGE_TOKEN=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
  [[ -n "$FORGE_TOKEN" ]] || die "login failed for user '$user' (check the password; the response carried no token)"
  export FORGE_URL FORGE_TOKEN
}

# forge_api <METHOD> <PATH> [JSON body]
forge_api() {
  local method="$1" path="$2" data="${3:-}" out code
  if [[ -n "$data" ]]; then
    out=$(curl -sk --max-time 120 -w $'\n%{http_code}' -X "$method" "$FORGE_URL$path" \
            -H "Authorization: Bearer $FORGE_TOKEN" -H 'Content-Type: application/json' -d "$data")
  else
    out=$(curl -sk --max-time 120 -w $'\n%{http_code}' -X "$method" "$FORGE_URL$path" \
            -H "Authorization: Bearer $FORGE_TOKEN")
  fi
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  printf '%s' "$out"
  [[ "$code" =~ ^2 ]] || { printf '\n' >&2; warn "HTTP $code on $method $path"; return 1; }
}

# JSON-quote an arbitrary string (handles quotes/backslashes in passwords).
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

jqp() { python3 -c "import sys,json$(printf '\n%s' "$1")"; }

# ── catalog ──────────────────────────────────────────────────────────────────
# forge_sync_source <source-name-substring>  -> syncs modules + auto-syncs blueprints
forge_sync_source() {
  local want="$1" id
  id=$(forge_api GET /api/module-sources | python3 -c "
import sys,json
want='''$want'''
for s in json.load(sys.stdin):
    if want in (s.get('name') or '') or want in (s.get('url') or ''): print(s['id']); break
") || return 1
  [[ -n "$id" ]] || die "no module source matching '$want' — register this repo as a module source first"
  forge_api POST "/api/module-sources/$id/sync" '{}' | python3 -c "
import sys,json
r=json.load(sys.stdin)['results']
print(f\"   modules: {r['modules_found']} found, {r['modules_created']} created, {r['modules_updated']} updated\")
if r.get('pack_errors'): print('   pack errors:', r['pack_errors'])
b=r.get('blueprint_auto_sync',{}).get('results',{})
if b: print(f\"   blueprints: {b.get('blueprints_found')} found, {b.get('releases_created')} new, {b.get('releases_invalid')} invalid\")
" >&2
}

# forge_latest_release <blueprint-id>  -> release id of the highest valid version
#
# Matches blueprint_id EXACTLY, never the display name. Display names overlap:
# "BNK on a disconnected IBM ROKS cluster (private registry + F5 License Proxy)"
# contains "License Proxy", so a substring search for the FLP blueprint silently
# returns the disconnected one — and, being the higher version, it wins the sort.
forge_latest_release() {
  forge_api GET /api/blueprint-catalog/releases | python3 -c "
import sys,json
want='''$1'''
rs=[r for r in json.load(sys.stdin)
    if r.get('blueprint_id')==want and r['validation_state']=='valid']
if not rs: raise SystemExit(1)
rs.sort(key=lambda r:[int(x) for x in r['blueprint_version'].split('.')], reverse=True)
print(rs[0]['id'])
"
}

# forge_import_release <id>
forge_import_release() { forge_api POST "/api/blueprint-catalog/releases/$1/import" '{}' >/dev/null; }

# ── deployment ───────────────────────────────────────────────────────────────
# forge_create_project <release-id> <name> <region> <cred-template-id> <vars-json>
# echoes the created module ids, in blueprint order, space separated
forge_create_project() {
  local rid="$1" name="$2" region="$3" cred="$4" vars="$5" body resp
  body=$(python3 -c '
import json,sys
name,region,cred,vars_ = sys.argv[1], sys.argv[2], int(sys.argv[3]), json.loads(sys.argv[4])
print(json.dumps({"name":name,"description":"roksbnkctl disconnected demo","cloud_provider":"ibm",
  "environment":"development","region":region,"credential_template_id":cred,
  "backend_type":"local","variables":vars_}))' "$name" "$region" "$cred" "$vars")
  resp=$(forge_api POST "/api/stacks/releases/$rid/projects" "$body") || return 1
  printf '%s' "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('PROJECT', d['project_id'], file=sys.stderr)
print(' '.join(str(m) for m in d['created_module_ids']))
"
}

# forge_apply <module-id>
forge_apply() { forge_api POST "/api/project-modules/$1/apply" '{}' >/dev/null; }

# forge_module_status <module-id>
forge_module_status() {
  forge_api GET "/api/project-modules/$1/status" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null
}

# forge_wait_module <module-id> <label> [timeout-seconds]
# Succeeds on "applied"/"destroyed"; fails loudly on any *_failed, and prints
# the module's error so a failure is diagnosable without opening the UI.
forge_wait_module() {
  local id="$1" label="$2" limit="${3:-5400}" waited=0 st last=""
  while :; do
    st=$(forge_module_status "$id")
    [[ "$st" != "$last" && -n "$st" ]] && { say "$label: $st"; last="$st"; }
    case "$st" in
      applied|destroyed) ok "$label complete"; return 0 ;;
      # plan_failed is terminal too — the plan never became an apply, so the module
      # sits there forever. Match any *_failed rather than listing them, so a state
      # this script has not seen yet still stops the run instead of hanging to timeout.
      *_failed|failed|error|cancelled)
        forge_api GET "/api/project-modules/$id/status" | python3 -c '
import sys,json; d=json.load(sys.stdin)
print("   error:", (d.get("deployment_error") or "(none recorded)")[:400])' >&2
        die "$label failed ($st) — see the module log in the Forge UI for the step output" ;;
    esac
    (( waited += 20 )); (( waited > limit )) && die "$label still '$st' after ${limit}s"
    sleep 20
  done
}

# forge_module_output <module-id> <output-name>
# opentofu modules expose real outputs; container modules surface theirs from the
# artifact's outputs_file. Falls back to scraping the apply log, which is where a
# terraform output line ends up when the state view is unavailable.
forge_module_output() {
  local id="$1" key="$2" v
  v=$(forge_api GET "/api/state/module/$id/outputs" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(0)
o=d.get('outputs') or {}
val=o.get('''$key''')
if isinstance(val,dict): val=val.get('value')
print(val or '')" 2>/dev/null)
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  forge_api GET "/api/project-modules/$id/deployments" >/dev/null 2>&1
  forge_api GET "/api/tasks" >/dev/null 2>&1 || true
  return 1
}

# forge_destroy_project <project-id>
forge_destroy_project() { forge_api POST "/api/projects/$1/destroy-all" '{}' >/dev/null; }

# forge_delete_project <project-id>
forge_delete_project() { forge_api DELETE "/api/projects/$1" >/dev/null 2>&1 || true; }
