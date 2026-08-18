# shellcheck shell=bash
# Shared "is this project actually destroyed?" logic for the teardown scripts.
#
# WHY THIS IS NOT deployed_count/failed_count
# ------------------------------------------
# Forge derives the project summary like this (project_service.py:993):
#
#   deployed_count = count(status in ["applied"])
#   failed_count   = count(status in ["failed","apply_failed","destroy_failed",
#                                     "init_failed","plan_failed"])
#
# A module in `destroying` is in NEITHER set, so a project whose teardown is
# still RUNNING reports 0/0 — byte-identical to one that has finished. Polling
# those counts cannot distinguish "done" from "in progress"; it never could.
#
# On 2026-08-17 that cost two clusters. teardown-v145.sh waited for 0/0, saw it
# while module 192's `cluster down` was still running, and deleted project 114.
# The delete cascaded away the destroy task's own DB row, and the in-flight task
# died three seconds later:
#
#   22:42:15  dispatched destroy task 467 (celery 8eb88a1d…) for module 192
#   22:45:5x  v1-new-connected (114): project deleted      ← us
#   22:45:55  PendingRollbackError: Instance '<Task …>' has been deleted
#
# f5e2e1 and f5e2e4 outlived their own teardown and had to be removed by hand,
# along with their VPCs, subnets and public gateways. Filed as bnk-forge#125.
#
# So: enumerate the modules and require each to be TERMINALLY destroyed.

# Statuses that mean "this module holds nothing, and nothing is in flight".
# Taken from ModuleStatus in bnk-forge backend/models/enums.py:25 rather than
# guessed — a real project reported `not_initialized`, which an invented list
# missed, and the script then refused to delete a project that had never
# deployed anything.
#
# Deliberately EXCLUDED, and why:
#   applying/destroying/planning/initializing — in flight; deleting the project
#     now cascades away the running task's DB row and orphans what it held
#   applied                                   — still holds resources
#   *_failed                                  — destroy did not complete
#   planned/initialized                       — nothing applied, but a plan or
#     init ran; treat as needing a look rather than silently dropping
FORGE_TERMINAL_CLEAR_RE='^(destroyed|not_initialized|pending|not_deployed)$'

# fd_get <path> — GET through whichever caller's plumbing exists. teardown-all.sh
# comes in via e2e-lib.sh and already has forge_api + FORGE_TOKEN; teardown-v145.sh
# is standalone with API/T. Deliberately NOT named forge_* : forge-api.sh already
# defines forge_module_status, and redefining it here would silently change
# behaviour for every other caller of that library.
fd_get() {
  if declare -F forge_api >/dev/null 2>&1; then
    forge_api GET "$1" 2>/dev/null
  else
    curl -sk --max-time 60 "${API:-$FORGE_URL}$1" \
      -H "Authorization: Bearer ${T:-${FORGE_TOKEN:-}}" 2>/dev/null
  fi
}

# fd_project_module_ids <project-id> — ids from the execution plan.
# Prints nothing (and returns 1) if the plan cannot be read; callers MUST treat
# that as "unknown", never as "no modules".
fd_project_module_ids() {
  local pid="$1" out
  out=$(fd_get "/api/projects/$pid/execution-plan" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ids = [m["id"] for l in (d.get("layers") or []) for m in (l.get("modules") or []) if m.get("id")]
print(" ".join(str(i) for i in ids))
' 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# fd_module_status <module-id> — empty string if it cannot be read.
fd_module_status() {
  fd_get "/api/project-modules/$1/status" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null
}

# forge_project_destroyed <project-id> — 0 when every module is terminally
# clear. Non-zero otherwise, INCLUDING when the state cannot be determined: an
# unreadable status is not evidence of an empty project.
forge_project_destroyed() {
  local pid="$1" ids st
  ids=$(fd_project_module_ids "$pid") || return 2
  for m in $ids; do
    st=$(fd_module_status "$m")
    # An empty status means the status could not be READ (5xx, timeout, 000).
    # Treating that as "clear" is how a teardown waves through a module that is
    # still holding a cluster.
    [[ -z "$st" ]] && return 2
    [[ "$st" =~ $FORGE_TERMINAL_CLEAR_RE ]] || return 1
  done
  return 0
}

# forge_project_module_report <project-id> — "id=status id=status …" for logging.
forge_project_module_report() {
  local pid="$1" ids out=""
  ids=$(fd_project_module_ids "$pid") || { printf 'modules unreadable'; return; }
  for m in $ids; do out+="$m=$(fd_module_status "$m") "; done
  printf '%s' "${out% }"
}
