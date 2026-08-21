#!/usr/bin/env bash
# Shared harness for the four deployment variants.
#
# The point of these scripts is not "did the deploy return 0" — Forge already
# tells us that. It is whether the deployment is the KIND of deployment the
# blueprint claims: a disconnected variant that quietly pulled from F5's public
# registry has passed its deploy and failed its purpose. So each variant asserts
# on the cluster afterwards, and a failed assertion fails the run.
set -uo pipefail

E2E_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$E2E_HERE/../demos"
source "$DEMO_DIR/lib/forge-api.sh"

E2E_T0=$(date +%s)
E2E_FAILURES=0
declare -a E2E_RESULTS=()

hms() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
e2e_say()  { printf '   %s\n' "$*" >&2; }
e2e_head() { printf '\n\033[1m══ [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# assert <description> <actual> <expected>
e2e_assert() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    E2E_RESULTS+=("PASS|$what|$got")
    printf '   \033[32m✓\033[0m %-52s %s\n' "$what" "$got" >&2
  else
    E2E_RESULTS+=("FAIL|$what|got '$got' want '$want'")
    printf '   \033[31m✗\033[0m %-52s got %s, want %s\n' "$what" "$got" "$want" >&2
    E2E_FAILURES=$(( E2E_FAILURES + 1 ))
  fi
}

# assert_ge <description> <actual> <minimum>
e2e_assert_ge() {
  local what="$1" got="$2" min="$3"
  if [[ "${got:-0}" -ge "$min" ]]; then
    E2E_RESULTS+=("PASS|$what|$got >= $min")
    printf '   \033[32m✓\033[0m %-52s %s (>= %s)\n' "$what" "$got" "$min" >&2
  else
    E2E_RESULTS+=("FAIL|$what|$got < $min")
    printf '   \033[31m✗\033[0m %-52s %s, want >= %s\n' "$what" "$got" "$min" >&2
    E2E_FAILURES=$(( E2E_FAILURES + 1 ))
  fi
}

# ── cluster-side assertions ──────────────────────────────────────────────────
# All of these read the cluster directly. KUBECONFIG must already point at it.

e2e_license_state() {
  rk -n "${FLP_NAMESPACE:-f5-utils}" get licenses.k8s.f5net.com -o jsonpath='{.items[0].status.state}' 2>/dev/null
}
# The MODE column operators read is .spec.operationMode — there is no mode field
# under status at all, so the obvious-looking status.mode silently returns empty
# and the assertion fails against a perfectly good deployment.
e2e_license_mode() {
  rk -n "${FLP_NAMESPACE:-f5-utils}" get licenses.k8s.f5net.com -o jsonpath='{.items[0].spec.operationMode}' 2>/dev/null
}
e2e_f5_pods_running() {
  rk get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^f5-/ && $4 == "Running"' | wc -l
}
e2e_f5_pods_not_running() {
  rk get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^f5-/ && $4 != "Running" && $4 != "Completed"' | wc -l
}
# `bnk up` returns when the install has been APPLIED, not when every pod has
# finished starting — the verify block runs seconds later, so a pod still pulling
# or still in ContainerCreating reads as "stuck" and fails a run that is actually
# healthy. Use case 3 failed exactly this way: 2 pods at 23:09:07, all 38 Running
# by 23:10. Poll until the count settles at 0, then let the assertion read it;
# on a genuinely stuck pod this simply burns the timeout and still reports the
# real number, so a true failure is never masked — only deferred.
e2e_wait_pods_settled() {
  local timeout="${1:-300}" waited=0 n
  while (( waited < timeout )); do
    n=$(e2e_f5_pods_not_running)
    [[ "$n" == "0" ]] && { (( waited > 0 )) && e2e_say "pods settled after ${waited}s"; return 0; }
    sleep 10; waited=$(( waited + 10 ))
  done
    # Name them. A bare count is not actionable: UC2 reported "1 still not
    # Running" at 13:22 and the cluster was `deleting` minutes later, so which
    # pod and why were gone before anyone could look. The teardown that follows a
    # failed verify destroys the only evidence, exactly as deleting a project
    # cascades away its task logs.
    e2e_say "pods did NOT settle in ${timeout}s - ${n} still not Running:"
    rk get pods -A --no-headers 2>/dev/null \
      | awk '$1 ~ /^f5-/ && $4 != "Running" && $4 != "Completed" {printf "     %s/%s  %s  restarts=%s  age=%s\n",$1,$2,$4,$5,$6}' >&2
    # Why, not just what: Reason/Message carry ImagePullBackOff, Insufficient
    # memory, unbound PVC - the difference between a flake and a real defect.
    while read -r _ns _pod; do
      [[ -z "$_pod" ]] && continue
      e2e_say "  --- $_ns/$_pod ---"
      rk get pod "$_pod" -n "$_ns" -o jsonpath='{range .status.conditions[*]}{"     cond "}{.type}{"="}{.status}{" "}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null >&2
      rk get pod "$_pod" -n "$_ns" -o jsonpath='{range .status.containerStatuses[*]}{"     ctr  "}{.name}{" ready="}{.ready}{" "}{.state.waiting.reason}{" "}{.state.waiting.message}{"\n"}{end}' 2>/dev/null >&2
    done < <(rk get pods -A --no-headers 2>/dev/null \
             | awk '$1 ~ /^f5-/ && $4 != "Running" && $4 != "Completed" {print $1, $2}')
  return 1
}
# Containers in the BNK namespaces NOT served by the private mirror. The
# disconnected variants must report 0; the connected ones must report all of
# them, which is what proves the two paths are actually different.
e2e_containers_off_mirror() {
  local mirror="${1:-}"
  rk get pods -n f5-bnk -n f5-utils -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c -v "^${mirror}/" 
}
e2e_containers_total() {
  for ns in f5-bnk f5-utils; do
    rk -n $ns get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | grep -c .
}
e2e_containers_from_mirror() {
  local mirror="$1"
  for ns in f5-bnk f5-utils; do
    rk -n $ns get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | grep -c "^${mirror}/"
}
# Containers served by a given registry host. Used positively: a connected
# install must show every BNK container coming from repo.f5.com, not merely
# "not from the mirror" — an image from anywhere else would pass that weaker
# test.
e2e_containers_from_registry() {
  local host="$1"
  for ns in f5-bnk f5-utils; do
    rk -n $ns get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | grep -c "^${host}/"
}

