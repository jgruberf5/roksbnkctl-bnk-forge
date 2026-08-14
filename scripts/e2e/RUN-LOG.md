# Clean-room verification of the four use cases on roksbnkctl v1.42.0

Everything built for the guide was torn down and rebuilt from scratch, following
the guide, against **roksbnkctl v1.42.0** (`sha256:4652de25…`) and catalog
**5.2.0**. This records what happened, including the difficulties — the failures
are the useful part.

Started 2026-08-08 ~18:30 UTC. BNK Forge 3.1.6 at `161.156.198.185:8443`.

> **This is a record of that run, not a statement of current state.** The modules
> now pin **v1.44.0** and the catalog is **5.6.0**. The create path was re-verified
> on v1.43.0 (7/7, 59m10s); the BYO-VPC/BYO-subnet adopt path added in 5.6.0 has
> been verified only by rendering tfvars, never against live IBM Cloud.

---

## Result

| Use case | Blueprint | Cluster | Result | Wall clock |
|---|---|---|---|---|
| 1 — new, connected | `roks-new-cluster` | `f5uc1` | ✅ **7/7** | 47m18s |
| 2 — new, disconnected | `roks-new-cluster-disconnected` | `f5uc2` | ✅ **5/5** | 48m58s |
| 3 — existing, connected | `roks-existing-cluster` | `f5uc3` | ✅ **7/7** | 6m55s |
| 4 — existing, disconnected | `roks-disconnected` | `f5uc4` | ✅ **6/6** | 10m21s |

**All four passed on the first attempt with no manual intervention.** On v1.41.0
the same sequence required hand-intervention at three separate points: a
`rollout restart` of the registry-trust DaemonSet plus a module re-apply for the
disconnected install, a manual release of the Forge cluster registration before
each adopt, and a re-apply of `cwc-guard` after it exhausted its retry budget.

Every run: **38 F5 pods** running, none stuck, licence `Active`, and **103 of 103
containers** from the expected source — `repo.f5.com` on the connected cases, the
mirror at `10.243.0.4` on the disconnected ones, with zero crossover either way.
Use cases 3 and 4 additionally proved the adopted cluster kept its original id.

---

## Phase 1 — teardown

Torn down in the order the guide prescribes — cluster projects, then the F5
License Proxy, then Harbor — because the proxy's VSI sits inside the services VPC
that Harbor owns, and reversing it fails on `vpc_in_use`.

| Project | What it was |
|---|---|
| 103 `f5e2e-v3-final` | UC3 |
| 101 `f5e2e-v4-bare` | UC4 |
| 95 `f5e2e-v2-new-disco` | UC2, owned `f5e2e2` |
| 98 `f5e2e-bare-disconnected` | scaffolding, owned `f5e2e4` |
| 99 `f5e2e-bare-connected` | scaffolding, already destroyed |
| 94 `f5demo-roksbnkctl-flp` | F5 License Proxy |
| 92 `f5demo-harbor-registry` | Harbor + FAR mirror |

Plus the CLI-built `f5e2e6` (workspace `uc3src`) and the orphaned `f5e2e5`.

### Exception 1 — `f5e2e5` had to be removed by hand

`f5e2e5` had **no Forge project and no roksbnkctl workspace**, so neither
`destroy-all` nor `roksbnkctl down` could reach it. It exists because Forge
dispatched `bnk-install` on a module that was explicitly `enabled:false`, and
neither `cancel` (which returns 200 and flips the status to `planned`) nor
deleting the project stopped the container — it kept installing onto the cluster
with nothing in Forge representing it.

Filed as **bnk-forge #527**, extending **#462**. Removed with
`teardown-orphan-f5e2e5.sh`: cluster, gateway attachment, gateway, then the VPC's
subnets, public gateways and the VPC.

### Exception 2 — `destroy-all` returned non-zero on project 101, then worked

The first `POST /api/projects/101/destroy-all` returned non-zero. An immediate
retry returned a normal orchestrator task id and a full execution plan, and the
destroy ran to completion. Transient, and the teardown script absorbs it because
it polls the project's state rather than trusting the dispatch call's exit code —
which is the right shape for this API generally.

### Exception 3 — disconnected clusters always report `warning`, and it is benign

`f5e2e2` and `f5e2e4` both reported `state=warning` before teardown. The clean run
reproduced it exactly, and the pattern is unambiguous — it tracks worker egress,
not health:

