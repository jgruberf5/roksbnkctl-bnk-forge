# DEPLOY-ENGINE-EXT-007 — Artifact Components, Composition, and the Container Step Runner

> Status: **Proposed** (draft for the BNK Forge team).
> Supersedes the "tool store + pipeline-over-PATH" and "registry/container
> component" drafts. The organizing concept is the **artifact component**; the
> container/registry pieces become one artifact *kind*, and execution is inferred
> from kind.

## Objective

Make the catalog citizen an **artifact component** — a typed, pinned, signed
deployment artifact (`container_image | helm_chart | manifest`) that **references
zero-or-more other artifact components**, forming a dependency graph. *How* an
artifact deploys is determined by its kind: a **container image** runs
**procedurally** via a governed **container step runner** (Docker *or* Kubernetes);
a **helm chart / manifest** deploys **declaratively** via the existing kubernetes
engine. A **blueprint** composes artifact components with an input form. The
reference graph is what makes supply-chain governance (mirror, sign, allowlist,
pull-secrets) work across *all* images a deployment pulls — not just the top one.

## Object model

One catalog citizen, three kinds, execution inferred from kind:

```
Artifact component
  ├─ kind: container_image | helm_chart | manifest
  ├─ pinned ref + digest + signature           (governed, immutable)
  ├─ references: [artifact component, …]        ← the dependency graph
  └─ execution binding  (defaulted by kind)
        container_image → PROCEDURAL  → container step runner  (steps + state)
        helm_chart      → DECLARATIVE → kubernetes engine (helm)  (values)
        manifest        → DECLARATIVE → kubernetes engine (apply) (namespace)

Blueprint = composes artifact components + the input form
```

- **Artifact = the unit.** A `container_image` is a leaf; a `helm_chart` /
  `manifest` references the `container_image` artifacts it deploys.
- **Composition = the graph.** `references` lets BNK Forge resolve the *whole*
  image set a deployment will pull, so it can mirror, signature-verify, allowlist,
  and pull-secret every node — graph-wide supply-chain, not top-of-tree only.
- **Execution = a property of kind**, not a separate component. Declarative
  artifacts converge a cluster to a state; a tool image runs a *sequence of
  commands*. Both are artifact components; the runner differs.
- **The blueprint** stays the deployable the user runs (compose + form).

| Concept | What it is | Deploys via |
|---|---|---|
| `container_image` artifact | a pinned, signed image (e.g. `roksbnkctl-tools-runner`) | container step runner (procedural steps) |
| `helm_chart` artifact | a pinned chart + the images it references | kubernetes engine (helm), declarative |
| `manifest` artifact | pinned k8s YAML + the images it references | kubernetes engine (apply), declarative |
| **blueprint** | composition of artifact components + form | the runners above, per node |

## Bootstrapping reality (why the runner substrate is pluggable)

For a **container_image** artifact the execution substrate cannot assume a target
cluster:

1. **There may be no cluster yet** — the flagship case *creates* a ROKS cluster, so
   a runner needing a cluster to launch the job that creates the cluster is circular.
2. **BNK Forge commonly deploys as docker-compose** (the `helm/` chart is the
   alternative). A compose install may have no Kubernetes at all.

So a container_image artifact runs on **BNK Forge's own substrate**, never the
target cluster — roksbnkctl creates the cluster via the IBM API, so the runner only
needs egress. The substrate follows how BNK Forge is deployed:

| BNK Forge deployment | container_image substrate |
|---|---|
| **docker-compose** (default) | **Docker runner** — sibling containers via the host engine |
| **Helm / Kubernetes** | **Kubernetes runner** — one Job per step |

(The worker image already ships `docker-ce-cli` with no daemon — built for the
sibling pattern.) Declarative artifacts (chart/manifest) deploy *to* a cluster via
the existing kubernetes engine and are out of this substrate question.

## Decision summary

### Adopt