# Worker Internet egress. A public gateway on the cluster subnets is what
# separates variant 1/3 from variant 2/4, so assert on it rather than trusting
# the input we passed in.
e2e_worker_egress() {
  local node
  node=$(rk get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return
  rk debug node/"$node" --image=busybox -q -- timeout 8 wget -q -O- https://registry.redhat.io/v2/ >/dev/null 2>&1 \
    && echo yes || echo no
}

# ── Forge-side helpers ───────────────────────────────────────────────────────
e2e_module_states() {   # every module in a project, "name=status" per line
  local pid="$1" m
  for m in $(cat "$STATE/$pid.modules" 2>/dev/null); do
    printf '%s=%s\n' "$m" "$(forge_module_status "$m")"
  done
}

e2e_summary() {
  local total=$(( $(date +%s) - E2E_T0 ))
  e2e_head "Result"
  local r
  for r in "${E2E_RESULTS[@]}"; do
    IFS='|' read -r st what detail <<< "$r"
    printf '   %-5s %-52s %s\n' "$st" "$what" "$detail" >&2
  done
  e2e_say ""
  e2e_say "wall clock: $(hms "$total")"
  if (( E2E_FAILURES )); then
    printf '   \033[31m%d assertion(s) failed\033[0m\n' "$E2E_FAILURES" >&2
    return 1
  fi
  printf '   \033[32mall %d assertions passed\033[0m\n' "${#E2E_RESULTS[@]}" >&2
  return 0
}

# forge_project_id_by_name <name> -> id, or empty. Never creates: a teardown
# asking "is this still here?" must not bring it into being.
forge_project_id_by_name() {
  forge_api GET /api/projects 2>/dev/null | python3 -c '
import sys, json
want = sys.argv[1]
d = json.load(sys.stdin)
for p in (d if isinstance(d, list) else d.get("projects", [])):
    if p.get("name") == want:
        print(p["id"]); break' "$1" 2>/dev/null
}

# A freshly synced release is "discovered", not deployable: project creation
# rejects it with BLUEPRINT_RELEASE_NOT_DEPLOYABLE until it is imported or
# approved. Idempotent — importing an already-imported release is a no-op, so
# this is safe to call on every run.
forge_import_release() {
  local rid="$1" state
  state=$(forge_api GET "/api/blueprint-catalog/releases/$rid" 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin).get("release_state",""))' 2>/dev/null)
  case "$state" in
    imported|approved) return 0 ;;
  esac
  forge_api POST "/api/blueprint-catalog/releases/$rid/import" '{}' >/dev/null \
    || { warn "could not import release $rid"; return 1; }
  e2e_say "release $rid imported (was '${state:-discovered}')"
}