| Cluster | Egress | State | Status |
|---|---|---|---|
| `f5uc1` | yes | `normal` | All Workers Normal |
| `f5uc2` | **no** | **`warning`** | Some Cluster Operators are down-level and need to be updated |
| `f5uc3` | yes | `normal` | All Workers Normal |
| `f5uc4` | **no** | **`warning`** | Some Cluster Operators are down-level and need to be updated |

A `public_gateway=false` cluster cannot reach `registry.redhat.io`, so OpenShift's
own cluster operators cannot pull their updates — visible as `ImagePullBackOff` on
the `openshift-marketplace` pods, which is expected on an air-gapped cluster and
has nothing to do with BNK. BNK itself was fully healthy on both: 38 pods running,
licence `Active` via `f5licenseproxy`, 103/103 containers from the mirror.

**This is not a fault**, but it looks like one on Forge's Kubernetes page, so the
guide now says so.

### Exception 4 — the disconnected cluster took twice as long to build

`f5uc3` (connected) took **43 minutes**; `f5uc4` (disconnected) took **92**. Same
blueprint inputs apart from `public_gateway`, built in parallel, same account and
region. Worth allowing for: the guide's "30–45 minutes" holds for a connected
cluster but is optimistic for a disconnected one.

### Exception 5 — the IBM Cloud CLI session expires silently

After ~12 hours, `ibmcloud ks cluster get` reported every cluster `absent` and the
gateway query returned an empty body rather than an error. All four clusters were
in fact running; `ibmcloud login` restored the correct answers immediately.

An expired session is indistinguishable from deleted infrastructure at the CLI, so
**re-authenticate before concluding anything is missing.** The e2e harness carries
a comment about this same class of bug having previously left `kubectl` pointed at
the wrong cluster.

---

## Phase 2 — Harbor + FAR mirror, F5 License Proxy

Rebuilt from nothing via `disconnected-roks-cluster-demo.sh up flp`.

| | |
|---|---|
| Harbor VSI module | 7m30s |
| FAR mirror module | 10m10s |
| Harbor private IP | `10.243.0.4` — same as the previous build |
| Harbor floating IP | `150.239.112.45` |
| Mirror contents | **89 repositories** in `bnk-mirror` — identical count to the previous build |
| FLP | `https://10.243.1.4:8443`, root CA captured |

Both addresses came back identical to the previous build, so the services layer is
reproducible from a clean account.

## Phase 3 — the four use cases

Run against catalog **5.2.0** (confirmed: release 199 reports
`blueprint_version = 5.2.0`) with the v1.42.0 runner digest.

Four cluster builds ran **concurrently** — the first real test of the #55 fix,
since before v1.42.0 the four workspaces shared one kubeconfig and could silently
retarget each other. No cross-talk: each verify phase asserted against its own
cluster, and the connected/disconnected pairs returned mutually exclusive results
(`connected` + 103 from `repo.f5.com` versus `f5licenseproxy` + 103 from the
mirror), which a shared kubeconfig could not have produced.

### What v1.42.0 fixed, observed live

The release notes said none of the four fixes had been exercised against a live
Forge or cluster. All four were, here:

| Issue | Fix | Observed |
|---|---|---|
| #57 | reachability gate retries; DaemonSet rolled every run | UC2's disconnected install converged on the **first** attempt. The same scenario on v1.41.0 needed a manual `rollout restart ds/registry-ca-installer` and a re-apply. |
| #53 | `bnk up` refuses fast on an install it does not own | Never fired, correctly — every adopt targeted a genuinely BNK-free cluster, and `bnk up` exited **0** on the adopt path in ~6 min (UC3) and ~10 min (UC4). |
| #54 | `bnkforge register` non-destructive, refuses another project's cluster | Both adopts took the clean unowned path; `cluster-registry` completed in ~50s each. |
| #55 | `kubectl`/`oc` passthroughs honour `-w` | Four concurrent workspaces, no cross-talk. |

### `cwc-guard` completed unaided

On UC3 and UC4 the guard finished inside its 30×60s retry budget, patching
`f5-spk-cwc` to `strategy: Recreate`. It failed on v1.41.0 only because the
install it waits for was itself stalled on the stale probe — a cascade of #57
rather than a defect of its own.

---

