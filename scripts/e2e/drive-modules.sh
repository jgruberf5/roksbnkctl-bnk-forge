#!/usr/bin/env bash
# Drive a project's modules in dependency order, directly against the Forge API.
#
# The variant harnesses exit on the first module failure, which is right when the
# failure is real. It was not here: every module failed because the v4 beta's
# credential template carried provider "ibmcloud" where the credentials service
# matches "ibm", so nothing was injected. Once that was fixed the modules were
# fine, but the scripts that would have driven them had already gone.
#
#   ./drive-modules.sh <label> <module-id>...
#
# Applies each module in the order given, waiting for the previous to reach
# `applied` before starting the next. Stops on a real failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
LABEL="$1"; shift
API="$FORGE_URL"
T=$(curl -sk --max-time 30 -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token // empty')
[[ -n "$T" ]] || { echo "$LABEL: could not authenticate to Forge" >&2; exit 1; }
say() { printf '[%s] %s %s\n' "$(date -u +%H:%M:%S)" "$LABEL" "$*"; }

status() { curl -sk --max-time 30 "$API/api/project-modules/$1/status" -H "Authorization: Bearer $T" | jq -r '.status // ""'; }

for M in "$@"; do
  st=$(status "$M")
  if [[ "$st" == "applied" ]]; then say "module $M already applied"; continue; fi
  # A module left `applying` from an earlier dispatch is already doing the work;
  # re-applying would double-dispatch it.
  if [[ "$st" != "applying" ]]; then
    say "applying module $M (was $st)"
    curl -sk --max-time 60 -o /dev/null -X POST "$API/api/project-modules/$M/apply" \
      -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{}'
  else
    say "module $M already applying — waiting"
  fi
  last=""
  for _ in $(seq 1 480); do   # up to 4h; a ROKS cluster is ~50m, bnk up ~15m
    st=$(status "$M")
    [[ "$st" != "$last" && -n "$st" ]] && { say "module $M: $st"; last="$st"; }
    case "$st" in
      applied) break;;
      apply_failed|failed) say "module $M FAILED — stopping"; exit 1;;
    esac
    sleep 30
  done
  [[ "$(status "$M")" == "applied" ]] || { say "module $M did not reach applied"; exit 1; }
done
say "all modules applied"