1. **Artifact component** as the catalog kind (`module_source_kind = "artifact"`,
   `bnkforge.artifact.json`): typed `container_image | helm_chart | manifest`,
   digest-pinned, signed, allowlisted, admin-approvable, with `references[]`.
2. **Execution inferred from kind** — `container_image` → a new `container`
   `EngineSpec` row (runner profile `container-default`); `helm_chart`/`manifest` →
   the existing `kubernetes` engine. Overridable, but the default is the kind.
3. **Container step runner**, substrate-pluggable (`DockerRunner` /
   `KubernetesRunner`), running an image artifact's `steps[]` (argv invocations of
   the artifact's own image; no shell), with the generalized persistent workspace.
4. **Graph-wide supply chain** — mirror / signature-verify / registry-allowlist /
   pull-secret resolution walks the `references` graph.
5. **Container Registries — a global Access Method** (peer of SSH keys + Cloud
   Credential Templates) for pulling image artifacts; **credentials delivered per
   substrate** (env/authfile for Docker, K8s Secrets for Kubernetes); **run secrets
   persisted to the project**; reuse the Celery/deployment-record/outputs spine.

## Artifact-component manifest (`bnkforge.artifact.json`)

```json
{
  "schema_version": 1,
  "artifact": {
    "kind": "container_image",
    "name": "roksbnkctl-tools-runner",
    "version": "1.11.4",
    "category": "bnk",
    "description": "All-in-one roksbnkctl + terraform + IBM Cloud toolchain.",
    "provider": "ibm"
  },

  "container_image": {
    "image": "ghcr.io/jgruberf5/roksbnkctl-tools-runner",
    "digest": "sha256:<...>",
    "registry_host": "ghcr.io",
    "signature": { "type": "cosign", "identity": "...", "issuer": "..." },
    "default_command": ["roksbnkctl"]
  },

  "references": [],

  "execution": {
    "engine": "container",
    "runner_profile": "container-default",
    "state": { "persist": true, "mount_path": "/state", "home_env": ["ROKSBNKCTL_HOME"] },
    "steps": {
      "apply":   [
        { "name": "init",       "run": { "args": ["init","-w","{{inputs.ws}}","--config-file","seed.yaml","--override-from-env"] } },
        { "name": "cluster up", "run": { "args": ["-w","{{inputs.ws}}","cluster","up","--auto"] }, "when": "{{inputs.cluster_create}}" },
        { "name": "bnk up",     "run": { "args": ["-w","{{inputs.ws}}","bnk","up","--auto"] },      "when": "{{inputs.install_bnk}}" }
      ],
      "destroy": [ { "name": "down", "run": { "args": ["-w","{{inputs.ws}}","down","--auto"] } } ]
    },
    "outputs_file": "outputs.json"
  },

  "lifecycle": { "supports_init": true, "supports_plan": true, "supports_apply": true,
                 "supports_destroy": true, "supports_refresh": false, "supports_drift": false },
  "inputs":  { "required": [], "optional": [] },
  "outputs": { "key_outputs": [] },
  "credentials": { "required": [ { "name": "ibmcloud", "type": "cloud", "description": "..." } ] }
}
```

A **helm_chart** artifact instead carries a `helm_chart` block (`chart_ref` +
digest + signature), `references[]` listing the `container_image` artifacts it
deploys, and an `execution` of `{engine: kubernetes, values: …, namespace: …}` —
no `steps`. A **manifest** artifact is analogous with `manifest` + apply.

Validation (extend `module_metadata.py`):
- `artifact.kind ∈ {container_image, helm_chart, manifest}`; the matching typed
  block present; **digest required** (no floating tags); `registry_host` /
  chart registry on the admin allowlist; `signature` per policy; reject embedded
  secrets and shell/`command`/`image-override` keys in steps.