# Forge scans a cluster when it is registered and never again on its own, so a
# BNK install that takes 15 minutes shows an empty cluster for 15 minutes. Drive
# a rescan on an interval instead, and the Kubernetes console fills in as the
# install proceeds — which is the whole point of registering before installing.
#
# The redirect is load-bearing: this is called as PID=$(e2e_watch_cluster ...),
# and command substitution waits for every writer to the pipe to let go. A
# backgrounded child inherits it, so without >/dev/null the caller hangs forever
# on a loop that never exits.
e2e_watch_cluster() {
  local name="$1" interval="${2:-60}" owner=$$
  (
    local id="" n=0
    # BOUNDED, and orphan-aware. This subshell inherits the parent's argv, so in
    # `ps` it is indistinguishable from the main script -- which is how one of
    # these survived its parent by 7h15m, PUTting a rescan every 60s at a project
    # that had been deleted hours earlier, while `pgrep` cheerfully reported the
    # "run" as still alive. e2e_stop_watch kills it by PID on the happy path;
    # these two guards cover every other path.
    #   kill -0 : the owning script is gone, so there is nothing left to watch
    #   n < 240 : a 4h ceiling, well past the longest real install (UC2, 58m)
    while (( n++ < 240 )); do
      kill -0 "$owner" 2>/dev/null || exit 0
      [[ -z "$id" ]] && id=$(forge_cluster_id_by_name "$name")
      [[ -n "$id" ]] && forge_api PUT "/api/k8s/clusters/$id" '{}' >/dev/null 2>&1
      sleep "$interval"
    done
  ) >/dev/null 2>&1 &
  echo $!
}

e2e_stop_watch() {
  [[ -n "${1:-}" ]] && kill "$1" 2>/dev/null
  # One last scan so the console reflects the finished state, not the last poll.
  local id
  id=$(forge_cluster_id_by_name "${2:-}")
  [[ -n "$id" ]] && forge_api PUT "/api/k8s/clusters/$id" '{}' >/dev/null 2>&1 \
    && e2e_say "final cluster rescan queued"
  return 0
}

