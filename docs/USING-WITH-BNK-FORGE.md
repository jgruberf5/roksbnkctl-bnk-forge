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
   - the four phase **artifacts** `roksbnkctl-cluster` / `roksbnkctl-bnk` /
     `roksbnkctl-testing` / `roksbnkctl-gateway` (each `kind: container_image`), and
   - the **blueprint** *IBM ROKS + BNK (roksbnkctl)* that composes them.

## 4. Put the credential template on a project

1. Open (or create) a **Project**.
2. Project detail → **Credentials** → select the IBM credential template from
   step 1.

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
with `cluster_create` off is not destroyed by `cluster down`.)

---

## Notes / gotchas

- Each phase artifact pins the runner image **by digest** (see
  `roksbnkctl/<phase>/bnkforge.artifact.json`; all four pin the same image). It
  must be a roksbnkctl build that includes `init --non-interactive` — the digest
  in this repo points at such a build.
- Requires a BNK Forge with **deployment-scoped shared workspace** support
  (`state.scope: deployment`); without it each phase module would get its own
  empty workspace and `bnk up` would fail with "workspace not initialised".
- BNK Forge ships a *built-in* example artifact `roksbnkctl-tools-runner` whose
  steps use flags roksbnkctl does not have (`--home`, `cluster up --region/--cluster-name`,
  `bnk up --outputs`, and no `--auto`) and mount at `/state`. **Do not** deploy
  that one — use the blueprint from this module source, which uses real flags,
  env-driven config, and the `/work` mount.
- A ROKS create can take 30–45 min; the artifact's per-step timeouts allow for it.