- `references[]` entries resolve to known artifact components (build the graph).
- `execution.engine` defaults to the kind's engine; `steps` only for procedural
  (container) execution; every `run` invokes **this artifact's own image** (argv,
  no shell). `apply` step-set required when procedural; `supports_destroy ⇒
  destroy`.

## Container step runner (container_image artifacts)

Runs an image artifact's `steps[]` on the pluggable substrate. One interface:

```
ContainerRunner.run_step(image_digest, command, args, env, workspace, limits, timeout) -> StepResult
```

### A. Docker runner (docker-compose installs / no-cluster-yet)
Sibling containers via the host Docker engine. Mount `/var/run/docker.sock` into
`celery-worker` **via a docker-socket-proxy** (only `containers create/start/logs/
wait`; no host-bind mounts, no privileged) or rootless Docker. Persistent workspace
= a **named Docker volume** subpath (named so the sibling can mount it). Pull auth =
transient authfile. Threat model: a compose BNK Forge is single-host/single-tenant
and is already the trusted control plane on the host — governed, signed,
digest-pinned sibling containers are the accepted CI pattern.

### B. Kubernetes runner (Helm/cluster installs, or a configured runner cluster)
One **Job per step** in a locked runner namespace: image by digest; persistent
workspace = a per-component **PVC** (Retain); **all credentials as short-lived K8s
Secrets** (see below); deny-by-default NetworkPolicy; resource limits;
`activeDeadlineSeconds`. Strong multi-tenant isolation.

### Substrate selection
`container_runner.backend = docker | kubernetes` (inferred: compose ⇒ docker, Helm
⇒ kubernetes). For Kubernetes, a `runner_kubeconfig`/context names **where Jobs
land** — a dedicated runner namespace is recommended over the target cluster
(avoids coupling a run to a cluster it provisions / that may not exist). The
artifact's `steps` are **substrate-agnostic**; only the deployment picks the runner.

## Declarative artifacts (helm_chart / manifest)

A `helm_chart` / `manifest` artifact deploys via the **existing kubernetes engine**
(helm install/upgrade or apply) against the project's target cluster. It is
**stateless from the runner's side** — the *cluster* holds the state — so it needs
no persistent workspace. Its value in this model is the **`references` graph**: it
enumerates the `container_image` artifacts it pulls, so BNK Forge mirrors,
signature-verifies, allowlists, and pull-secrets every one of them, and persists
the right `cne_pull_secret`. This is how the supply-chain governance built for the
container runner extends to chart/manifest deployments for free.

## Container Registries — an Access Method