# ── deploy / teardown ────────────────────────────────────────────────────────
# One project per variant. Mirrors the demo script's deploy(): enable every
# module (optional ones arrive disabled), put the blueprint's depends_on edges
# back (enabling a module recomputes them from library metadata and wipes them),
# then apply only the first module and let Forge's graph trigger the rest.
e2e_deploy() {
  local bp_dir="$1" rel="$2" project="$3" vars="$4"
  local tmp="$STATE/.e2e.create" m
  forge_import_release "$rel" || die "release $rel is not deployable"
  E2E_MODS=$(forge_create_project "$rel" "$project" "$REGION" \
               "$FORGE_CREDENTIAL_TEMPLATE_ID" "$vars" 2> >(tee "$tmp" >&2)) \
    || die "could not create project '$project'"
  E2E_PID=$(awk '/^PROJECT/{print $2}' "$tmp")
  [[ -n "$E2E_PID" ]] || die "project created but no id returned"

  # Forge injects IBMCLOUD_API_KEY into every container step from the PROJECT's
  # credential template ({**credentials_env, **step_env}). No template means no
  # key, and roksbnkctl fails deep inside `bnk up` with "no IBM Cloud API key for
  # workspace bnk" — 15 minutes and three retries after the project was created.
  # Project 66 came out with a null template despite the request carrying one, so
  # verify rather than trust, and repair rather than fail: the cost of being wrong
  # here is an hour of cloud time.
  local ct
  ct=$(forge_api GET "/api/projects/$E2E_PID" 2>/dev/null \
       | python3 -c 'import sys,json;print(json.load(sys.stdin).get("credential_template_id") or "")' 2>/dev/null)
  if [[ -z "$ct" ]]; then
    warn "project $E2E_PID has no credential template — repairing to $FORGE_CREDENTIAL_TEMPLATE_ID"
    forge_api PUT "/api/projects/$E2E_PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null
    ct=$(forge_api GET "/api/projects/$E2E_PID" 2>/dev/null \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("credential_template_id") or "")' 2>/dev/null)
    [[ -n "$ct" ]] || die "project $E2E_PID still has no credential template — every step would run without IBMCLOUD_API_KEY"
  fi
  e2e_say "credential template $ct attached — IBMCLOUD_API_KEY will be injected"
  # Key this by PROJECT NAME, not one shared "e2e.project". All four variants
  # share $STATE, so a single unqualified file is owned by whichever variant
  # deployed last -- and e2e_teardown reads that file BEFORE falling back to the
  # name it was handed. c2-uc4-down was asked to tear down f5e2e-v4-existing-disco
  # and destroyed project 24, f5e2e-v2-new-disco, because UC2 had written the
  # shared file last. That project needed destroying anyway; with two live
  # projects it would have destroyed the wrong one.
  echo "$E2E_PID" > "$STATE/$project.project"; echo "$E2E_MODS" > "$STATE/$E2E_PID.modules"
  e2e_say "project $E2E_PID, modules: $E2E_MODS"
  for m in $E2E_MODS; do forge_enable_module "$m"; done
  forge_restore_dependencies "$E2E_HERE/../../blueprints/$bp_dir/forge-blueprint.json" $E2E_MODS
  # Re-assert the credential template immediately before dispatch. Forge's
  # update_project does `if hasattr(project_data, "credential_template_id")`,
  # and hasattr is always true for a declared Pydantic field — so ANY project
  # update that omits it silently nulls it. Checking once at creation is not
  # enough: projects 66 and 68 both read back 17 at creation and None by the time
  # a module ran, and every "no IBM Cloud API key for workspace bnk" failure
  # today traces to exactly that.
  forge_api PUT "/api/projects/$E2E_PID" "{\"credential_template_id\": $FORGE_CREDENTIAL_TEMPLATE_ID}" >/dev/null 2>&1
  ct=$(forge_api GET "/api/projects/$E2E_PID" 2>/dev/null \
       | python3 -c 'import sys,json;print(json.load(sys.stdin).get("credential_template_id") or "")' 2>/dev/null)
  [[ -n "$ct" ]] || die "project $E2E_PID lost its credential template again — steps would run without IBMCLOUD_API_KEY"
  e2e_say "credential template $ct re-asserted before dispatch"
  forge_apply "$(echo "$E2E_MODS" | awk '{print $1}')"
  # Registration is the first module, so the cluster appears early and the rest
  # of the install is watchable on Forge's Kubernetes page while it happens.
  local watch_pid=""
  if [[ -n "${E2E_CLUSTER_UNDER_TEST:-}" ]]; then
    watch_pid=$(e2e_watch_cluster "$E2E_CLUSTER_UNDER_TEST" 60)
    e2e_say "rescanning $E2E_CLUSTER_UNDER_TEST every 60s — watch it fill in on the Kubernetes page"
  fi
  for m in $E2E_MODS; do forge_wait_module "$m" "module $m" 7200; done
  e2e_stop_watch "$watch_pid" "${E2E_CLUSTER_UNDER_TEST:-}"
}

# Destroy, then delete — and only delete once every module actually reports
# "destroyed". A module that has not STARTED destroying still reads "applied";
# deleting then is how a teardown walks away from live IBM resources with no
# module left to describe them.
e2e_teardown() {
  local project="$1" pid m ok=1
  pid=$(cat "$STATE/$project.project" 2>/dev/null)
  if [[ -z "$pid" ]]; then
    pid=$(forge_project_id_by_name "$project" 2>/dev/null)
    [[ -z "$pid" ]] && { e2e_say "no project '$project' to tear down"; return 0; }
  fi
  e2e_head "Teardown of project $pid"
  forge_destroy_project "$pid" || warn "destroy-all returned non-zero"
  for m in $(cat "$STATE/$pid.modules" 2>/dev/null); do
    forge_wait_module "$m" "module $m" 7200 destroyed || ok=0
  done
  if (( ok )); then
    forge_delete_project "$pid"
    rm -f "$STATE/$project.project" "$STATE/$pid.modules"
    e2e_say "project $pid destroyed and deleted"
  else
    warn "project $pid has modules that did not destroy — leaving it in place"
    return 1
  fi
}

