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

# ── timing ───────────────────────────────────────────────────────────────────
# Every phase is stamped so a completed run can report what it actually took.
# The blueprint's estimated_time and each module's estimated_time_minutes drive
# what the UI promises before a deploy, and those started as guesses — the Harbor
# project advertised 40 minutes and finished in 17. Grounding them needs numbers
# from a real end-to-end run, so the run collects its own.
RUN_T0=$(date +%s)
PHASE_MARKS=""            # "epoch<TAB>name" per line, in order

_stamp() { date -u +%H:%M:%S; }

phase() {
  local now; now=$(date +%s)
  PHASE_MARKS+="${now}	$*"$'\n'
  printf '\n%s══ [%s] %s %s\n' "$B" "$(_stamp)" "$*" "$N" >&2
}
say()   { printf '   %s\n' "$*" >&2; }
ok()    { printf '   %s✓%s [%s] %s\n' "$G" "$N" "$(_stamp)" "$*" >&2; }
warn()  { printf '   %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '   %s✗%s %s\n' "$R" "$N" "$*" >&2; timing_summary; exit 1; }

# hms <seconds>
hms() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# timing_summary — wall-clock per phase, then the authoritative per-module
# durations Forge recorded. The module numbers are what estimated_time_minutes
# should be set from; the phase numbers include this script's own polling and
# the out-of-band waits (Harbor's cloud-init, the CA fetch), so they are the
# honest "how long did it take me" figure and always exceed the module sums.
timing_summary() {
  [[ -z "$PHASE_MARKS" ]] && return 0
  local now; now=$(date +%s)
  printf '\n%s══ Timing %s\n' "$B" "$N" >&2
  printf '   %-46s %s\n' "phase" "wall clock" >&2
  local prev_t="" prev_n=""
  while IFS=$'\t' read -r t n; do
    [[ -z "$t" ]] && continue
    [[ -n "$prev_t" ]] && printf '   %-46s %s\n' "$prev_n" "$(hms $((t - prev_t)))" >&2
    prev_t="$t"; prev_n="$n"
  done <<< "$PHASE_MARKS"
  [[ -n "$prev_t" ]] && printf '   %-46s %s\n' "$prev_n" "$(hms $((now - prev_t)))" >&2
  printf '   %-46s %s\n' "TOTAL" "$(hms $((now - RUN_T0)))" >&2

  # Per-module, straight from Forge's own deployment records.
  local any=0
  for f in "$STATE"/*.project; do
    [[ -e "$f" ]] || continue
    local tag pid; tag=$(basename "$f" .project); pid=$(cat "$f")
    for mid in $(cat "$STATE/$tag.modules" 2>/dev/null); do
      local row
      # No 2>/dev/null on the parse: an earlier version escaped the quotes inside
      # an f-string, python raised a SyntaxError, and the redirect swallowed it —
      # so the table silently never printed.
      row=$(forge_api GET "/api/project-modules/$mid/deployments" 2>/dev/null | python3 -c '
import sys, json
try:
    ds = json.load(sys.stdin).get("deployments") or []
except Exception:
    raise SystemExit
for d in ds:
    if d.get("action") == "apply" and d.get("status") == "success" and d.get("duration_seconds"):
        print(int(d["duration_seconds"]))
        break
')
      if [[ -n "$row" ]]; then
        [[ $any == 0 ]] && { printf '\n   %-46s %s\n' "module (Forge-recorded apply)" "duration" >&2; any=1; }
        printf '   %-46s %s\n' "$tag/module $mid" "$(hms "$row")" >&2
      fi
    done
  done
  [[ $any == 1 ]] && printf '\n   %s\n' "Set estimated_time_minutes from the module rows, not the phase rows." >&2
}

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
  if [[ ! "$code" =~ ^2 ]]; then
    printf '\n' >&2
    warn "HTTP $code on $method $path"
    # Forge explains itself in the body — which validation failed, which variable
    # was the wrong type. Callers capture stdout and drop it on failure, so
    # without this the operator sees a bare status code and has to replay the
    # request by hand to learn anything.
    printf '%s' "$out" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); e=d.get('error') or d.get('detail') or d
    m=e.get('message') if isinstance(e,dict) else e
    if m: print('     '+str(m)[:700])
except Exception:
    b=sys.stdin.read().strip()
    if b: print('     '+b[:300])
" >&2 || true
    return 1
  fi
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
  if ! resp=$(forge_api POST "/api/stacks/releases/$rid/projects" "$body"); then
    # Forge reports a required variable sent as "" as "missing", which reads like
    # the script forgot to send it at all. Name the ones that went out empty so
    # the next question is "why is this shell variable unset" and not "which of
    # these two dozen values did we drop".
    printf '%s' "$body" | python3 -c "
import sys,json
v=(json.load(sys.stdin).get('variables') or {})
empty=sorted(k for k,x in v.items() if x=='' or x is None)
print('     sent %d variables; empty: %s' % (len(v), ', '.join(empty) or 'none'))
" >&2 || true
    return 1
  fi
  printf '%s' "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('PROJECT', d['project_id'], file=sys.stderr)
print(' '.join(str(m) for m in d['created_module_ids']))
"
}

# forge_apply <module-id>
forge_apply() { forge_api POST "/api/project-modules/$1/apply" '{}' >/dev/null; }

# forge_enable_module <module-id>
#
# A blueprint module marked `optional: true` is created DISABLED — it appears in
# the project but not in the diagram, and is skipped. That is the right default
# for a human choosing in the UI, and wrong for an unattended run that already
# supplied the inputs the module needs, so the demo turns them on explicitly.
#
# WARNING: enabling a disabled module DESTROYS the project's blueprint-derived
# dependency edges. update_module calls calculate_deployment_order() for the whole
# project, which re-derives dependencies from library-level module metadata unless
# use_existing_dependencies=True — and a blueprint's depends_on edges live in the
# manifest, not in the library modules, so they are dropped. The module is then left
# with no dependencies: the diagram loses its arrows and the sequencer is free to run
# a dependent module against something that is not ready. Callers must put the edges
# back — forge_restore_dependencies does that.
forge_enable_module() {
  forge_api PUT "/api/project-modules/$1" '{"enabled":true}' >/dev/null
}

# forge_restore_dependencies <blueprint-file> <module-id...>
#
# Re-applies the blueprint's depends_on graph after enabling. created_module_ids
# comes back in blueprint module order, so position maps a blueprint module id to
# the project module id it became.
#
# The graph is read from the blueprint FILE in this repo, not from the API. An
# earlier version asked /api/blueprint-catalog/releases/<id> for it; that endpoint
# returns catalog metadata only — no modules, no manifest — so the helper silently
# restored nothing and every deployment came out with a flat graph. This repo is
# the module source, so the file is the same content the release was built from.
#
# Verifies afterwards and DIES on a mismatch. Losing these edges is invisible in
# the API response and only shows up as a module racing the thing it depends on,
# which is exactly the failure that is hardest to attribute later.
forge_restore_dependencies() {
  local bp="$1"; shift
  [[ -f "$bp" ]] || die "blueprint file not found for dependency restore: $bp"
  local plan
  plan=$(python3 -c 'import sys,json
bp, ids = sys.argv[1], sys.argv[2:]
mods = json.load(open(bp))["modules"]
pos = {m["id"]: i for i, m in enumerate(mods)}
for i, m in enumerate(mods):
    if i >= len(ids):
        continue
    deps = [ids[pos[x]] for x in (m.get("depends_on") or []) if pos.get(x, len(ids)) < len(ids)]
    if deps:
        print(ids[i], ",".join(deps))' "$bp" "$@") \
    || die "could not read the dependency graph from $bp"

  [[ -z "$plan" ]] && return 0
  local mid deps got
  while read -r mid deps; do
    [[ -z "$mid" ]] && continue
    forge_api PUT "/api/project-modules/$mid/dependencies" "{\"dependencies\":[$deps]}" >/dev/null \
      || die "could not set dependencies on module $mid"
    # Read it back. A 200 does not prove the edge landed.
    got=$(forge_api GET "/api/project-modules/$mid/dependencies" \
          | python3 -c 'import sys,json
d=json.load(sys.stdin)
ds=d if isinstance(d,list) else (d.get("dependencies") or [])
print(",".join(str(x.get("id",x) if isinstance(x,dict) else x) for x in ds))' 2>/dev/null)
    [[ "$got" == "$deps" ]] \
      || die "dependency restore did not take on module $mid: wanted [$deps], got [${got:-none}]"
    say "dependency restored + verified: module $mid depends on [$deps]"
  done <<< "$plan"
}

# forge_cluster_id_by_name <name> -> id, or empty
forge_cluster_id_by_name() {
  forge_api GET /api/k8s/clusters 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
d = json.load(sys.stdin)
cs = d if isinstance(d, list) else (d.get("clusters") or [])
for c in cs:
    if c.get("name") == want:
        print(c.get("id"))
        break' "$1" 2>/dev/null
}

# forge_watch_cluster <cluster-name> <interval-seconds>
#
# Registering the cluster first is what puts it on Forge's Kubernetes page while
# BNK installs into it. On its own that shows an EMPTY cluster: a scan is
# enqueued once, at registration, and nothing rescans afterwards. The project
# columns that describe periodic sync — k8s_sync_enabled and
# k8s_sync_interval_seconds — exist on the model and in the API schema but no
# task reads them, so the sync they describe never runs.
#
# So the demo drives it. A no-op PUT to the cluster enqueues a fresh scan
# (routes/k8s/clusters.py update_cluster), which is how namespaces and pods
# appear as BNK creates them. Deliberately NOT `bnkforge register` again: that
# DELETEs the cluster and re-POSTs it, so the thing you are watching would
# vanish and come back with a new id.
#
# Echoes the watcher pid; the caller kills it when the phase ends.
forge_watch_cluster() {
  local name="$1" interval="${2:-60}"
  # The child's stdout MUST be closed off, not just its output discarded: this is
  # called as CLUSTER_WATCH_PID=$(forge_watch_cluster ...), and command
  # substitution waits for every writer to the pipe to let go. A backgrounded
  # child inherits that pipe, so without the redirect $(...) blocks forever on a
  # loop that never exits — the caller hangs before it has done anything.
  (
    local id=""
    while :; do
      [[ -z "$id" ]] && id=$(forge_cluster_id_by_name "$name")
      [[ -n "$id" ]] && forge_api PUT "/api/k8s/clusters/$id" '{}' >/dev/null 2>&1
      sleep "$interval"
    done
  ) >/dev/null 2>&1 &
  echo $!
}

# forge_module_status <module-id>
forge_module_status() {
  forge_api GET "/api/project-modules/$1/status" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null
}

# forge_wait_module <module-id> <label> [timeout-seconds] [want: applied|destroyed]
#
# `want` matters. Accepting either terminal state is right for an apply but wrong
# for a destroy: a module that has not STARTED destroying is still "applied", so a
# teardown reads it as already finished, returns immediately, and the caller deletes
# the project out from under modules that are still holding real resources. Forge
# tears down in reverse dependency order, so the modules a teardown polls first are
# exactly the ones still sitting at "applied". Default stays "applied" for apply
# callers; the teardown passes "destroyed".
forge_wait_module() {
  local id="$1" label="$2" limit="${3:-5400}" want="${4:-applied}" waited=0 st last=""
  while :; do
    st=$(forge_module_status "$id")
    [[ "$st" != "$last" && -n "$st" ]] && { say "$label: $st"; last="$st"; }
    # A module that never deployed has nothing to tear down.
    if [[ "$want" == "destroyed" && ( "$st" == "not_initialized" || -z "$st" ) ]]; then
      ok "$label — nothing deployed"; return 0
    fi
    case "$st" in
      "$want") ok "$label complete"; return 0 ;;
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