Registry auth is a first-class **Access Method**, a **peer of SSH Connection keys
and Cloud Credential Templates** on the Access Methods surface (`/auth-templates` —
D-020; `Sidebar` → *Access Methods*, operator role). **Global, reusable, no project
FK**, configured **once** — like `SSHCredential` ("an access method, not a cloud
provider"): a model + `/api/container-registries` CRUD + `/test`, secrets encrypted
and never serialized. Each entry is **named**, and **multiple entries per type are
allowed** — that is how multiple environments (several FARs, several ICRs, …) and
multiple hosts coexist. Blueprints/artifacts **reference** a registry **by name/id**
(the `project.credential_template_id` selection pattern) — never embedding a secret.

| Type | Hosts | Auth | Token exchange |
|---|---|---|---|
| `ghcr` | `ghcr.io` | username + PAT / GitHub App token | — (bearer) |
| `quay` | `quay.io` | robot account user + token | — (basic) |
| `ecr`  | `*.dkr.ecr.<region>.amazonaws.com`, `public.ecr.aws` | **reference an AWS Cloud Credential Template** | `ecr GetAuthorizationToken` (~12 h) |
| `acr`  | `<name>.azurecr.io` | **reference Azure creds** (SP / managed identity), or admin user | AAD → ACR refresh token |
| `icr`  | `icr.io`, `<region>.icr.io` | **reference an IBM Cloud Credential Template** | IAM token → `iamapikey` |
| `gar`  | `<region>-docker.pkg.dev` | **reference a GCP SA** (`gcp_credentials_json`) | SA → `oauth2accesstoken` |
| `far`  | F5 Artifact Registry (per-env host, default `repo.f5.com`) | service-account JSON → HTTP Basic `_json_key_base64` : base64(SA) | — (static SA) |

- **Standalone** (`ghcr`, `quay`, `far`): own encrypted secret.
- **Derived** (`ecr`, `acr`, `icr`, `gar`): **references a Cloud Credential
  Template** and the platform exchanges it for a short-lived registry token at pull
  time (reusing the AWS session-token-expiry / `ibm_cloud_service` IAM exchange) —
  often **no new secret**.

### FAR specifics (multi-environment, named)

F5 distributes a FAR token as a **gzip tarball** (`f5-cne-far-auth-key.tgz`)
containing a **single `.json`** Google-style **service account**. The auth scheme is
HTTP **Basic** with username `_json_key_base64` and password = **base64(the SA
JSON)** — mechanically the **same `_json_key_base64` scheme as `gar`** (FAR is a
GAR-backed registry at a different host). bnk-forge ingests the **`.tgz`** (or the
raw SA JSON), extracts the first `*.json`, base64-encodes it, and on pull emits a
`dockerconfigjson` with `{username: "_json_key_base64", password: base64(SA)}` for
the FAR host. This mirrors roksbnkctl exactly
(`internal/registry/source/farauth.go::ExtractServiceAccountFromTarball` + the
`jsonKeyUser = "_json_key_base64"` Basic auth in `source.go`), and the terraform flo
module ("untar, take the first `*.json`, read as `far_service_account_b64`").

**There are multiple FAR environments, each with its own host + token**, so create
**one named `far` Container Registry per environment** (e.g. `far-prod`,
`far-staging`); artifacts/blueprints reference the FAR registry **by name**. (roksbnkctl
today carries a single `bnk.far_repo_url` + `bnk.far_auth_file` per workspace; the
Access Method generalizes that to N named environments.)

An admin **registry-host allowlist** (`ApplicationSetting`) bounds which hosts any
registry may target; resolution walks the `references` graph so every image gets a
matching named registry.

## Credential delivery per substrate

A step/task needs several credential classes, delivered in the form each substrate
consumes:

| Class | Source | Docker runner | Kubernetes runner |
|---|---|---|---|
| Registry/repo pull | Container Registry (above) | transient authfile | `dockerconfigjson` **imagePullSecret** |
| Deployment / cloud (`IBMCLOUD_API_KEY`, …) | project `CloudCredentialTemplate` → `credentials_env` | `--env` | **Opaque Secret** via `envFrom`/`secretKeyRef` |
| Git / source-repo (token / SSH key) | `module.auth_token_encrypted` (REPO-AUTH-002) / `SSHCredential` | `--env` / mounted file | **Opaque Secret** (env or mounted) |

For the **Kubernetes runner every credential is a short-lived namespaced K8s
Secret** consumed by the step Job — not the worker-local subprocess env the
kubernetes engine uses today (`_inject_credentials`). Secrets are
`ownerReferences`-bound to the Job and GC'd with it; never logged. Reuse `V1Secret`
+ `create_namespaced_secret` (`qkview_service`) and the `kubernetes_engine`
dockerconfigjson/`imagePullSecrets` precedent. The Docker runner uses env + a
transient authfile + mounted tmp files, scoped to the step.

## Persisting run secrets to the project

On a run, credentials are upserted into the project secret store — **`ProjectSecret`**
(`project_secrets`) — keyed by `(project_id, name)`. The image-pull credential is
written as the project's **`cne_pull_secret`** (the base64 dockerconfigjson whose
`auths` cover what the workload pulls — FAR `repo.f5.com`, ICR, or the mirror),
exactly where BNK image-pull auth already lives (`bnk_upgrade_service` reads it;
`bnk.far_pull_secret_default` is the global fallback) — so BNK pods + day-2 keep
pulling after the run. Where the workload needs it **in-cluster**, the run also
pushes it as a K8s Secret into the project's cluster.

