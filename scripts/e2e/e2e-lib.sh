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
DEMO_DIR="$E2E_HERE/../demo"
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
  kubectl -n "${FLP_NAMESPACE:-f5-utils}" get licenses.k8s.f5net.com -o jsonpath='{.items[0].status.state}' 2>/dev/null
}
e2e_license_mode() {
  kubectl -n "${FLP_NAMESPACE:-f5-utils}" get licenses.k8s.f5net.com -o jsonpath='{.items[0].status.mode}' 2>/dev/null
}
e2e_f5_pods_running() {
  kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^f5-/ && $4 == "Running"' | wc -l
}
e2e_f5_pods_not_running() {
  kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^f5-/ && $4 != "Running" && $4 != "Completed"' | wc -l
}
# Containers in the BNK namespaces NOT served by the private mirror. The
# disconnected variants must report 0; the connected ones must report all of
# them, which is what proves the two paths are actually different.
e2e_containers_off_mirror() {
  local mirror="${1:-}"
  kubectl get pods -n f5-bnk -n f5-utils -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c -v "^${mirror}/" 
}
e2e_containers_total() {
  for ns in f5-bnk f5-utils; do
    kubectl -n $ns get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | grep -c .
}
e2e_containers_from_mirror() {
  local mirror="$1"
  for ns in f5-bnk f5-utils; do
    kubectl -n $ns get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  done | grep -c "^${mirror}/"
}
# Worker Internet egress. A public gateway on the cluster subnets is what
# separates variant 1/3 from variant 2/4, so assert on it rather than trusting
# the input we passed in.
e2e_worker_egress() {
  local node
  node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return
  kubectl debug node/"$node" --image=busybox -q -- timeout 8 wget -q -O- https://registry.redhat.io/v2/ >/dev/null 2>&1 \
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
  echo "$E2E_PID" > "$STATE/e2e.project"; echo "$E2E_MODS" > "$STATE/$E2E_PID.modules"
  e2e_say "project $E2E_PID, modules: $E2E_MODS"
  for m in $E2E_MODS; do forge_enable_module "$m"; done
  forge_restore_dependencies "$E2E_HERE/../../blueprints/$bp_dir/forge-blueprint.json" $E2E_MODS
  forge_apply "$(echo "$E2E_MODS" | awk '{print $1}')"
  for m in $E2E_MODS; do forge_wait_module "$m" "module $m" 7200; done
}

# Destroy, then delete — and only delete once every module actually reports
# "destroyed". A module that has not STARTED destroying still reads "applied";
# deleting then is how a teardown walks away from live IBM resources with no
# module left to describe them.
e2e_teardown() {
  local project="$1" pid m ok=1
  pid=$(cat "$STATE/e2e.project" 2>/dev/null)
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
    rm -f "$STATE/e2e.project" "$STATE/$pid.modules"
    e2e_say "project $pid destroyed and deleted"
  else
    warn "project $pid has modules that did not destroy — leaving it in place"
    return 1
  fi
}

# Point kubectl at the cluster under test, whatever created it.
e2e_kubeconfig() {
  local cluster="$1"
  # `ibmcloud ks` resolves the cluster in the CLI's CURRENT region, which is
  # whatever the last command left it as. Pin it, or verification fails with
  # "cluster not found" at the end of an hour-long deploy.
  ibmcloud target -r "$REGION" >/dev/null 2>&1
  ibmcloud ks cluster config -c "$cluster" --admin >/dev/null 2>&1 \
    || { warn "could not fetch kubeconfig for $cluster in $REGION"; return 1; }
  kubectl config current-context >/dev/null 2>&1
}
