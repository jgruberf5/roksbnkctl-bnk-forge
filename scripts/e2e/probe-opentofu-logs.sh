#!/usr/bin/env bash
# Does an opentofu module's task log accumulate DURING the apply, or only appear
# when it finishes?
#
#   ./probe-opentofu-logs.sh <module-id> [poll-seconds]
#
# WHY
# The Harbor module shows no output until it completes. Harbor is the only
# `opentofu` module in this catalog -- everything else is `container` -- so the
# two issues filed about container step output (bnk-forge #119, #154, both
# closed) do not necessarily cover it.
#
# One asymmetry is already confirmed and is probably half the story:
#
#   GET /api/tasks?module_id=19   ->  logs_full_size = null   (list omits logs)
#   GET /api/tasks/45             ->  logs_full_size = 33601  (detail has them)
#
# So anything enumerating a module's tasks sees every one as empty. That alone
# would produce "no output until finished" if the reader only ever polls the list
# and finally fetches the detail at the end.
#
# What this probe answers is the other half: on the DETAIL endpoint, does
# logs_full_size climb while status is still running, or stay flat and jump at
# completion? Flat-then-jump is a real buffering defect in the opentofu engine and
# worth filing. Climbing means the engine is fine and the defect is only the
# list/detail asymmetry above -- a different, cheaper fix.
#
# Samples every POLL seconds and prints a table. Exits when the task completes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
MOD="${1:?usage: probe-opentofu-logs.sh <module-id> [poll-seconds]}"
POLL="${2:-15}"
API="$FORGE_URL"
tok() { curl -sk --max-time 30 -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token//empty'; }
T=$(tok); [[ -n "$T" ]] || { echo "cannot authenticate" >&2; exit 2; }

# Wait for an apply task to appear for this module.
TID=""
for _ in $(seq 1 120); do
  TID=$(curl -sk --max-time 30 "$API/api/tasks?module_id=$MOD&limit=10" -H "Authorization: Bearer $T" \
        | jq -r '(.tasks//.)[]?|select(.task_type=="apply")|.id' 2>/dev/null | sort -rn | head -1)
  [[ -n "$TID" ]] && break
  command sleep 5
done
[[ -n "$TID" ]] || { echo "no apply task appeared for module $MOD" >&2; exit 1; }
echo "probing module $MOD, apply task $TID, every ${POLL}s"
printf '  %-10s %-12s %-14s %-14s %s\n' ELAPSED STATUS LIST_SIZE DETAIL_SIZE DELTA
start=$(date +%s); last=0
while :; do
  body=$(curl -sk --max-time 40 "$API/api/tasks/$TID" -H "Authorization: Bearer $T" 2>/dev/null)
  [[ -z "$body" ]] && { T=$(tok); command sleep "$POLL"; continue; }
  st=$(jq -r '.status // "?"' <<<"$body")
  det=$(jq -r '.logs_full_size // 0' <<<"$body")
  lst=$(curl -sk --max-time 40 "$API/api/tasks?module_id=$MOD&limit=10" -H "Authorization: Bearer $T" \
        | jq -r --arg t "$TID" '(.tasks//.)[]?|select((.id|tostring)==$t)|.logs_full_size // "null"' 2>/dev/null)
  printf '  %-10s %-12s %-14s %-14s %s\n' "$(( $(date +%s) - start ))s" "$st" "${lst:-absent}" "$det" "+$(( det - last ))"
  last=$det
  case "$st" in completed|failed|error|cancelled)
    echo "  final: status=$st detail_logs_full_size=$det"
    echo "  VERDICT: $( (( det > 0 )) && echo 'logs present at end' || echo 'no logs even at end' )"
    exit 0 ;;
  esac
  command sleep "$POLL"
done