## Phase 4 — screenshots and guide

Captured against the clean six-project Forge: Harbor, the FLP, and one project per
use case, all `deployed`, zero failed.

Guide changes driven by what this run actually showed:

* **Step 6** now shows both pipeline shapes — a *new cluster* deployment is two
  modules in a line, an *existing cluster* deployment is three because `cwc-guard`
  runs alongside the install. Previously only one shape was illustrated.
* **Timings corrected.** The old "30–45 minutes" for a cluster holds only for a
  connected one; disconnected measured 92 minutes. Adopting an existing cluster is
  7–10 minutes total.
* **Step 7** gained the `warning`-state explanation and a command to check where
  the images actually came from, which is the whole point of the disconnected
  cases and was not previously verifiable from the guide.
* A closing section records what was asserted on every run, so the claim "verified"
  is backed by the specific checks rather than asserted.

### Exception 6 — Forge's cluster scan intermittently returns 502 in the UI

The Kubernetes page reported **"Cluster scan failed — Request failed with status
code 502"**. The cluster was healthy and the stored kubeconfig valid:
`POST /api/k8s/clusters/45/scan` returned **200** with the full inventory
(OpenShift v1.33.13, 6/6 nodes ready, 6 HP nodes). Driving the scan over the API
populated the cache and the page then rendered correctly.

So this is a UI-side timeout on its own scan call, not a broken registration.
Worth knowing because the guide's Step 7 tells operators to confirm the install on
that page — if it 502s, the cluster is very likely fine and a retry (or an API
scan) will show it.

### Exception 7 — the screenshot driver cannot reuse a browser session

`capture.cjs` starts a fresh browser per invocation, so the Kubernetes page's
project/cluster selection does not persist between runs — the selection and the
screenshot must happen in one `SHOT_STEPS` sequence. Pressing `Escape` to dismiss
the cluster dropdown also clears the project selection, so the dropdown is left
open in the captured image.

---

## Summary

Four use cases, built from an empty IBM Cloud account and an empty BNK Forge,
against roksbnkctl **v1.42.0** and catalog **5.2.0**. **All four passed on the
first attempt with no manual intervention.**

The four roksbnkctl issues raised from the previous run (#53, #54, #55, #57) were
all exercised live here for the first time — the release notes stated none of them
had been. All four behaved as intended.

Outstanding upstream issues, none of which blocked this run:

| Repo | Issue |
|---|---|
| `sp-prod-field/bnk-forge` | #525 — destroying a module cascades into its dependencies |
| | #526 — no API endpoint returns module step output |
| | #527 — a disabled module is still dispatched; cancel and project-delete do not stop it |

---

## Teardown of the verified estate

Removed with `./teardown-all.sh uc3src uc4src`, which now discovers projects by
name instead of by id — ids change on every rebuild, and a stale id silently skips
a project that is still holding a cluster.

All six Forge projects destroyed and deleted in the prescribed order, with Harbor
last and **no `vpc_in_use`**. `f5uc1`, `f5uc3` and `f5uc4` and their VPCs went with
them.

### Exception 8 — `ibmcloud ks clusters` reports 0 while clusters exist

This bit twice and is worth stating plainly: **the cluster *list* endpoint cannot
be trusted.** After the teardown it reported `count: 0` while `f5uc2` was still
running with 6 workers. Querying by name — `ibmcloud ks cluster get --cluster
<name>` — returns the truth every time.

The teardown script's closing summary used the list form and therefore printed
"clusters listed: 0" over a live cluster. Verify by name.

### Exception 9 — UC2's cluster survived its project's destroy

`f5e2e-uc2` reported every module destroyed and was deleted, but `f5uc2` was still
present afterwards (`state=warning`, 6 workers) and its VPC could not be removed:

    Cannot delete the subnet while it is in use by IBM Cloud Kubernetes Service (IKS).
    Please remove all IKS worker nodes from the subnet and retry.

The other three clusters torn down through the same path went cleanly, so this was
not systematic. Removed by hand with `ibmcloud ks cluster rm --force-delete-storage`,
then the subnets and the VPC.

**The lesson for the teardown script**: `deployed_count == 0` on the project means
Forge believes its modules are destroyed, which is not the same as the cloud
resources being gone. Confirm against the provider — by name — before deleting the
project, because once the project is gone there is nothing left to retry with.
