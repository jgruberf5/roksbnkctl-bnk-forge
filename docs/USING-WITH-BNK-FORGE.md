# Using roksbnkctl-bnk-forge with BNK Forge — UI walkthrough

A step-by-step manual test of a roksbnkctl-based blueprint deployment.

Assumes a BNK Forge instance with the artifact-component / container-engine
features (Container Registries, Docker/Kubernetes container runner). A
docker-compose install already ships the `docker-socket-proxy` the Docker runner
uses, and `ghcr.io` is in the default registry-host allowlist — so the public
runner image needs **no** registry credential.

Log in as an operator/admin.

## 1. Create an IBM Cloud credential template

This supplies `IBMCLOUD_API_KEY` to the run and lets `region` / `resource_group`
auto-fill the form.

1. Left nav → **Access Methods** (`/auth-templates`).
2. In **Credential Templates**, click **Add** (or **+**).
3. Provider: **IBM Cloud**. Name: e.g. `ibm-eu-de`. Enter your **IBM Cloud API
   key**, **Region** (e.g. `eu-de`), and **Resource group** (e.g. `default`).
4. Save.

## 2. Container Registry — not needed

The `roksbnkctl-tools-runner` image is **public** on `ghcr.io` (already
allowlisted), so no Container Registry Access Method is required. (You'd only add
one — Access Methods → **Container Registries** → type `ghcr`/`far`/`icr`/… — if
you mirror the image to a private registry.)

## 3. Add the module source

1. Left nav → **Modules**.
2. Click **Sources** → **Add**.
3. Name: `roksbnkctl-bnk-forge`. URL:
   `https://github.com/jgruberf5/roksbnkctl-bnk-forge.git`. Branch: `main`.
4. Save and let it **sync**. The sync ingests:
   - the five **artifacts** `roksbnkctl-cluster` / `roksbnkctl-bnk` /
     `roksbnkctl-testing` / `roksbnkctl-gateway` / `roksbnkctl-flp` (each
     `kind: container_image`), and
   - **two blueprints** — *IBM ROKS + BNK (roksbnkctl)*, which composes the four
     phase modules, and *Deploying F5 License Proxy as an IBM Cloud VSI*, which
     uses `roksbnkctl-flp` on its own.

## 4. Put the credential template on a project

1. Open (or create) a **Project**.
2. Project detail → **Credentials** → select the IBM credential template from
   step 1.

## 4b. Project secrets — for the FLP-VSI blueprint only

*Deploying F5 License Proxy as an IBM Cloud VSI* takes F5's entitlement material as
**file secrets** on the project, which the container engine materializes into the
run workspace before the steps run (0600, re-created on every run — including
destroy). The ROKS + BNK blueprint does not use these.

1. Project detail → **Secrets** → **Add**, as a **file** secret.
2. Create exactly these two names:

   | Secret name | Upload | Lands in the workspace at |
   |---|---|---|
   | `f5_far_auth_key` | your `f5-far-auth-key.tgz` | `/work/far-auth.tgz` |
   | `f5_subscription_jwt` | your subscription JWT | `/work/subscription.jwt` |

The names are declared as `secret_files` on the artifact — a missing one fails the
run up front, naming the secret, rather than failing obscurely inside `flp up`.

## 5. Deploy the blueprint

1. Open the **blueprint catalog** and pick **IBM ROKS + BNK (roksbnkctl)**.
2. **Deploy** into the project. Fill the form:
   - `prefix` — e.g. `acme-eu`
   - `cluster_name` — e.g. `acme-eu-roks`
   - `region` / `resource_group` — inherited from the credential template
   - `cluster_create` — **on** for a new cluster (off = attach to the existing `cluster_name`)
   - `install_bnk` — **on**
   - `install_testing` / `install_gateway` — off for a first run
3. **Deploy.** The blueprint creates one module per phase and runs them in
   dependency order (`cluster → bnk → testing / gateway`). Each phase is a
   governed Docker sibling container whose `apply` runs `[init --non-interactive,
   <phase> up --auto]`. A disabled phase (`install_*` off) runs `init` and skips
   its `up`.
   - **Re-run a single phase** later by deploying just that module from the
     project's module list — the shared workspace means it sees the rest of the
     deployment's state.

## 6. Watch + verify

- The deployment log streams each step (the `init` step prints
  `✓ Applied N field(s) from environment …`).