# Bind a roksbnkctl workspace to the cluster under test. Everything cluster-facing
# then goes through roksbnkctl, which is the tool this repo exists to exercise —
# and which loads the workspace API key, region and KUBECONFIG itself. Driving
# `ibmcloud` and `kubectl` directly went around the tool under test and produced
# two real defects today: an expired CLI session that silently left kubectl on the
# previous cluster, and a region that had to be pinned by hand.
E2E_WS="${E2E_WS:-e2e}"

# e2e_ws_init <cluster>
#
# Build the read-only workspace the assertions run through. Split out of
# e2e_kubeconfig because the ADOPT assertion needs it too: v3 and v4 snapshot the
# cluster id BEFORE deploying, and that query goes through `roksbnkctl -w $E2E_WS`
# — which on a workspace nobody has initialised yet returns nothing at all.
#
# The baseline then came back empty and the comparison read:
#
#     ✗ adopted the pre-existing cluster    got 'd9rlligw04tdut2kppfg', want ''
#
# which looks like the blueprint created a cluster it promised not to, and is
# really the harness never having asked. It passed only when the workspace
# happened to survive from an earlier run, so a first run always failed it.
#
# init --non-interactive builds the workspace from ROKSBNKCTL_* env ALONE, so the
# demo .env names have to be mapped across explicitly. cluster.create=false: this
# workspace only ever adopts the cluster under test to read it.
e2e_ws_init() {
  local cluster="$1"
  ROKSBNKCTL_REGION="$REGION" \
  ROKSBNKCTL_RESOURCE_GROUP="$RESOURCE_GROUP" \
  ROKSBNKCTL_PREFIX="$cluster" \
  ROKSBNKCTL_CLUSTER_NAME="$cluster" \
  ROKSBNKCTL_CLUSTER_CREATE=false \
  IBMCLOUD_API_KEY="$IBMCLOUD_API_KEY" \
    roksbnkctl -w "$E2E_WS" init --non-interactive >/dev/null 2>&1 \
      || { warn "roksbnkctl init failed for workspace $E2E_WS"; return 1; }
}

# e2e_cluster_id <cluster> — id of an EXISTING cluster, or empty if there is none.
# Initialises the workspace first so a fresh run gets a real answer rather than "".
e2e_cluster_id() {
  local cluster="$1"
  e2e_ws_init "$cluster" || return 1
  roksbnkctl -w "$E2E_WS" ibmcloud ks cluster get --cluster "$cluster" --output json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null
}

e2e_kubeconfig() {
  local cluster="$1"
  e2e_ws_init "$cluster" || return 1
  roksbnkctl -w "$E2E_WS" kubeconfig --download --cluster "$cluster" >/dev/null 2>&1 \
    || { warn "roksbnkctl could not fetch a kubeconfig for $cluster"; return 1; }
  # `roksbnkctl kubectl` resolves credentials via the SHARED forge kubeconfig
  # (~/.roksbnkctl/forge/kubeconfig.yaml), not a per-workspace file — readClusterKubeconfig
  # tries that path before $KUBECONFIG. Without this refresh the passthrough keeps
  # talking to whichever cluster was there last; it was still pointed at a us-south
  # cluster while we were asserting against us-east.
  roksbnkctl -w "$E2E_WS" kubeconfig --refresh >/dev/null 2>&1 \
    || { warn "roksbnkctl could not refresh the forge kubeconfig"; return 1; }
  # Prove we are pointed at the cluster under test before asserting anything.
  local got
  got=$(rk get nodes -o jsonpath='{.items[0].metadata.labels.ibm-cloud\.kubernetes\.io/cluster-name}' 2>/dev/null)
  [[ -z "$got" || "$got" == "$cluster" ]] \
    || { warn "workspace is on '$got', expected '$cluster' — refusing to assert against the wrong cluster"; return 1; }
}

# rk: kubectl through roksbnkctl, with the workspace's KUBECONFIG loaded.
rk() { roksbnkctl -w "$E2E_WS" kubectl "$@"; }