Durable (`ProjectSecret`) vs transient (runner Secrets/authfiles, GC'd; exchanged
short-lived ECR/ICR/ACR/GAR tokens **re-derived, not persisted**).

## State persistence

For **procedural (container_image)** artifacts, state must survive between runs.
Reuse bnk-forge's persistent-workspace store — `WorkspaceManager` /
`ModuleContext.workspace_path` on the durable `workspace_data` + `state_data`
volumes (the OpenTofu engine's "*critical for destroy operations!*" store), **keyed
by `(deployment, component)`, not the run**, restored before each run so `destroy`
gets `apply`'s state. Docker = named-volume subpath; K8s = per-component PVC
(Retain).

**Generalized state-home env (tool-agnostic):** the runner mounts the workspace at
`state.mount_path` and sets the **component-declared** `state.home_env` var(s) to
it — `ROKSBNKCTL_HOME` for roksbnkctl, `TF_DATA_DIR` / `XDG_STATE_HOME` / `HOME` for
other `ctl` tools — so any tool reuses one mechanism. `persist: false` for
declarative artifacts (the cluster holds their state).

| roksbnkctl state-home | Persist? | If lost |
|---|---|---|
| `state*/terraform.tfstate` | **must** | can't `down`; re-`up` recreates |
| generated SSH private keys | **must** | jumphosts unreachable / recreated |
| `cluster-outputs.json` | should | reconstructable via `cluster register` |
| `config.yaml` | no | regenerated from the form each run |

State-home holds secrets (API key + private keys in tfstate) → encrypted /
access-controlled volume. **Ephemeral-runner hardening:** the tool's native remote
state (roksbnkctl `state s3` → COS) so state lives off-runner (also air-gap); the
captured `outputs_file` is the identity backstop. Retention released on stack
teardown.

## GitHub Actions parallel

| GitHub Actions | This spec |
|---|---|
| published action image | `container_image` **artifact** (pinned, signed) |
| a job's `steps:` | the artifact's `execution.steps` |
| the workflow + inputs | **blueprint** |
| `$GITHUB_OUTPUT` | `outputs_file` on the persistent workspace |
| workspace across steps | persistent workspace (named volume / PVC) |
| registry login / secrets | Container Registry Access Method / per-substrate creds |
| ephemeral runner | Docker sibling container / Kubernetes Job |

## Lifecycle, dispatch, non-goals

- **Lifecycle**: `init`/`plan`/`apply`/`destroy` step-sets for procedural artifacts;
  declarative artifacts use the kubernetes engine's lifecycle. `apply` required;
  `destroy` requires a `destroy` set; truthful matrix.
- **Dispatch**: `execution_engine` from the artifact kind (`container` /
  `kubernetes`); engine-aware routing per EXT-005; the worker submits + watches.
- **Non-goals**: no pack-supplied image refs/registries/floating tags; no raw
  shell/inline scripts in steps; no pack-controlled host mounts or privileged
  containers; raw Docker socket without a proxy disallowed in shared installs;
  additive to the OpenTofu/Kubernetes/Ansible engines.

## Phased delivery

1. **Artifact component + Container Registries Access Method**: `bnkforge.artifact.json`
   kind + validator + `references` graph + digest/signature/allowlist + approval;
   the registry Access Method (model + `/api/container-registries` CRUD + `/test` on
   `/auth-templates`; standalone + derived).
2. **`ContainerRunner` + `DockerRunner`** + the **persistent workspace**
   (`WorkspaceManager`, `state.mount_path`/`home_env`) — unblocks compose + the
   no-cluster-yet bootstrap.
3. **`KubernetesRunner`** (Job, PVC, NetworkPolicy, all-creds-as-Secrets,
   imagePullSecret) + where-Jobs-run config.
4. **`container` EngineSpec row + `container_engine`**: step resolution, substrate
   dispatch, outputs normalization, Celery lifecycle, redaction; **persist run
   secrets to the project** (`cne_pull_secret`).
5. **Declarative artifacts**: `helm_chart`/`manifest` kinds routed to the kubernetes
   engine with graph-wide mirror/sign/pull-secret from `references`.
6. **Migrate** the roksbnkctl pack to a `container_image` artifact using
   `roksbnkctl-tools-runner`.

## Acceptance criteria

1. A `container_image` artifact (`roksbnkctl-tools-runner@<digest>`) runs its
   `steps` on **both** substrates from the pinned image; on a **docker-compose, no
   Kubernetes** install the cluster phase creates a ROKS cluster with **no
   pre-existing cluster** anywhere.
2. A floating tag, non-allowlisted registry, failed signature, a step naming a
   non-own image / `sh`/`bash`, or a pack-embedded secret is rejected at validation.
3. A `helm_chart` artifact's `references` cause **every** referenced
   `container_image` to be mirrored/verified/allowlisted and covered by the
   persisted `cne_pull_secret` — graph-wide, not just the chart.
4. Private pulls work on both substrates: standalone (`ghcr`/`quay`/`far`) and
   derived (`icr`/`ecr`, no new secret); on Kubernetes the registry/cloud/repo creds
   arrive as namespaced **Secrets** GC'd with the Job; secrets never in logs/manifest.
5. After a run the project holds its secrets (`cne_pull_secret` persisted + pushed),
   so BNK pods + `bnk_upgrade_service` keep pulling.
6. **State survives between runs**: the `(deployment, component)` persistent
   workspace is restored each run so a later `destroy` tears down the earlier
   `apply`; the runner sets only the declared `state.home_env` (no tool hardcoding),
   and a second `ctl` tool with a different `home_env` works unchanged.

## Worked example

The `roksbnkctl/workspace` deployable becomes a **`container_image` artifact**
(`roksbnkctl-tools-runner`): its `execution.steps` are the phases (`init`,
`cluster up`/`register`, `bnk up`, `testing up`, `gateway up`) gated by the typed
form inputs; `state.home_env = [ROKSBNKCTL_HOME]` on the persistent workspace;
`IBMCLOUD_API_KEY` from the credential template. On a compose install the
`cluster up` step runs as a sibling container on the host's Docker — no cluster
exists yet, none is needed. A **BNK helm_chart artifact** (declarative) would sit
beside it, `references`-listing its `container_image` artifacts so the same
mirror/sign/pull-secret governance applies. The blueprint composes them + the form.

---

### Implementation note for the BNK Forge session

Verify the seams: `services/engine_registry.py`; `services/module_metadata.py`
(artifact validator + `references` graph + step denylist); `models/module.py`
(`module_source_kind`, `execution_engine`); `services/execution/{engine_interface,
engine_router,task_dispatch,kubernetes_engine,opentofu_engine}.py` +
`services/workspace_manager.py` (persistent workspace); `docker-compose.yml`
(`state_data`/`workspace_data` volumes; worker socket-proxy for the Docker backend);
`models/system.py::ApplicationSetting` (registry allowlist). For the registry
Access Method mirror `routes/ssh_credentials.py` + `models/ssh_credential.py`
(named, multiple-per-type) and surface it on `pages/AuthTemplates.tsx`; for derived
types reference a `CloudCredentialTemplate` like `project.credential_template_id`;
for `far`, ingest the `*.tgz` and emit `_json_key_base64` Basic exactly as
roksbnkctl `internal/registry/source/{farauth.go,source.go}` does (one named entry
per FAR environment). For project persistence use `models/project.py::ProjectSecret`
+ `routes/project_secrets.py` (write `cne_pull_secret`). Build the `DockerRunner` + persistent workspace first —
the no-cluster-yet / compose-default path.
