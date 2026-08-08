# Using roksbnkctl-bnk-forge with BNK Forge — UI walkthrough

A step-by-step manual test of every blueprint in this repo, field by field. This is
the operator's version; the customer-facing walkthrough with screenshots is
[**An end to end demo using BNK Forge and roksbnkctl**](../scripts/demo/An%20end%20to%20end%20demo%20using%20BNK%20Forge%20and%20roksbnkctl%20for%20deployment%20use%20cases.md).

Assumes **BNK Forge 3.1.6 or later** with the artifact-component / container-engine
features (Container Registries, Docker/Kubernetes container runner). A
docker-compose install already ships the `docker-socket-proxy` the Docker runner
uses, and `ghcr.io` is in the default registry-host allowlist — so the public
runner image needs **no** registry credential.

All modules pin **roksbnkctl v1.42.0** (`sha256:4652de25…`). That is the build the
four use cases are verified against; see [The runner image](../README.md#the-runner-image)
for what each release contributed.

Log in as an operator/admin.

## 1. Create an IBM Cloud credential template

This supplies `IBMCLOUD_API_KEY` to the run and lets `region` / `resource_group`
auto-fill the form.

1. Left nav → **Access Methods** (`/auth-templates`).
2. In **Credential Templates**, click **Add** (or **+**).
3. Provider: **IBM Cloud**. Name: e.g. `ibm-us-east`. Enter your **IBM Cloud API
   key**, **Region** (e.g. `us-east`), and **Resource group** (e.g. `default`).
4. Save.

The API key must be able to create VPCs, clusters and Transit Gateways.

> **Region is load-bearing.** It cascades from this template onto every form, and
> everything you then name — the VPC, the Transit Gateway, the SSH key, the
> registry — has to live in that same region. A mismatch surfaces much later as a
> confusing "VPC not found" for a VPC you can plainly see in the console. An IBM VPC
> ID carries its region in the prefix (`r014-…` is us-east, `r006-…` us-south),
> which is the quickest way to tell them apart.

## 2. Container Registry — not needed

The `roksbnkctl-tools-runner` image is **public** on `ghcr.io` (already
allowlisted), so no Container Registry Access Method is required. (You'd only add
one — Access Methods → **Container Registries** → type `ghcr`/`far`/`icr`/… — if
you mirror the image to a private registry.)

## 3. Add the source

BNK Forge ingests **modules** and **blueprints** from separate source types, but
you only add **one**: registering either creates the companion automatically.
Adding the second by hand just makes a duplicate.

1. Left nav → **Catalog**. (There is no **Modules** nav item — modules live under
   Catalog, behind the **Advanced** switch; `/modules` redirects to `/catalog`.)
2. On the **Blueprints** panel, click **Sources** → **+ Add Blueprint Source**.
3. Name: `roksbnkctl-bnk-forge`. Repository URL:
   `https://github.com/jgruberf5/roksbnkctl-bnk-forge`. Branch: `main`.
   Description: `ROKS deployment blueprints driven by roksbnkctl`. Leave
   **Git Ref** empty and **Make Default** unchecked.
4. **Save**, and let it sync.

> The **Blueprints** left-nav item points at `/stacks`; `/blueprints` is a 404.
> On some builds a freshly synced blueprint lands in state **`discovered`** with
> **Deploy** disabled — click **Import** to enable it. On 3.1.6 the blueprints are
> deployable straight after the sync.

The sync ingests **7 modules** and **7 blueprints**, all at version **5.2.0**:

| Module | What it does | Destroy |
|---|---|---|
| `roksbnkctl-cluster-create` | creates the VPC, ROKS cluster and Transit Gateway, then registers it | `tgw disconnect` → `cluster down` |
| `roksbnkctl-cluster-registry` | adopts an **existing** cluster and registers it | `tgw disconnect` |
| `roksbnkctl-bnk-install` | installs BNK onto the cluster | `bnk down` |
| `roksbnkctl-cwc-guard` | clears F5's `f5-spk-cwc` RWO Multi-Attach deadlock | no-op |
| `roksbnkctl-FAR-mirror` | replicates the supply chain into a private registry | `registry delete` |
| `roksbnkctl-flp` | standalone F5 License Proxy VSI | `flp down` |
| `harbor` | private Harbor registry VSI + services VPC (opentofu) | destroys both |

| Blueprint | Use case | Modules |
|---|---|---|
| BNK on a **NEW** IBM ROKS cluster | 1 — new, connected | `cluster-create → bnk-install` |
| BNK on a **NEW disconnected** IBM ROKS cluster | 2 — new, disconnected | `cluster-create → bnk-install` |
| BNK on an **existing** IBM ROKS cluster | 3 — existing, connected | `cluster-registry → bnk-install ∥ cwc-guard` |
| BNK on a **disconnected** IBM ROKS cluster | 4 — existing, disconnected | `cluster-registry → bnk-install ∥ cwc-guard` |
| Private Harbor registry on an IBM Cloud VSI | supporting (2 and 4) | `harbor → FAR-mirror` |
| Mirror F5 artifacts from FAR | supporting | `FAR-mirror` |
| Deploying F5 License Proxy as an IBM Cloud VSI | supporting (2 and 4) | `flp` |

## 4. The project comes from the Deploy dialog

There is no separate "create a project, then attach a credential" step. Clicking
**Deploy** on a blueprint opens a dialog that creates the project inline — you give
it a **project name**, pick the **credential template** from step 1, and confirm the
**region**. The blueprint's own fields follow in the same dialog.

**Deploy is two steps in this UI.** *Deploy Blueprint* only *creates* the project
and its modules, all `Pending`; it launches nothing. The actual run starts from the
project page: **Deploy all → Start Deployment**, which executes the dependency
pipeline.

An existing project works too — open it and select the credential template on its
**Credentials** tab before deploying into it.

> **If a module reports "no IBM Cloud API key"**, the project lost its credential
> template. Re-select it on the project and re-run the module.

> **No project secrets are needed by any blueprint.** Older revisions of this
> walkthrough told you to create `f5_far_auth_key` and `f5_subscription_jwt` file
> secrets for the FLP blueprint. That declaration is gone — Forge cannot mark a
> declared secret optional, so `materialize_secret_files` failed any project that
> did not have them, which made the COS path unusable. The entitlement material now
> comes from COS for every module. Adding those secrets does nothing.

## 5. The supply chain

Every ROKS and FLP blueprint fetches **`f5-far-auth-key.tgz`** and
**`subscription.jwt`** from IBM Cloud Object Storage. Defaults:

| Field | Default if blank |
|---|---|
| `cos_instance` | `bnk-supply-chain` |
| `cos_region` | `us-south` |
| `far_auth_file` | `f5-far-auth-key.tgz` |
| `subscription_jwt_file` | `subscription.jwt` |

**`cos_bucket` is required on every form** — account-suffixed bucket names
(`bnk-artifacts-0b5a00334eaf`) cannot be guessed, so there is no safe default.

The object names changed in roksbnkctl v1.22.0; an account still holding the
pre-v1.22 layout (`bnk-orchestration` / `bnk-schematics-resources` / `trial.jwt`)
must copy the two objects to the new names.

---

## Use case 1 — new cluster, connected

Blueprint: **BNK on a NEW IBM ROKS cluster (created end to end)**. Allow **55–70
minutes**.

1. Blueprint catalog → **Deploy** into the project.
2. Fill the form:
   - `prefix` — e.g. `acme-eu`. **The cluster is named exactly this.**
   - `cos_bucket` — your supply-chain bucket.
   - `region` / `resource_group` — inherited from the credential template.
   - `cluster_vpc_cidr` — **optional here.** This cluster gets its own Transit
     Gateway, so there is nothing to overlap.
   - `openshift_version` / `workers_per_zone` — default `4.20` and `2` (six
     workers across three zones).
3. **Deploy.** `cluster-create` runs
   `init → cluster up --auto → bnkforge register`, then `bnk-install` runs
   `init → bnk up --auto → bnk status`.

Registration happens at the end of `cluster-create`, so the cluster appears on
Forge's **Kubernetes** page before the install starts and you can watch BNK arrive
on it.

## Use case 2 — new cluster, disconnected

Blueprint: **BNK on a NEW disconnected IBM ROKS cluster**. Needs the Harbor
registry and the License Proxy standing first — see [Supporting
deployments](#supporting-deployments). Allow **55–70 minutes** on top of those.

Same as use case 1, plus:

| Field | What to enter |
|---|---|
| `existing_transit_gateway` | the gateway your registry and License Proxy are on |
| `cluster_vpc_cidr` | **required** — see the warning below |
| `registry_generic_host` | the mirror's **private** IP, e.g. `10.243.0.4` |
| `registry_password` | the mirror's admin password |
| `registry_ca_b64` | the mirror's CA certificate, base64 PEM |
| `flp_external_url` | e.g. `https://10.243.1.4:8443` |
| `flp_root_ca_b64` | from the FLP deployment's outputs |

> **`cluster_vpc_cidr` is required here and optional on use case 1**, and the
> asymmetry is the whole point. A disconnected cluster must share a Transit Gateway
> with the registry it pulls from. IBM Cloud's default gives *every* VPC in a region
> the same address prefixes, so a second cluster on that gateway overlaps the first,
> and the gateway resolves the ambiguity by silently dropping traffic for one of
> them. It presents as intermittent image-pull timeouts with every firewall in the
> path wide open — not as a routing error.
>
> Pick a block **no other VPC on that gateway is using**, including ones another
> team set up. IBM splits a `/16` into three `/18`s, one per zone, and two VPCs
> claiming the same `/18` collide even in different regions:
>
> ```
> ibmcloud tg connections <gateway-id>        # every VPC on the gateway
> ibmcloud is vpc-address-prefixes <vpc-id>   # what each one advertises
> ```
>
> [`scripts/e2e/CONSTRAINTS.md`](../scripts/e2e/CONSTRAINTS.md) records the ranges
> already taken on the test gateway and how the collision was diagnosed.

`bnk-install` picks up an extra step here: `registry adopt`, gated on
`registry_target`. The mirror record is workspace-scoped and the deployment that
filled the registry cannot hand it over, so the install writes its own — derived
from the configured target, needing no FAR access. That is the point: an air-gapped
install should not have to reach the source it mirrored to avoid.

## Use case 3 — existing cluster, connected

Blueprint: **BNK on an existing IBM ROKS cluster (existing Transit Gateway)**.
Three modules, no cluster creation.

1. Blueprint catalog → **Deploy** into the project.
2. Fill the form:
   - `prefix`, `cos_bucket`, `region`, `resource_group`
   - `cluster_name` — the **existing** cluster's name or ID
   - `existing_transit_gateway` — the gateway its VPC is reached over
   - `registry_cos_name` — only if the cluster's registry COS instance is not
     `<prefix>-registry-cos`, `<cluster>-registry-cos` or `<cluster>-cos`
3. `cluster-registry`'s apply is
   `init → cluster register → kubeconfig --download → bnkforge register`.

The middle step is load-bearing. `bnkforge register` sends the cluster's kubeconfig
in its request body, reading the **forge kubeconfig** that `cluster up` writes — and
`cluster register` does *not* write one, because it never provisions anything.
`kubeconfig --download` fetches the admin config to `~/.kube/config`, the documented
fallback `register` then finds.

**The cluster is never created and never destroyed.** Destroy runs `bnk down` then
`tgw disconnect` — never `cluster down`. A Transit Gateway attachment that
pre-existed has no terraform resource behind it, so the disconnect is a no-op for
it.

`cwc-guard` runs alongside `bnk-install`. On a cluster where BNK was **previously**
installed, F5's `f5-spk-cwc` Deployment can deadlock on its ReadWriteOnce volume
(`Multi-Attach`) and the licence never activates; the guard patches the Deployment
to `strategy: Recreate` and cycles its replicas. The new-cluster blueprints leave it
out — a freshly created cluster has never run BNK, so the deadlock cannot arise.

## Use case 4 — existing cluster, disconnected

Blueprint: **BNK on a disconnected IBM ROKS cluster (private registry + F5 License
Proxy)**. Use case 3's fields plus use case 2's registry and FLP fields. Needs the
supporting deployments below.

---

## Supporting deployments

Use cases 2 and 4 need a private registry and a License Proxy inside your network
first. Build them once; several disconnected clusters can share them.

### Private Harbor registry — and the mirror

Blueprint: **Private Harbor registry on an IBM Cloud VSI**. Allow **15–20 minutes**.

| Field | What to enter |
|---|---|
| `prefix` | names the VSI, VPC and subnet |
| `ssh_key_name` | an existing IBM Cloud VPC SSH key |
| `harbor_admin_password` | password to set for Harbor's `admin` user |
| `transit_gateway` | the gateway your clusters will attach to |
| `cos_bucket` | the supply-chain bucket |

Harbor issues its own TLS certificate **from terraform**, not from openssl on the
box, so its CA is an ordinary module output — nothing to capture over SSH.

The blueprint's second module, `roksbnkctl-FAR-mirror`, is `optional: true`, which
in Forge means **created but disabled**. Enable it to fill the registry on the way
up; leave it off for an empty registry and run the standalone FAR mirror blueprint
later. Its `registry_generic_host` and `registry_ca_b64` are wired by
`source: module` from the harbor module's outputs, so nothing is copied by hand.

> This wiring needs a Forge carrying **PR #519**. Before it, `container_tasks` built
> a step's inputs from the project module's own variables and ignored the
> declaration, so the mirror ran with no registry host — and failed reporting a
> missing registry host, which reads like a blueprint that forgot a field.

When it finishes, note the registry's **private IP** (`registry_host`) and its
**`vpc_id`** from the project's outputs.

### F5 License Proxy

Blueprint: **Deploying F5 License Proxy as an IBM Cloud VSI**. One module, no
cluster. Allow **3–5 minutes** (the VSI itself can take longer to finish booting).

| Field | What to enter |
|---|---|
| `prefix` | the same prefix you used for Harbor |
| `flp_vsi_vpc` | the services VPC **ID** from the Harbor project's `vpc_id` output — e.g. `r014-6202ec45-…`, not the VPC's name. Naming a VPC is what selects the standalone, cluster-less path. |
| `cos_bucket` | the same bucket |
| `flp_vsi_zone` / `flp_vsi_ssh_key` | recommended; the rest can stay blank |
| `flp_vsi_floating_ip` | leave **on** for the `flp status` web UI. **Not** the CWC endpoint. |

`apply` runs `init → flp up --auto → flp status`. The proxy's listener starts
serving a little **after** `flp up` returns, so an early `flp status` line may read
"unable to connect" before it goes green.

**Outputs** carry `endpoint`, `external_endpoint`, `root_ca_b64` and `floating_ip`.
Feed `external_endpoint` + `root_ca_b64` into the disconnected cluster forms.

`destroy` runs `flp down --auto`, which exits 0 "nothing to do" when there is no
state — so tearing down a never-applied module is not an error.

---

## Watch + verify

- The deployment log streams each step (the `init` step prints
  `✓ Applied N field(s) from environment …`).
- State (terraform state, generated keys, `cluster-outputs.json`) persists on the
  **deployment-shared** `/work` volume (`state.scope: deployment`, workspace `bnk`)
  — shared by every module in the blueprint, so each sees the others' state and
  **Destroy** can tear it down. The FLP module is independent, in its own `flp`
  workspace.
- Open **Kubernetes** and select the cluster. A healthy install shows **Cluster
  Ready · BNK installed** and around **38 F5 pods running** across `f5-bnk` and
  `f5-utils`.
- Confirm licensing:

      kubectl -n f5-utils get licenses.k8s.f5net.com

  | Use case | Expected `MODE` |
  |---|---|
  | 1 and 3 — connected | `connected` |
  | 2 and 4 — disconnected | `f5licenseproxy` |

  `STATE` should read `Active` in all four.

## Teardown

**Destroy all** on the project, then delete the project — in that order. Deleting a
project removes it from BNK Forge but leaves its IBM Cloud resources running, and
once the project is gone there is nothing left to destroy them with.

Take things down in the reverse of the order you built them:

| | Destroy | Why |
|---|---|---|
| 1 | your **cluster** projects | they attach to the Transit Gateway the registry uses |
| 2 | the **F5 License Proxy** | its VSI sits inside the registry's services VPC |
| 3 | the **Harbor registry** | it owns that VPC and deletes it last |

**Destroy the License Proxy before the Harbor registry.** They are separate
projects, so BNK Forge has no way to know they are related and will not stop you
doing it the other way round — but IBM Cloud will. Harbor's destroy deletes its own
VSI, then fails on the subnet and VPC with `vpc_in_use`. Nothing is lost: destroy
the proxy, then run **Destroy all** on the Harbor project again and it picks up
where it stopped.

### Removing BNK but keeping the cluster

On the *new cluster* use cases, do **not** reach for destroy on the `bnk-install`
module alone. Forge tears down a module's dependencies with it, so `bnk-install`
takes `cluster-create` — and your cluster — with it. BNK comes off in about two
minutes and the cluster teardown starts straight after, which is easy to miss.

If you want the cluster to outlive BNK, deploy it with an *existing cluster*
blueprint (use case 3 or 4) instead. Those never create or destroy the cluster.

---

## Notes / gotchas

- Each artifact pins the runner image **by digest** (see
  `roksbnkctl/<phase>/bnkforge.artifact.json`; all six pin the same image). The pin
  *is* the supply-chain boundary — `image` and `entrypoint` are on the step
  denylist, and the manifest validator rejects floating tags. To move to a different
  build, change the `digest` and re-sync the module source.
- **A module reports "no IBM Cloud API key".** The project lost its credential
  template. Re-select it on the project and re-run the module. BNK Forge 3.1.6 fixes
  the cause.
- **`bnk up` pulls the manifest and charts host-side**, so the operator host must
  itself reach the mirror — not just the worker nodes. The runner executes on the
  BNK Forge host, whose VPC is attached to the same Transit Gateway, so this holds
  here. As of v1.41.0 an unreachable mirror fails the install immediately, naming
  the registry and the node, instead of surfacing as `ImagePullBackOff` and a helm
  deadline ten minutes later.
- **The reachability gate is tunable, and the NEW-disconnected blueprint raises it.**
  A Transit Gateway attachment is asynchronous — IBM programs routes some time after
  the connection reports `attached` — so a probe run moments later reports no route
  to a mirror that is fine minutes on. v1.42.0 retries each target within a budget
  and rolls its DaemonSet every run so a stale verdict cannot be re-read. The
  new-cluster disconnected blueprint ships `reachability_retry_seconds` **600** and
  `reachability_timeout_seconds` **900** (defaults are 180 / 480) because it attaches
  the gateway in the same run as the install. Leave both blank on the existing-cluster
  blueprint unless `cluster register` has to attach the VPC for you; `0` is a valid
  answer meaning "one shot, never a race".
- **A cluster can only belong to one Forge project.** As of v1.42.0 `bnkforge register`
  updates in place and preserves the cluster id, and **refuses** a cluster another
  project holds rather than silently moving it. If you are re-pointing a cluster,
  release it from the owning project first — or pass `--force`, which performs a real
  move. Automatic registration inside `cluster up` / `bnk up` never forces.
- **`bnk up` refuses fast on an install it does not own.** If the cluster already has
  BNK and this workspace's state is empty, v1.42.0 stops before planning and names the
  cluster and namespace, instead of planning a full install over the existing one and
  failing ~13 minutes later. There is no `bnk adopt` yet, so the fix is a clear refusal,
  not a recovery — an existing-cluster deployment still needs a cluster without BNK.
- BNK Forge ships a *built-in* example artifact `roksbnkctl-tools-runner` whose
  steps use flags roksbnkctl does not have (`--home`,
  `cluster up --region/--cluster-name`, `bnk up --outputs`, and no `--auto`) and
  mount at `/state`. **Do not** deploy that one — use the blueprints from this
  source, which use real flags, env-driven config, and the `/work` mount.
- Requires a BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`); without it each module would get its own empty
  workspace and `bnk up` would fail with "workspace not initialised".
- A ROKS create takes 30–45 minutes; the artifacts' per-step timeouts allow for it.
