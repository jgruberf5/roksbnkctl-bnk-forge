# roksbnkctl-bnk-forge

A [BNK Forge](https://github.com/jgruberf5) **module source** that runs
[roksbnkctl](https://github.com/jgruberf5/roksbnkctl) from a blueprint to
provision an IBM Cloud ROKS cluster and install BIG-IP Next for Kubernetes (BNK).

It ships **one BNK Forge artifact component per roksbnkctl phase** —
`roksbnkctl-cluster-create`, `roksbnkctl-cluster-registry`,
`roksbnkctl-bnk-install`, `roksbnkctl-cwc-guard`, `roksbnkctl-FAR-mirror` and
`roksbnkctl-flp`, each `kind: container_image` wrapping the published
`roksbnkctl-tools-runner` image — plus the `opentofu` module `harbor`, and
blueprints that compose them as **dependency graphs**. BNK Forge's **container
engine** runs each phase as a governed container step (argv only, no shell) on
either a **Docker** or **Kubernetes** substrate. Because the phases are separate
modules, **each phase can be deployed / re-run independently**, while a
**deployment-scoped shared workspace** (`state.scope: deployment`) keeps
roksbnkctl's single `/work` state (tfstate, generated keys, kubeconfig) shared
across them — so `bnk-install` sees the cluster the module ahead of it built or
adopted.

The blueprints cover both directions: **creating** a ROKS cluster end to end, and
installing onto one **you already have**. Each comes in a connected and a
disconnected (air-gapped) form — the four deployment situations a customer
actually meets.

Seven blueprints ship here, over seven modules:

| Blueprint | Builds | Modules |
|---|---|---|
| [BNK on a NEW IBM ROKS cluster](blueprints/roks-new-cluster/forge-blueprint.json) | VPC, ROKS cluster and Transit Gateway, then BNK — workers have egress, so images come straight from F5 | `cluster-create → bnk-install` |
| [BNK on a NEW disconnected IBM ROKS cluster](blueprints/roks-new-cluster-disconnected/forge-blueprint.json) | the same, with **no worker egress** — images from your mirror, licensing through the FLP | `cluster-create → bnk-install` |
| [BNK on an existing IBM ROKS cluster](blueprints/roks-existing-cluster/forge-blueprint.json) | BNK onto a cluster **you already own**, over an existing Transit Gateway | `cluster-registry → bnk-install ∥ cwc-guard` |
| [BNK on a disconnected IBM ROKS cluster](blueprints/roks-disconnected/forge-blueprint.json) | the **air-gapped** install onto your own cluster, from a registry you have already mirrored | `cluster-registry → bnk-install ∥ cwc-guard` |
| [Private Harbor registry on an IBM Cloud VSI](blueprints/harbor-registry/forge-blueprint.json) | a private OCI registry on the Transit Gateway, CA published as an output, then filled from FAR | `harbor → FAR-mirror` |
| [Mirror F5 artifacts from FAR](blueprints/far-mirror/forge-blueprint.json) | the supply chain replicated into **any** private registry — no cluster needed | `FAR-mirror` |
| [Deploying F5 License Proxy as an IBM Cloud VSI](blueprints/flp-vsi/forge-blueprint.json) | the FLP as a **standalone VSI appliance**, no cluster | `flp` |

> **`cwc-guard` is on the existing-cluster blueprints only.** F5's `f5-spk-cwc`
> Multi-Attach deadlock can only arise on a cluster that has already run BNK once,
> which a freshly created cluster never has — so the new-cluster blueprints leave
> the module out rather than run a guard against an impossible condition.

Every install blueprint is the same shape — **settle the cluster, then install
BNK** — over two modules, or three where `cwc-guard` rides alongside the install.

Filling the registry is deliberately not one of them: mirroring needs no cluster,
takes far longer than the install, and is reusable across many installs. Build the
registry with the Harbor blueprint (which can fill it in the same deployment) or
point the standalone FAR mirror blueprint at a registry you already run; the
disconnected install blueprints just consume the result.

> **The Harbor blueprint fills its own registry.** The mirror module takes the
> registry address and CA straight from the harbor module's `registry_host` /
> `registry_ca_b64` outputs by `source: module` wiring, so one deployment leaves a
> registry a disconnected install can use immediately and nothing is copied by hand.
> It ships `optional: true`, which in Forge means **created but disabled** — enable
> it to mirror on the way up, or leave it off for an empty registry and run the
> standalone FAR mirror blueprint later.
>
> This needs a Forge carrying **PR #519**, which taught the container path the same
> dependency-output wiring the opentofu path already had. Before it,
> `container_tasks` built a step's inputs from the project module's own variables and
> ignored the declaration, so the mirror ran with no registry host — the step fails
> reporting a missing registry host, which reads like a blueprint that forgot a field.

See [Adopting an existing cluster](#adopting-an-existing-cluster),
[Creating the cluster too](#creating-the-cluster-too) and
[The FLP-VSI blueprint](#the-flp-vsi-blueprint).

## The runner image

All six container modules pin **roksbnkctl v1.42.0** (`sha256:4652de25…`). The
image carries the whole toolchain (terraform, helm, kubectl, oc, the ibmcloud
CLI), so a step needs nothing on the host.

The releases that matter for this repo, and why:

| Release | What it gave us |
|---|---|
| **v1.42.0** | Four fixes found bringing these four use cases up end to end. The reachability gate now **retries** each target instead of believing one TCP failure, and **rolls its DaemonSet every run** so a stale verdict cannot be re-read; `bnkforge register` updates **in place**, preserving the cluster id, and **refuses** a cluster held by another project instead of silently moving it; `kubectl`/`oc`/`shell`/`exec` passthroughs honour `-w`; and `bnk up` **refuses fast** when the cluster already has an install this workspace does not own, instead of planning 64 resources and failing 13 minutes later. |
| **v1.41.0** | `bnk up` proves the mirror and the License Proxy are reachable from **every** node before installing, riding the DaemonSet that already installs the registry CA. An unreachable mirror now fails immediately instead of surfacing as `ImagePullBackOff` and a helm deadline ten minutes later, naming neither the registry nor the node. |
| **v1.40.2** / **v1.39.0** | `cluster.vpc_cidr` (`ROKSBNKCTL_CLUSTER_VPC_CIDR`), so each cluster VPC owns its address block, and `cluster up` / `tgw connect` refuse an overlap up front. See [`scripts/e2e/CONSTRAINTS.md`](scripts/e2e/CONSTRAINTS.md). |
| **v1.38.0** | A `public_gateway=false` cluster is reachable from the operator host — the disconnected create path. |
| **v1.36.0** | `registry adopt`, which lets a disconnected install use a mirror another deployment populated without reaching back to the FAR source. |
| **v1.35.0** | `registry replicate` refuses to adopt a self-signed registry's CA from the wire — trust must be supplied out of band. |

> **`bnk up` pulls the manifest and charts host-side**, so the operator host must
> itself reach the mirror — not just the worker nodes. The runner executes on the
> BNK Forge host, whose VPC is attached to the same Transit Gateway, so this holds
> for these blueprints.

> **Tune the reachability gate when the gateway is attached in the same run.** A
> Transit Gateway attachment is asynchronous: IBM programs the routes some time
> after the connection reports `attached`. On the **NEW disconnected** blueprint,
> `cluster-create` attaches the gateway and `bnk-install` probes minutes later, so
> that blueprint ships a raised budget — `reachability_retry_seconds` **600** and
> `reachability_timeout_seconds` **900**, against roksbnkctl's defaults of 180 and
> 480. The existing-cluster disconnected blueprint leaves both blank, because an
> adopted cluster is normally already on the gateway; raise them there too if
> `cluster register` has to attach the VPC in the same run. Setting the retry
> budget to `0` is a real answer — a one-shot probe for a static environment where
> a failure is never a race.

> **The install adopts the mirror; it does not re-replicate it.** `bnk up` refuses
> to render against a mirror the workspace has no record of, and that record is
> workspace-scoped — the deployment that filled the registry cannot hand it over.
> The only other way to write one is to re-run `registry replicate`, which needs the
> FAR source reachable at install time; an air-gapped operator usually does not have
> that, which is the whole reason they mirrored.
> `roksbnkctl registry adopt` derives the record from the configured target and
> sanity-checks the mirror, with no source access. The install runs it, gated on
> `registry_target`, so the connected blueprint never sees it.

> **A self-signed mirror now needs its CA supplied out of band.** As of
> roksbnkctl **v1.35.0**, `registry replicate` refuses to adopt a self-signed
> registry's CA from the wire — unpinned trust-on-first-use handed durable,
> cluster-wide trust to whoever won a race on one dial. The disconnected
> mirror blueprints expose **`registry_ca_b64`** and **`registry_ca_sha256`** for
> this; supply at least one or the replicate step fails closed (and the refusal
> quotes the fingerprint the host actually served, so you can record the pin from
> it). **The Harbor blueprint removes the chore entirely**: its certificate is
> issued by terraform rather than by openssl on the box, so the CA is an ordinary
> module output and the mirror module takes it by `source: module` wiring — nothing
> to capture, and no SSH to the registry to bootstrap trust.

### What the container engine does and does not pass through

Learned by running these against a live Forge, and worth knowing before writing
another runner module:

- **Step `env` reaches the container; `state.home_env` may not.** Every
  `ROKSBNKCTL_*` variable here arrives via step `env`. `home_env` is the
  documented hook for `HOME`/`XDG_*`, but at least one shipping Forge build does
  not pass its keys through — so **`HOME` is declared in every step's `env`** in
  this repo (and kept in `home_env` too, for builds that honour it). Without a
  real `HOME`, helm, `ibmcloud` and `oc` resolve it to `""` and fail writing
  dotfiles at `/`. `HOME` points at `/home/runner`, the image's own home —
  **not** somewhere under `/work`, because the `ibmcloud` container-service
  plugin lives at `/home/runner/.bluemix` and moving `HOME` breaks
  `cluster register`'s kubeconfig fetch.
- **`secret_files` is all-or-nothing, and its behaviour changed.** Older builds
  validated and synced the block without implementing it — the files never
  appeared and the step failed on a missing path. Newer builds implement it, and
  now every declared secret is *mandatory*: `materialize_secret_files` raises if
  the project lacks one, with no way to mark an entry optional. A module that
  supports more than one way of getting the same material therefore cannot
  declare the secret path at all without breaking the others.

**The image is not a deploy-form field, by design.** BNK Forge resolves it solely
from the artifact's `container_image` block: the engine's `_resolve_image_digest`
applies no `{{inputs.*}}` templating there, the manifest validator requires a
`sha256:` digest and rejects floating tags, and `image` / `entrypoint` are on the
step denylist so a step cannot redirect to another image. That pin *is* the
supply-chain boundary — it is what makes mirroring, signature verification and the
registry allowlist meaningful. To move to a different build, change the `digest`
in `roksbnkctl/<phase>/bnkforge.artifact.json` and re-sync the module source; to
serve it from somewhere else, point a **Container Registry access method** at the
host rather than editing the reference.

## How it works

```
Blueprint form ──▶ step env (ROKSBNKCTL_*)  ─┐
  prefix, cos_bucket, region,               │   roksbnkctl-tools-runner image
  resource_group, …                         ▼   (container step, argv only)
IBM credential template ──▶ IBMCLOUD_API_KEY ──▶ init --non-interactive
                                                 → cluster up / cluster register
                                                 → bnk up --auto → bnk status
persistent /work volume  ◀── state (tfstate, keys, cluster-outputs.json) ──▶ outputs
```

- **Form → env → `config.yaml`.** Blueprint `inputs` render the deploy form and
  are wired to every module in the graph. Each artifact's `apply` step-set begins
  with an idempotent `init` step that maps the inputs to `ROKSBNKCTL_*` env vars
  and runs `roksbnkctl init --non-interactive` (builds `config.yaml` from the
  environment alone), then runs that phase's own verb. Re-running a module
  re-inits (idempotent) and re-converges.
- **Phases are separate modules over one shared workspace.** `cluster-create` /
  `cluster-registry`, `bnk-install` and `cwc-guard` are distinct artifacts wired by
  the blueprint's `depends_on` graph; `state.scope: deployment` makes them share
  one roksbnkctl `/work`, so each sees the others' state. **Each has its own
  `destroy`** (`roksbnkctl <phase> down`), so destroying the deployment tears them
  down in reverse dependency order and a single module can be torn down on its own.
  `cluster-create`'s destroy runs `tgw disconnect` before `cluster down` — a
  connection to an **existing** TGW lives in its own `state-tgw/` phase, which
  `cluster down` refuses to destroy underneath itself.
- **Registration runs first, deliberately.** Both graphs put the cluster on Forge's
  Kubernetes page before `bnk-install` starts, so BNK can be watched arriving on it
  while the install is still running.
- **Credential template → API key.** Selecting an IBM credential template on the
  Forge project injects `IBMCLOUD_API_KEY` into the run; `region` and
  `resource_group` auto-inherit from the template via the form cascade.
- **State persists** on the mounted `/work` volume (`ROKSBNKCTL_HOME=/work/.roksbnkctl`),
  keyed to the deployment — so `destroy` tears down what `apply` created.
- **Outputs**: `cluster-outputs.json` is read back as the artifact's outputs.

## The form

Every blueprint asks only for what it cannot work out for itself. `region` and
`resource_group` come from the credential template; `ibmcloud_api_key` is resolved
from it and never typed; `bnkforge_project` is filled with the deploying project's
own name. Anything left blank falls back to roksbnkctl's default.

**Required on all four ROKS blueprints:**

| Field | Effect |
|---|---|
| `prefix` | Resource name prefix (e.g. `acme-eu`). On the *new cluster* blueprints the cluster is named exactly this. |
| `cos_bucket` | Bucket holding the FAR auth key + subscription JWT. Required because account-suffixed bucket names (`bnk-artifacts-<account>`) cannot be guessed. |

**Also required, by blueprint:**

| Field | New | New disco | Existing | Existing disco |
|---|:--:|:--:|:--:|:--:|
| `cluster_name` — the cluster to adopt | | | ● | ● |
| `existing_transit_gateway` | | ● | ● | ● |
| `cluster_vpc_cidr` | optional | ● | | |
| `registry_generic_host` / `registry_password` / `registry_ca_b64` | | ● | | ● |
| `flp_external_url` / `flp_root_ca_b64` | | ● | | ● |

**Optional everywhere (all fall back to roksbnkctl's defaults):**

| Field | Effect |
|---|---|
| `openshift_version` / `workers_per_zone` | *New cluster* blueprints only. Default `4.20` and `2` (six workers across three zones). |
| `cos_instance` / `cos_region` / `far_auth_file` / `subscription_jwt_file` | The supply chain, when it is not at `bnk-supply-chain` / `us-south` / `f5-far-auth-key.tgz` / `subscription.jwt`. |
| `manifest_version` | BNK manifest release to install. |
| `registry_cos_name` | Overrides the registry COS instance `cluster register` probes for. |
| `bigip_url` / `bigip_username` / `bigip_password` | BIG-IP target + credentials for the BNK **CIS** controller. |
| `zone<n>_int_vip_cidr` / `zone<n>_int_snat_cidr` / `zone<n>_ext_vlan_cidr` / `zone<n>_int_vlan_cidr` / `zone<n>_external_selfip` / `zone<n>_internal_selfip` (n = 1–3) | Per-AZ TMM network mapping — **listener (VIP)** and **SNAT** CIDRs + VLAN CIDRs + self-IPs. Fill all six fields of a zone for it to apply. |
| `bnkforge_url` / `bnkforge_username` / `bnkforge_password` / `bnkforge_insecure` | Register the cluster with a Forge instance. Blank URL skips registration entirely. |

> **`cluster_vpc_cidr` is required on the new-disconnected blueprint and optional on
> the new-connected one**, and that asymmetry is the point. A disconnected cluster
> must share a Transit Gateway with the registry it pulls from, and IBM Cloud's
> default gives every VPC in a region the same address prefixes — so a second
> cluster on that gateway overlaps the first and the gateway silently drops traffic
> for one of them. A connected cluster gets its own gateway and has nothing to clash
> with. [`scripts/e2e/CONSTRAINTS.md`](scripts/e2e/CONSTRAINTS.md) has the ranges
> already taken and how the collision presents.

## Adopting an existing cluster

Two blueprints install BNK onto a ROKS cluster **you already own**, reached over a
Transit Gateway **you already own**. Both run over the `roksbnkctl-bnk-install`
module, whose `apply` is the adopt sequence:

```
init (env → config.yaml) → cluster register <name> → bnk up --auto → bnk status
```

`cluster register` writes `cluster-outputs.json` for the existing cluster and — when
`existing_transit_gateway` is set — attaches its VPC to that gateway. A VPC that is
**already** attached is *adopted*: roksbnkctl records the live connection and skips
the apply, so no terraform resource manages it.

**The cluster is never created and never destroyed.** Destroy runs `bnk down --auto`
then `tgw disconnect --auto` — never `cluster down`. And because an adopted
attachment has no managed resource behind it, `tgw disconnect` cannot remove a
connection that pre-existed; it exits 0 "nothing to do".

`cluster register` also needs the cluster's **registry COS instance**. It probes
`<prefix>-registry-cos`, `<cluster>-registry-cos` and `<cluster>-cos`; if yours is
named otherwise, set `registry_cos_name`.

### Registering the cluster with BNK Forge

Registration is its **own module, first in the graph** — `roksbnkctl-cluster-registry`.
A project apply therefore begins by adopting the cluster and putting it on Forge's
Kubernetes page, so it can be watched while BNK installs onto it. Everything else
depends on that module:

```
cluster-create   ──▶ bnk-install                  (the two NEW-cluster blueprints)
cluster-registry ──▶ bnk-install ∥ cwc-guard      (the two EXISTING-cluster blueprints)

harbor ──▶ FAR-mirror                (registry; publishes registry_host + CA, then fills it)
FAR-mirror                           (standalone: fills any registry, given host + CA)
```

The mirror deliberately does **not** depend on registration — it needs no cluster
at all, so it runs independently and the long replicate starts immediately.

The module also owns the Transit Gateway attachment (its `destroy` is
`tgw disconnect`), because `cluster register` is what creates it. `bnk-install`'s
destroy is now just `bnk down`, and Forge's reverse-order teardown gets the
sequence right: BNK first, then the detach.

Adopting a cluster into the roksbnkctl workspace does not make it visible *in
Forge*. Fill in **`bnkforge_url`** (plus username/password) and the module also
runs `roksbnkctl bnkforge register`, so the cluster lands on Forge's Kubernetes
page before BNK is installed on it. Leave the URL blank and both steps are
skipped — the `when` gate keeps the sequence unchanged for anyone who does not
want it.

It takes two steps, not one:

```
cluster register <name>  →  kubeconfig --download  →  bnkforge register
```

The middle one is load-bearing. `bnkforge register` sends the cluster's
kubeconfig in its request body, reading the **forge kubeconfig** that
`cluster up` writes — and `cluster register` does *not* write one, because it
never provisions anything. `kubeconfig --download` fetches the admin config to
`~/.kube/config`, which is the documented fallback that `register` then finds.

The password reaches the step as `BNK_FORGE_PASSWORD` in the step environment,
never as an argv token — the process table is readable and step logs are
persisted. `bnkforge_insecure` defaults to **false**; set it to `true` only for a
Forge with a self-signed certificate.

### 1. Connected — [BNK on an existing IBM ROKS cluster](blueprints/roks-existing-cluster/forge-blueprint.json)

Three modules — `cluster-registry → bnk-install ∥ cwc-guard`. Charts and images
come from F5's registry, licensing from the subscription JWT in your orchestration
COS bucket. The form is the adopt identity (`prefix`, `cluster_name`, `region`,
`resource_group`, `existing_transit_gateway`) plus the optional COS coordinates,
the CIS BIG-IP target, and the per-AZ TMM network mapping.

### 2. Disconnected — [BNK on a disconnected IBM ROKS cluster](blueprints/roks-disconnected/forge-blueprint.json)

**BNK Forge is the CI.** This is the same roksbnkctl step sequence the
[disconnected-cluster CI demo](https://github.com/jgruberf5/roksbnkctl/tree/main/scripts/demos/disconnected-cluster-ci-demo)
runs under Argo Workflows, with one structural difference: the demo's mirror
Workflow is **not** part of this blueprint. Filling the registry is its own
concern — it needs no cluster, takes far longer than the install, and is reusable
across many installs — so it lives in the Harbor and FAR-mirror blueprints, and
this one consumes the result:

| Demo Workflow | Where it lives here | Steps |
|---|---|---|
| `wf-mirror.yaml` | the **Harbor** / **FAR-mirror** blueprints | `init` → `registry replicate --target generic` → `registry verify` |
| `wf-install.yaml` | `roksbnkctl-bnk-install` in **this** blueprint | `init` → `registry adopt` → `bnk up --auto` → `bnk status` |

`registry adopt` is what bridges the two: the mirror record is workspace-scoped, so
an install that did not do the replicate has to write its own — from the configured
target, with no FAR access. `state.scope: deployment` still shares one `/work`
across this blueprint's modules. The generated `config.yaml` matches the
demo's tested `bnk.yaml` field for field (adopt the cluster, `cos:` supply chain,
`registry: generic` by private IP, `license_mode: f5licenseproxy`, the existing
TGW). It differs only in `resources.{registry_cos,tgw_jumphost,client_vpc}`, which
the BNK-phase override forces off regardless of config.

Every module supports destroy, because **destroy is that phase's `down`**: the
install runs `bnk down`, the registration runs `tgw disconnect`, and the mirror
(in its own blueprint) runs **`registry delete`** — which removes every artifact it
replicated (by digest, from `registry-mirror.json`) and clears the mirror record,
so a later `bnk up` reverts to pulling from FAR rather than a mirror that no longer
holds what it needs.

Additional form fields: `registry_generic_host` (the mirror's **private** IP/DNS
over the TGW), `registry_password`, `registry_ca_b64`, `flp_external_url` +
`flp_root_ca_b64` (from `flp output` on the workspace that owns the proxy — or the
FLP-VSI blueprint below), and `cos_bucket`.

## Creating the cluster too

The two **NEW cluster** blueprints add `roksbnkctl-cluster-create` ahead of the
install, so a project builds the VPC, the ROKS cluster and (on the connected path)
its own Transit Gateway before BNK goes on:

| | [New, connected](blueprints/roks-new-cluster/forge-blueprint.json) | [New, disconnected](blueprints/roks-new-cluster-disconnected/forge-blueprint.json) |
|---|---|---|
| Modules | `cluster-create → bnk-install` | `cluster-create → bnk-install` |
| Transit Gateway | **creates** its own | **adopts** yours — it must be the one the registry is on |
| Worker egress | yes; images direct from F5 | none; images from your mirror, licensing via the FLP |
| `cluster_vpc_cidr` | optional | **required** |
| Time | 55–70 minutes | 55–70 minutes |

`cluster-create`'s `apply` is `init → cluster up --auto → bnkforge register`. It
needs no `kubeconfig --download` step, unlike `cluster-registry`: `cluster up`
provisions, so it writes the forge kubeconfig `bnkforge register` reads.

Its `destroy` is `init → bnkforge unregister → tgw disconnect --auto →
cluster down --auto`. The disconnect comes **before** `cluster down` because a TGW
connection made in its own `state-tgw/` phase is one `cluster down` refuses to tear
down underneath itself.

> **Destroying `bnk-install` alone takes the cluster with it.** Forge tears down a
> module's dependencies with it, so `bnk-install`'s destroy cascades into
> `cluster-create`. BNK comes off in about two minutes and the cluster teardown
> starts straight after, which is easy to miss. If you want the cluster to outlive
> BNK, deploy it with an *existing cluster* blueprint instead — those never create
> or destroy it.

## The FLP-VSI blueprint

[**Deploying F5 License Proxy as an IBM Cloud VSI**](blueprints/flp-vsi/forge-blueprint.json)
is a second, independent blueprint with a single module (`roksbnkctl/flp`). It runs
`roksbnkctl flp up` in **`mode: vsi`** against an **existing VPC**, with **no
cluster** — the standalone licensing appliance from the
[disconnected walkthrough](https://github.com/jgruberf5/roksbnkctl/tree/main/scripts/demos/disconnected-cluster-cli-demo),
which is the end-to-end tested reference this artifact reproduces field for field.

```
apply:   init (env → config.yaml) → flp up --auto → flp status
destroy: flp down --auto            (exits 0 "nothing to do" when there is no state)
```

The proxy is the only component that needs egress to F5; consuming clusters reach
it privately over the VPC or a Transit Gateway. Feed this deployment's
`external_endpoint` + `root_ca_b64` outputs into the consuming workspace's
`bnk.flp.external` block.

| Field | Effect |
|---|---|
| `prefix` | Resource name prefix for the appliance. |
| `region`, `resource_group` | Inherit from the selected IBM credential template. |
| `flp_vsi_vpc` | **Existing VPC ID.** Naming a VPC is what makes the appliance cluster-less. |
| `flp_vsi_zone` / `flp_vsi_profile` / `flp_vsi_boot_size_gb` | Placement + sizing. Blank = first zone / `bx2-4x16` / 100 GB. |
| `flp_vsi_ssh_key` | Existing IBM Cloud VPC SSH key, for operator access to the appliance. |
| `flp_vsi_floating_ip` | On (default) = an operator floating IP for `flp status` + the `:80` web UI. **Not** the CWC endpoint. |
| `flp_management_allowed_cidrs` / `flp_licensing_allowed_cidrs` | Per-plane security-group scoping (`:80` UI vs. `:8443` proxy + `:22`). Comma-separated. |
| `flp_status_image` + `flp_status_registry_host` / `_ca_b64` | Run the `flp-status` web UI from a (possibly self-signed, air-gapped) mirror. |
| `cos_instance` / `cos_bucket` / `cos_region` / `far_auth_file` / `subscription_jwt_file` | The COS supply chain. `cos_bucket` is **required**; the rest default to `bnk-supply-chain` / `us-south` / `f5-far-auth-key.tgz` / `subscription.jwt`. |
| `flp_vsi_reach` / `flp_namespace` / `manifest_version` | Reachability mode, namespace, and the BNK manifest release. |

**The supply chain comes from COS — there are no project secrets.** The artifact
used to declare the FAR auth key and the subscription JWT as `secret_files`, so
Forge would materialize them into the run workspace. That declaration is gone,
because Forge has no way to mark a secret *optional*: `materialize_secret_files`
raises on any declared secret the project does not have, so declaring them made the
COS path — which this module fully supports, and which the blueprint exposes as
inputs — impossible to use. Builds that did not implement `secret_files` hid this;
the ones that do turn it into a hard failure:

    Required secret 'f5_far_auth_key' is not set on this project.

So the two artifacts come from COS, as they do for every module here. The
`far_auth_local_file` / `subscription_jwt_local_file` inputs went with the
declaration: `secret_files` was the only thing that put a file into the run
workspace, so with it removed there was nothing for a local path to point at.
**Do not add `f5_far_auth_key` / `f5_subscription_jwt` project secrets** — they are
no longer read, and older walkthroughs that tell you to create them are stale.

## Requirements

- **BNK Forge 3.1.6 or later**, with the container-engine + Container Registries
  features (the artifact-component model). 3.1.6 also carries PR #519, which the
  Harbor blueprint's built-in mirror needs, and fixes the credential template being
  dropped from a project.
- A **Container Registry** Access Method for `ghcr.io` (the runner image is public,
  but BNK Forge resolves a registry per image host) and an **IBM Cloud credential
  template** on the project, with an API key that can create VPCs, clusters and
  Transit Gateways.
- The pinned `roksbnkctl-tools-runner` image — see [The runner image](#the-runner-image).
- The **FAR supply chain** in IBM Cloud Object Storage, holding
  **`f5-far-auth-key.tgz`** + **`subscription.jwt`**. The blueprints default to COS
  instance **`bnk-supply-chain`** / bucket **`bnk-artifacts`** / region
  **`us-south`**, and every one of those is overridable on the form —
  `cos_bucket` is **required** precisely because account-suffixed bucket names
  (`bnk-artifacts-<account>`) cannot be guessed. (The object names changed in
  roksbnkctl v1.22.0 — an account still holding the pre-v1.22 layout
  `bnk-orchestration` / `bnk-schematics-resources` / `trial.jwt` must copy the two
  objects to the new names, or the BNK phase cannot fetch them.)
- An existing **Transit Gateway**, for the three blueprints that adopt one rather
  than create one.
- A BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`) — required so the phase modules share roksbnkctl's
  `/work` state.

## Using it

BNK Forge ingests **modules** and **blueprints** from *separate* source types, so
this repo must be registered as **both** — and the module source first, so the
module exists in the catalog when the blueprint deploys (otherwise project
creation fails with `BLUEPRINT_MODULES_MISSING`):

1. Register this repo as a Git **module source**. The module sync discovers
   **seven** packs — six `container`-engine ones,
   `roksbnkctl/{cluster-create,cluster-registry,bnk-install,cwc-guard,far-mirror,flp}/bnkforge.pack.json`,
   each backed by the sibling `bnkforge.artifact.json` the container engine runs
   at deploy, plus the `opentofu` module `harbor/`.
2. Register this repo as a Git **blueprint source**. The blueprint sync walks the
   repo for files named exactly `forge-blueprint.json` and imports **all seven**,
   every one under `blueprints/`.
3. On a project with an IBM credential template selected, deploy a blueprint and
   fill the form. No project secrets are needed by any blueprint — the entitlement
   material comes from COS.

Two walkthroughs:

- [**An end to end demo using BNK Forge and roksbnkctl**](scripts/demos/An%20end%20to%20end%20demo%20using%20BNK%20Forge%20and%20roksbnkctl%20for%20deployment%20use%20cases.md)
  — the customer-facing one, with screenshots, covering all four use cases plus the
  supporting registry and License Proxy.
- [`docs/USING-WITH-BNK-FORGE.md`](docs/USING-WITH-BNK-FORGE.md) — the operator's
  UI walkthrough for a manual test, field by field.

## Layout

```
harbor/                 *.tf + cloud-init.yaml.tftpl + pack        # opentofu: private Harbor registry VSI + services VPC; TLS issued by terraform
roksbnkctl/cluster-create/   pack + artifact                        # CREATE the VPC + ROKS cluster + TGW, register it;  destroy: tgw disconnect, cluster down
roksbnkctl/cluster-registry/ pack + artifact                        # adopt an EXISTING cluster, register it with Forge; destroy: tgw disconnect
roksbnkctl/bnk-install/      pack + artifact                        # install BNK onto the cluster;              destroy: bnk down
roksbnkctl/far-mirror/       pack + artifact                        # FAR -> private registry replicate + verify; destroy: registry delete
roksbnkctl/flp/              pack + artifact                        # standalone FLP VSI appliance (no cluster);  destroy: flp down
roksbnkctl/cwc-guard/        pack + artifact                        # clears F5's cwc RWO Multi-Attach deadlock;  destroy: no-op
blueprints/roks-new-cluster/forge-blueprint.json                    # "BNK on a NEW IBM ROKS cluster (created end to end)"
blueprints/roks-new-cluster-disconnected/forge-blueprint.json       # "BNK on a NEW disconnected IBM ROKS cluster (private registry + FLP)"
blueprints/roks-existing-cluster/forge-blueprint.json               # "BNK on an existing IBM ROKS cluster (existing Transit Gateway)"
blueprints/roks-disconnected/forge-blueprint.json                   # "BNK on a disconnected IBM ROKS cluster (private registry + FLP)"
blueprints/harbor-registry/forge-blueprint.json                     # "Private Harbor registry on an IBM Cloud VSI" (+ optional FAR mirror)
blueprints/far-mirror/forge-blueprint.json                          # "Mirror F5 artifacts from FAR into a private registry"
blueprints/flp-vsi/forge-blueprint.json                             # "Deploying F5 License Proxy as an IBM Cloud VSI" (roksbnkctl/flp only)
scripts/demos/                                                       # the customer walkthrough + its screenshots and driver
scripts/e2e/                                                        # the four-variant end-to-end harness; CONSTRAINTS.md is required reading
docs/USING-WITH-BNK-FORGE.md                                        # UI walkthrough for a manual test
docs/specs/                                                         # the design specs (historical; bnk-forge has since implemented them)
```

Each ROKS artifact declares `state.scope: deployment` so the modules in a blueprint
share one roksbnkctl `/work` workspace (workspace `bnk`); `apply` runs
`[init, <phase> up]` (idempotent, re-runnable). Deploy a single module to re-run it,
or deploy the blueprint / project to run them in dependency order. The FLP module
is independent — its own workspace, its own deployment.

Validated against BNK Forge's `validate_pack_manifest` + `validate_artifact_manifest` + `BlueprintManifest`.
