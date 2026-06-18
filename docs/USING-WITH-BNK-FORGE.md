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
   - the **artifact** `roksbnkctl-workspace` (`kind: container_image`), and
   - the **blueprint** *IBM ROKS + BNK (roksbnkctl)*.

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
3. **Deploy.** The container engine runs each roksbnkctl phase as a governed
   Docker sibling container:
   `init --non-interactive` → `cluster up --auto` → `bnk up --auto`.

## 6. Watch + verify

- The deployment log streams each step (the `init` step prints
  `✓ Applied N field(s) from environment …`).
- State (terraform state, generated keys, `cluster-outputs.json`) persists on the
  per-deployment `/work` volume — so a later **Destroy** can tear it down.
- On success the artifact's outputs carry `cluster_id` / `region` / etc.

## 7. Teardown

**Destroy** the deployment → runs `roksbnkctl down --auto` against the persisted
workspace. (An *existing* cluster attached with `cluster_create` off is not
destroyed.)

---

## Notes / gotchas

- The artifact pins the runner image **by digest** (see
  `roksbnkctl/workspace/bnkforge.artifact.json`). It must be a roksbnkctl build
  that includes `init --non-interactive` — the digest in this repo points at such
  a build.
- BNK Forge ships a *built-in* example artifact `roksbnkctl-tools-runner` whose
  steps use flags roksbnkctl does not have (`--home`, `cluster up --region/--cluster-name`,
  `bnk up --outputs`, and no `--auto`) and mount at `/state`. **Do not** deploy
  that one — use the blueprint from this module source, which uses real flags,
  env-driven config, and the `/work` mount.
- A ROKS create can take 30–45 min; the artifact's per-step timeouts allow for it.
