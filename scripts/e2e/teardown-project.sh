#!/usr/bin/env bash
# Destroy and delete one Forge project BY NAME, waiting for every module to reach
# a terminally cleared state first.
#
# make-bare-cluster.sh creates a project and has no `down` action, so the bare
# clusters that variants 3 and 4 adopt had no scripted teardown at all. This is it.
#
# Polls MODULE STATUSES, never deployed_count/failed_count -- a module in
# `destroying` is counted by neither, so the project summary reads 0/0 while the
# teardown is still running. Misreading that deleted a project out from under its
# own in-flight destroy and orphaned two clusters (bnk-forge#125).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
API="$FORGE_URL"
source "$HERE/forge-destroy-lib.sh"
NAME="${1:?usage: teardown-project.sh <project-name>}"
T=$(curl -sk --max-time 30 -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token//empty')
[[ -n "$T" ]] || { echo "cannot authenticate to $API" >&2; exit 2; }
say() { printf '   [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

PID=$(curl -sk --max-time 40 "$API/api/projects" -H "Authorization: Bearer $T" \
      | jq -r --arg n "$NAME" '(.projects//.)[]|select(.name==$n)|.id' | head -1)
[[ -z "$PID" ]] && { say "$NAME: already gone"; exit 0; }

say "$NAME (project $PID): destroy-all"
curl -sk -o /dev/null --max-time 60 -X POST "$API/api/projects/$PID/destroy-all" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{}'
rc=1
for _ in $(seq 1 240); do
  forge_project_destroyed "$PID"; rc=$?
  (( rc == 0 )) && { say "$NAME: every module terminally destroyed"; break; }
  sleep 20
done
if (( rc != 0 )); then
  say "!! $NAME: destroy did not finish clean — $(forge_project_module_report "$PID")"
  say "!! NOT deleting it: a delete now cascades away any in-flight destroy task"
  exit 1
fi
curl -sk -o /dev/null --max-time 60 -X DELETE "$API/api/projects/$PID" -H "Authorization: Bearer $T"
say "$NAME: project deleted"