- State (terraform state, generated keys, `cluster-outputs.json`) persists on the
  **deployment-shared** `/work` volume (`state.scope: deployment`) — shared by all
  four phase modules, so each phase sees the others' state and **Destroy** can tear
  it down.
- On success the `cluster` phase's outputs carry `cluster_id` / `region` / etc.

## 7. Teardown

**Destroy** the deployment → each phase runs its own `roksbnkctl <phase> down
--auto` in reverse dependency order (gateway → bnk / testing → cluster). You can
also destroy a **single phase** from its module. (An *existing* cluster attached
with `cluster_create` off is not destroyed by `cluster down`.) The cluster
phase's destroy runs `tgw disconnect --auto` before `cluster down --auto`: when
`existing_transit_gateway` was set, `cluster up` attaches the VPC in a separate
`state-tgw/` phase that `cluster down` refuses to tear down underneath itself.
It is a clean no-op when no Transit Gateway was adopted.

---

## Deploying the FLP as an IBM Cloud VSI

Same flow, different blueprint — **Deploying F5 License Proxy as an IBM Cloud
VSI**. It has one module and needs **no cluster**.

1. Do steps 1, 4 and **4b** (credential template, project, the two file secrets).
2. Blueprint catalog → **Deploying F5 License Proxy as an IBM Cloud VSI** →
   **Deploy** into the project. Fill the form:
   - `prefix` — e.g. `acme-flp`
   - `region` / `resource_group` — inherited from the credential template
   - `flp_vsi_vpc` — the **ID of an existing VPC** the consuming cluster can reach
     (same VPC, peered, or over a Transit Gateway). This is what selects the
     standalone, cluster-less path.
   - `flp_vsi_zone` / `flp_vsi_ssh_key` — recommended; the rest can stay blank.
   - `flp_vsi_floating_ip` — leave **on** to get the `flp status` web UI.
3. **Deploy.** `apply` runs `[init, flp up --auto, flp status]`. The VSI comes up in
   roughly 15–25 minutes; the proxy's listener starts serving a little **after**
   `flp up` returns, so an early `flp status` line may read "unable to connect"
   before it goes green.
4. **Outputs** carry `endpoint`, `external_endpoint`, `root_ca_b64` and
   `floating_ip`. Feed `external_endpoint` + `root_ca_b64` into the consuming
   workspace's `bnk.flp.external` block (or, in CI, the `ROKSBNKCTL_FLP_EXTERNAL_URL`
   / `ROKSBNKCTL_FLP_ROOT_CA_B64` variables) so its BNK install licenses through
   this proxy.
5. **Destroy** runs `flp down --auto`, which exits 0 "nothing to do" when there is
   no state — so a teardown of a never-applied module is not an error.

> The FLP form depends on `ROKSBNKCTL_FLP_MODE` / `ROKSBNKCTL_FLP_VSI_*`, which
> land in roksbnkctl **after v1.33.1**. Until the artifact's digest is re-pinned to
> a runner carrying them, `init` skips those fields and `flp up` will not take the
> VSI path.

---

## Notes / gotchas

- Each phase artifact pins the runner image **by digest** (see
  `roksbnkctl/<phase>/bnkforge.artifact.json`; all four pin the same image). It
  must be a roksbnkctl build that includes `init --non-interactive` — the digest
  in this repo points at **roksbnkctl v1.33.1**.
- The **FAR supply chain** must live at roksbnkctl's built-in COS defaults —
  instance `bnk-supply-chain`, bucket `bnk-artifacts`, objects
  `f5-far-auth-key.tgz` + `subscription.jwt`. The blueprint form cannot override
  them (roksbnkctl exposes no `ROKSBNKCTL_*` env var for the COS coordinates),
  and the names changed in roksbnkctl v1.22.0 — an account still holding
  `bnk-orchestration` / `bnk-schematics-resources` / `trial.jwt` must copy the
  objects across, or the BNK phase fails fetching them.
- Requires a BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`); without it each phase module would get its own
  empty workspace and `bnk up` would fail with "workspace not initialised".
- BNK Forge ships a *built-in* example artifact `roksbnkctl-tools-runner` whose
  steps use flags roksbnkctl does not have (`--home`, `cluster up --region/--cluster-name`,
  `bnk up --outputs`, and no `--auto`) and mount at `/state`. **Do not** deploy
  that one — use the blueprint from this module source, which uses real flags,
  env-driven config, and the `/work` mount.
- A ROKS create can take 30–45 min; the artifact's per-step timeouts allow for it.
