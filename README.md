# roksbnkctl-bnk-forge

A [BNK Forge](https://github.com/jgruberf5) **module source** that runs
[roksbnkctl](https://github.com/jgruberf5/roksbnkctl) from a blueprint to
provision an IBM Cloud ROKS cluster and install BIG-IP Next for Kubernetes (BNK).

It ships **one BNK Forge artifact component per roksbnkctl phase** —
`roksbnkctl-cluster-registry`, `roksbnkctl-bnk-install`, `roksbnkctl-FAR-mirror`
and `roksbnkctl-flp`, each `kind: container_image` wrapping the published
`roksbnkctl-tools-runner` image — plus the `opentofu` module `harbor`, and
blueprints that compose them as **dependency graphs**. BNK Forge's **container
engine** runs each phase as a governed container step (argv only, no shell) on
either a **Docker** or **Kubernetes** substrate. Because the phases are separate
modules, **each phase can be deployed / re-run independently**, while a
**deployment-scoped shared workspace** (`state.scope: deployment`) keeps
roksbnkctl's single `/work` state (tfstate, generated keys, kubeconfig) shared
across them — so `bnk-install` sees the cluster `cluster-registry` adopted.

These blueprints work on a ROKS cluster **you already have**. Creating one from
scratch is roksbnkctl's own `cluster up`, run from the CLI.

Five blueprints ship here, over five modules:

| Blueprint | Builds | Modules |
|---|---|---|
| [BNK on an existing IBM ROKS cluster](blueprints/roks-existing-cluster/forge-blueprint.json) | BNK onto a cluster **you already own**, over an existing Transit Gateway | `cluster-registry → bnk-install` |
| [BNK on a disconnected IBM ROKS cluster](blueprints/roks-disconnected/forge-blueprint.json) | the **air-gapped** install, from a registry you have already mirrored | `cluster-registry → bnk-install` |
| [Private Harbor registry on an IBM Cloud VSI](blueprints/harbor-registry/forge-blueprint.json) | a private OCI registry on the Transit Gateway, CA published as an output | `harbor` |
| [Mirror F5 artifacts from FAR](blueprints/far-mirror/forge-blueprint.json) | the supply chain replicated into **any** private registry — no cluster needed | `FAR-mirror` |
| [Deploying F5 License Proxy as an IBM Cloud VSI](blueprints/flp-vsi/forge-blueprint.json) | the FLP as a **standalone VSI appliance**, no cluster | `flp` |

Both install blueprints are **two modules — register the cluster, then install BNK**.
Filling the registry is deliberately not one of them: mirroring needs no cluster, takes
far longer than the install, and is reusable across many installs. Build the registry
with the Harbor blueprint, fill it with the FAR mirror blueprint, and the install
blueprint just consumes it.

> **Why the mirror is not a module inside the Harbor blueprint.** It was, briefly. A
> module can declare an input as `source: module` and have Forge wire it from a
> dependency's output — but only on the **opentofu** path. `container_tasks` never runs
> the dependency-output wiring (`variable_assembler` layer 3); it builds the step's
> inputs from the project module's own variables. The mirror is a container module, so
> the wiring is stored, ignored, and the step runs with no registry host. Until that is
> fixed in Forge, Harbor's `registry_host` and `registry_ca_b64` outputs have to be
> carried by whoever drives the deployment.

See [Adopting an existing cluster](#adopting-an-existing-cluster) and
[The FLP-VSI blueprint](#the-flp-vsi-blueprint).

## The runner image

All four container modules pin **roksbnkctl v1.36.0** (`sha256:910ca678…`) — the
first release carrying `registry adopt`, which is what lets the disconnected
install use a mirror another deployment populated without reaching back to the
FAR source. The image carries the whole toolchain
(terraform, helm, kubectl, oc, the ibmcloud CLI), so a step needs nothing on the
host.

> **The install adopts the mirror; it does not re-replicate it.** `bnk up` refuses
> to render against a mirror the workspace has no record of, and that record is
> workspace-scoped — the deployment that filled the registry cannot hand it over.
> Before roksbnkctl v1.36.0 the only way to write one was to re-run `registry
> replicate`, which needs the FAR source reachable at install time; an air-gapped
> operator usually does not have that, which is the whole reason they mirrored.
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
  prefix, cluster_name, region,             │   roksbnkctl-tools-runner image
  resource_group, cluster_create, …         ▼   (container step, argv only)
IBM credential template ──▶ IBMCLOUD_API_KEY ──▶ init --non-interactive
                                                 → cluster up --auto
                                                 → bnk up --auto  (…testing/gateway)
persistent /work volume  ◀── state (tfstate, keys, cluster-outputs.json) ──▶ outputs
```

- **Form → env → `config.yaml`.** Blueprint `inputs` render the deploy form and
  are wired to every phase module. Each phase artifact's `apply` step-set begins
  with an idempotent `init` step that maps the inputs to `ROKSBNKCTL_*` env vars
  and runs `roksbnkctl init --non-interactive` (builds `config.yaml` from the
  environment alone — roksbnkctl ≥ the `--non-interactive` release), then runs
  that phase's `cluster up` / `bnk up` / `testing up` / `gateway up`, gated by a
  typed input. Re-running a phase re-inits (idempotent) and re-converges.
- **Phases are separate modules over one shared workspace.** `cluster`, `bnk`,
  `testing`, `gateway` are distinct artifacts wired by the blueprint's
  `depends_on` graph; `state.scope: deployment` makes them share one roksbnkctl
  `/work`, so each phase sees the others' state. **Each phase has its own
  `destroy`** (`roksbnkctl <phase> down`), so destroying the deployment tears the
  phases down in reverse dependency order (gateway → bnk/testing → cluster), and
  a single phase can be torn down on its own. The cluster phase's `destroy` runs
  `tgw disconnect` first (a no-op when no Transit Gateway was adopted) — a
  connection to an **existing** TGW lives in its own `state-tgw/` phase, which
  `cluster down` refuses to destroy underneath itself.
- **Credential template → API key.** Selecting an IBM credential template on the
  Forge project injects `IBMCLOUD_API_KEY` into the run; `region` and
  `resource_group` auto-inherit from the template via the form cascade.
- **State persists** on the mounted `/work` volume (`ROKSBNKCTL_HOME=/work/.roksbnkctl`),
  keyed to the deployment — so `destroy` tears down what `apply` created.
- **Outputs**: `cluster-outputs.json` is read back as the artifact's outputs.

## The form

| Field | Effect |
|---|---|
| `prefix` | Resource name prefix (e.g. `acme-eu`). |
| `cluster_name` | New cluster name, or existing cluster name/ID. |
| `region`, `resource_group` | Inherit from the selected IBM credential template. |
| `cluster_create` | On = provision a new ROKS cluster; Off = attach to the existing `cluster_name` (`cluster up` does both). |
| `install_bnk` | Install BIG-IP Next for Kubernetes. |
| `install_testing` | Deploy the testing phase. |
| `install_gateway` | Deploy the gateway phase. |

**Advanced (all optional):**

| Field | Effect |
|---|---|
| `existing_transit_gateway` | Adopt an existing Transit Gateway by name/ID (the new cluster + testing VPC attach to it) instead of creating one. |
| `testing_vpc_name` | Name the testing client VPC to create (testing phase). |
| `bigip_url` / `bigip_username` / `bigip_password` | BIG-IP target + credentials for the BNK **CIS** controller. |
| `zone<n>_int_vip_cidr` / `zone<n>_int_snat_cidr` / `zone<n>_ext_vlan_cidr` / `zone<n>_int_vlan_cidr` / `zone<n>_external_selfip` / `zone<n>_internal_selfip` (n = 1–3) | Per-AZ TMM network mapping — **listener (VIP)** and **SNAT** CIDRs + VLAN CIDRs + self-IPs for the BNK phase. Fill all six fields of a zone for it to apply. |

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
cluster-registry ──▶ bnk-install     (both install blueprints)

harbor                               (registry; publishes registry_host + CA)
FAR-mirror                           (fills any registry, given host + CA)
```

The mirror deliberately does **not** depend on registration — it needs no cluster
at all, so it runs in parallel and the long replicate starts immediately.

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

One module. Charts and images come from F5's registry, licensing from the
subscription JWT in your orchestration COS bucket. The form is the adopt identity
(`prefix`, `cluster_name`, `region`, `resource_group`, `existing_transit_gateway`)
plus the optional COS coordinates, the CIS BIG-IP target, and the per-AZ TMM
network mapping.

### 2. Disconnected — [BNK on a disconnected IBM ROKS cluster](blueprints/roks-disconnected/forge-blueprint.json)

**BNK Forge is the CI.** This is the same roksbnkctl step sequence the
[disconnected-cluster CI demo](https://github.com/jgruberf5/roksbnkctl/tree/main/scripts/demos/disconnected-cluster-ci-demo)
runs under Argo Workflows — two Workflows over one shared PVC become two modules
over one deployment-scoped workspace:

| Demo Workflow | Module | Steps |
|---|---|---|
| `wf-mirror.yaml` | `roksbnkctl-FAR-mirror` | `init` → `registry replicate --target generic` → `registry verify` |
| `wf-install.yaml` | `roksbnkctl-bnk-install` | `init` → `registry adopt` → `bnk up --auto` → `bnk status` |

`depends_on` serializes them exactly as `argo submit` did, and `state.scope:
deployment` is the PVC: the mirror phase's workspace — including the registry CA it
records — is what the install phase reads. The generated `config.yaml` matches the
demo's tested `bnk.yaml` field for field (adopt the cluster, `cos:` supply chain,
`registry: generic` by private IP, `license_mode: f5licenseproxy`, the existing
TGW). It differs only in `resources.{registry_cos,tgw_jumphost,client_vpc}`, which
the BNK-phase override forces off regardless of config.

Every module supports destroy, because **destroy is that phase's `down`**: the
install runs `bnk down`, the registration runs `tgw disconnect`, and the mirror
runs **`registry delete`** — which removes every artifact it replicated (by
digest, from `registry-mirror.json`) and clears the mirror record, so a later
`bnk up` reverts to pulling from FAR rather than a mirror that no longer holds
what it needs.

Additional form fields: `registry_generic_host` (the mirror's **private** IP/DNS
over the TGW), `registry_password`, `flp_external_url` + `flp_root_ca_b64` (from
`flp output` on the workspace that owns the proxy — or the FLP-VSI blueprint
below), and `cos_bucket`.

> **Two caveats.**
> 1. The demo pairs `bnk up` with a **cwc-guard sidecar** that clears F5's
>    ReadWriteOnce Multi-Attach deadlock on a **reused** cluster. A Forge container
>    step is one container with no sidecar and no shell, so that guard is not
>    reproduced. On a cluster where BNK was previously installed, licensing can
>    stall until `f5-spk-cwc` is patched to `Recreate` and cycled by hand.
> 2. `cos_bucket` / `cos_instance` / `manifest_version` need the `ROKSBNKCTL_COS_*`
>    overrides, which land in roksbnkctl **after v1.33.1** — see the note under
>    [The FLP-VSI blueprint](#the-flp-vsi-blueprint). With the v1.33.1 pin those
>    fields are ignored and the built-in COS defaults apply.

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
| `far_auth_local_file` / `subscription_jwt_local_file` | Where the entitlement files land in the workspace. Defaults match the two **project secrets** below. Clear both to pull from COS instead. |
| `cos_instance` / `cos_bucket` / `cos_region` / `far_auth_file` / `subscription_jwt_file` | The COS supply chain, when not using local files. |

**The supply chain comes from COS.** The artifact used to declare the FAR auth key
and the subscription JWT as `secret_files`, so Forge would materialize them into the
run workspace. That declaration is gone, because Forge has no way to say a secret is
*optional*: `materialize_secret_files` raises on any declared secret the project does
not have, so declaring them made the COS path — which this module fully supports, and
which the blueprint exposes as inputs — impossible to use. Builds that did not
implement `secret_files` hid this; the ones that do turn it into a hard failure:

    Required secret 'f5_far_auth_key' is not set on this project.

The two artifacts come from COS — `cos_instance` / `cos_bucket` / `cos_region` /
`far_auth_file` / `subscription_jwt_file` — as they do for every module here. The
`*_local_file` inputs are gone with the declaration: `secret_files` was the only thing
that put a file into the run workspace, so with it removed there is nothing for a local
path to point at.

| Project secret | Lands at | What it is |
|---|---|---|
| `f5_far_auth_key` | `/work/far-auth.tgz` | the F5 FAR auth tarball |
| `f5_subscription_jwt` | `/work/subscription.jwt` | the F5 subscription JWT |

This is the same **local-file supply chain** (`use_cos_bucket = false`) the tested
walkthrough uses — no COS bucket needed.

> **Runner requirement.** The FLP form drives `config.yaml` through
> `ROKSBNKCTL_FLP_MODE` / `ROKSBNKCTL_FLP_VSI_*` and the supply-chain variables,
> which land in roksbnkctl **after v1.33.1**. Until a runner image carrying them is
> published and the digest in `roksbnkctl/flp/bnkforge.artifact.json` is re-pinned,
> `init` will silently skip those fields and `flp up` will not select the VSI path.
> The four ROKS phases are unaffected — they only use variables v1.33.1 already has.

## Requirements

- A **BNK Forge** with the container-engine + Container Registries features
  (the artifact-component model).
- A **Container Registry** Access Method for `ghcr.io` (the runner image is public,
  but BNK Forge resolves a registry per image host) and an **IBM Cloud credential
  template** on the project.
- The pinned `roksbnkctl-tools-runner` image — see [The runner image](#the-runner-image).
- For the **ROKS + BNK** blueprint, the **FAR supply chain** in the IBM account
  must sit where roksbnkctl looks when no `cos:` block is configured — and that
  form has no field for it, because **v1.33.1 has no `ROKSBNKCTL_*` override for
  the COS coordinates**. Those defaults are COS instance **`bnk-supply-chain`**,
  bucket **`bnk-artifacts`**, holding **`f5-far-auth-key.tgz`** +
  **`subscription.jwt`**. (They were renamed in roksbnkctl v1.22.0 — an account
  still holding the pre-v1.22 layout `bnk-orchestration` /
  `bnk-schematics-resources` / `trial.jwt` must copy the two objects to the new
  names, or the BNK phase cannot fetch them.) The FLP-VSI blueprint sidesteps this
  entirely by taking the entitlement material as **project secrets**.
- A BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`) — required so the phase modules share roksbnkctl's
  `/work` state.

## Using it

BNK Forge ingests **modules** and **blueprints** from *separate* source types, so
this repo must be registered as **both** — and the module source first, so the
module exists in the catalog when the blueprint deploys (otherwise project
creation fails with `BLUEPRINT_MODULES_MISSING`):

1. Register this repo as a Git **module source**. The module sync discovers
   **five** packs — four `container`-engine ones,
   `roksbnkctl/{cluster-registry,bnk-install,far-mirror,flp}/bnkforge.pack.json`,
   each backed by the sibling `bnkforge.artifact.json` the container engine runs
   at deploy, plus the `opentofu` module `harbor/`.
2. Register this repo as a Git **blueprint source**. The blueprint sync walks the
   repo for files named exactly `forge-blueprint.json` and imports **all five**,
   every one under `blueprints/`.
3. On a project with an IBM credential template selected, deploy a blueprint and
   fill the form. For the FLP-VSI blueprint, add the two **project secrets**
   (`f5_far_auth_key`, `f5_subscription_jwt`) first.

A step-by-step UI walkthrough lives in [`docs/USING-WITH-BNK-FORGE.md`](docs/USING-WITH-BNK-FORGE.md).

## Layout

```
harbor/                 *.tf + cloud-init.yaml.tftpl + pack        # opentofu: private Harbor registry VSI + services VPC; TLS issued by terraform
roksbnkctl/cluster-registry/ pack + artifact                        # adopt an EXISTING cluster, register it with Forge; destroy: tgw disconnect
roksbnkctl/bnk-install/      pack + artifact                        # install BNK onto the adopted cluster;      destroy: bnk down
roksbnkctl/far-mirror/       pack + artifact                        # FAR -> private registry replicate + verify; destroy: registry delete
roksbnkctl/flp/              pack + artifact                        # standalone FLP VSI appliance (no cluster);  destroy: flp down
blueprints/roks-existing-cluster/forge-blueprint.json               # "BNK on an existing IBM ROKS cluster (existing Transit Gateway)"
blueprints/roks-disconnected/forge-blueprint.json                   # "BNK on a disconnected IBM ROKS cluster (private registry + FLP)"
blueprints/harbor-registry/forge-blueprint.json                     # "Private Harbor registry on an IBM Cloud VSI" (+ optional FAR mirror)
blueprints/far-mirror/forge-blueprint.json                          # "Mirror F5 artifacts from FAR into a private registry"
blueprints/flp-vsi/forge-blueprint.json                             # "Deploying F5 License Proxy as an IBM Cloud VSI" (roksbnkctl/flp only)
docs/USING-WITH-BNK-FORGE.md                                        # UI walkthrough for a manual test
docs/specs/                                                         # the design specs (historical; bnk-forge has since implemented them)
```

Each phase artifact declares `state.scope: deployment` so the four ROKS modules
share one roksbnkctl `/work` workspace (workspace `forge`); `apply` runs
`[init, <phase> up]` (idempotent, re-runnable). Deploy a single phase to re-run it,
or deploy the blueprint / project to run them in dependency order. The FLP module
is independent — its own workspace (`flp`), its own deployment.

Validated against BNK Forge's `validate_pack_manifest` + `validate_artifact_manifest` + `BlueprintManifest`.
