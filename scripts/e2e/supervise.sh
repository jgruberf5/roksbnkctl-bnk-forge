#!/usr/bin/env bash
# Watchdog for a demo run. Polls every 30s and reconciles what the HARNESS is
# doing against what FORGE actually says.
#
# WHY THIS EXISTS
# Every stall in this project has had the same shape: the driving script died or
# wandered off, the Forge modules carried on (or stopped), and nothing noticed
# for hours. The scripts are a convenience; Forge is the authority. So this asks
# Forge, every 30 seconds, and shouts when the two disagree.
#
# It detects, and names, four distinct conditions — they need different actions
# and lumping them together is why they went unnoticed:
#
#   RUNNING   a module is applying and its task log is still growing
#   STALLED   a module is applying but nothing has changed for STALL_AFTER
#   ORPHANED  modules are mid-flight but no harness process is alive to drive
#             the next one — the exact state that cost hours on the v4 beta
#   FAILED    a module reached apply_failed / destroy_failed
#
#   ./supervise.sh [seconds-between-polls]
#
# Prints one line per poll per project. Exits 0 when every tracked project has
# all modules applied, 1 on a failure, 2 on an unrecoverable stall.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
INTERVAL="${1:-30}"
STALL_AFTER="${STALL_AFTER:-1200}"        # 20m of no observable change
API="$FORGE_URL"
mkdir -p "$HERE/logs"
HEARTBEAT="${HEARTBEAT:-$HERE/logs/supervisor-status.txt}"

TOKEN=""
auth() {
  TOKEN=$(curl -sk --max-time 30 -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token // empty')
  [[ -n "$TOKEN" ]]
}
# Every call re-auths on 401 rather than dying: these runs outlive a Forge token,
# and an expired one used to surface as an empty body and a jq null error.
api() {
  local out code
  out=$(curl -sk --max-time 45 -w $'\n%{http_code}' "$API$1" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" == "401" ]]; then auth || return 1
    out=$(curl -sk --max-time 45 -w $'\n%{http_code}' "$API$1" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
    out="${out%$'\n'*}"
  fi
  printf '%s' "$out"
}
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

auth || { say "FATAL: cannot authenticate to Forge at $API"; exit 2; }

declare -A LAST_SIG LAST_CHANGE
OVERALL=0

while :; do
  projects=$(api /api/projects | jq -r '(.projects // .)[] | "\(.id)|\(.name)"' 2>/dev/null)
  [[ -z "$projects" ]] && { say "no projects visible — nothing to supervise"; exit 0; }

  all_done=1
  : > "$HEARTBEAT.tmp"
  while IFS='|' read -r pid pname; do
    [[ -z "$pid" ]] && continue
    mods=$(api "/api/projects/$pid/execution-plan" | jq -r '[.layers[]?.modules[]?.id] | join(" ")' 2>/dev/null)
    [[ -z "$mods" ]] && continue
    sig=""; states=""; any_bad=0
    for m in $mods; do
      st=$(api "/api/project-modules/$m/status" | jq -r '.status // "?"' 2>/dev/null)
      # Task log size is the only evidence that an `applying` module is doing
      # anything. Module status alone sits on "applying" for an hour either way.
      tid=$(api "/api/tasks?module_id=$m&limit=5" | jq -r '(.tasks // .)[]?|select(.task_type=="apply")|.id' 2>/dev/null | sort -rn | head -1)
      sz=$(api "/api/tasks/$tid" | jq -r '.logs_full_size // 0' 2>/dev/null)
      sig+="$m:$st:$sz "; states+="$m=$st "
      [[ "$st" =~ _failed$ ]] && any_bad=1
      [[ "$st" == "applied" ]] || all_done=0
    done

    now=$(date +%s)
    if [[ "${LAST_SIG[$pid]:-}" != "$sig" ]]; then
      LAST_SIG[$pid]="$sig"; LAST_CHANGE[$pid]=$now
    fi
    idle=$(( now - ${LAST_CHANGE[$pid]:-$now} ))

    # Is anything actually driving this run? A harness that has exited while its
    # modules are still mid-flight is the ORPHANED case: Forge keeps going, but
    # nothing will apply the NEXT module when this one lands.
    driver="none"
    if pgrep -f "v[0-9]-(new|existing)-.*\.sh|make-bare-cluster\.sh|drive-modules\.sh|disconnected-roks-cluster-demo\.sh" 2>/dev/null \
         | grep -qvE "^($$|$PPID)$"; then driver="alive"; fi

    verdict="RUNNING"
    if [[ "$any_bad" == "1" ]]; then verdict="FAILED"
    elif echo "$states" | grep -q '=applying' && [[ "$driver" == "none" ]]; then verdict="ORPHANED"
    elif echo "$states" | grep -q '=applying' && (( idle > STALL_AFTER )); then verdict="STALLED"
    elif echo "$states" | grep -qv '=applied'; then verdict="RUNNING"
    fi
    say "$verdict  p$pid $pname  [$states] idle=${idle}s driver=$driver"
    printf '%s %s p%s %s [%s] idle=%ss driver=%s\n' \
      "$(date -u +%s)" "$verdict" "$pid" "$pname" "$states" "$idle" "$driver" >> "$HEARTBEAT.tmp"
    [[ "$verdict" == "FAILED"   ]] && OVERALL=1
    [[ "$verdict" == "STALLED"  ]] && OVERALL=2
  done <<< "$projects"

  mv -f "$HEARTBEAT.tmp" "$HEARTBEAT"
  (( all_done )) && { say "ALL PROJECTS APPLIED"; exit 0; }
  (( OVERALL )) && exit $OVERALL
  sleep "$INTERVAL"
done
