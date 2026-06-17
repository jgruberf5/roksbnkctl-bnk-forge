# DEPLOY-ENGINE-EXT-007 — Container Step Runner (Docker or Kubernetes) and Registry/Container Component

> Status: **Proposed** (draft for the BNK Forge team).
> Supersedes the earlier binary "tool store + pipeline-over-PATH" draft — the
> container is the correct unit. The execution substrate is **pluggable**: a
> Docker runner *or* a Kubernetes task runner, both first-class.

## Objective

Add a CI-style deployment model where a blueprint **stages invocations of a
pinned container image** — like a GitHub Action `uses:` — and BNK Forge runs each
step as a container **on its own execution substrate**. The unit of tooling is a
**registry/container component**: a signed, digest-pinned image (e.g.
`ghcr.io/jgruberf5/roksbnkctl-tools-runner`) that bundles a `ctl` tool and
everything it needs. A **container step runner** executes each step with one of
two interchangeable backends — **Docker** (for docker-compose installs) or
**Kubernetes Job** (for cluster installs) — injecting typed inputs as args/env,
mounting a workspace volume for state, and reading a structured outputs file.

## Bootstrapping reality (why the substrate must be pluggable)

Two facts kill a "Kubernetes-Job-only" design:

1. **There may be no cluster yet.** The flagship use case *creates* a ROKS cluster.
   A runner that needs a K8s cluster to launch the Job that creates the cluster is
   circular. The step container must run on a substrate that exists **before** any
   target cluster does.
2. **BNK Forge commonly deploys as docker-compose** (the `helm/` chart is the
   alternative, not the default). A compose install may have **no Kubernetes at
   all**.

Resolution: the step container runs on **BNK Forge's own execution substrate**,
never on the cluster being provisioned. roksbnkctl creates the cluster through the
IBM Cloud API, so the runner only needs a place to run with network egress — no
target cluster required. The substrate is therefore **selected by how BNK Forge
itself is deployed**:

| BNK Forge deployment | Container step substrate |
|---|---|
| **docker-compose** (default) | **Docker runner** — sibling containers via the host Docker engine |
| **Helm / Kubernetes** | **Kubernetes runner** — one Job per step |
| either, with a configured runner cluster | Kubernetes runner against that cluster |

(Signal that the Docker path is intended: the worker image already ships
`docker-ce-cli` with no daemon baked in — built to talk to a host Docker socket.)

## Decision summary

### Adopt

1. **Registry/container component type** (`module_source_kind = "container"`,
   `bnkforge.container.json`): an image referenced by `registry@sha256:digest`,
   signature-verified, resolved only against an admin **registry allowlist**,
   admin-approvable per (image, digest).
2. **New engine `container`** — one `EngineSpec` row (runner profile
   `container-default`), added the way `ansible` was.
3. **Steps stage container invocations** — `{uses: <container-component>, with:
   {args, env}}`, templated from **typed inputs** + prior-step outputs only. No raw
   shell; no pack-supplied image refs (the component owns digest/registry/signature).
4. **Pluggable `ContainerRunner` substrate** — a `DockerRunner` and a
   `KubernetesRunner` behind one interface, selected by deployment config. Both run
   on BNK Forge's substrate, not the target cluster.
5. **Reuse the existing spine** — Celery task lifecycle, deployment records, task
   logs, `credentials_env` injection, structured-outputs artifact.

## Registry/Container component (`bnkforge.container.json`)

```json
{
  "schema_version": 1,
  "container": {
    "name": "roksbnkctl-tools-runner",
    "description": "All-in-one roksbnkctl + terraform + IBM Cloud toolchain.",
    "image": "ghcr.io/jgruberf5/roksbnkctl-tools-runner",
    "digest": "sha256:<...>",
    "registry_host": "ghcr.io",
    "signature": { "type": "cosign", "identity": "...", "issuer": "..." },
    "default_command": ["roksbnkctl"],
    "working_dir": "/work"
  }
}
```
- Discovered like `bnkforge.pack.json` ⇒ a `module_source_kind="container"` catalog
  entry; no engine; not independently deployable (it's a dependency).
- Validation: `digest` **required** (no floating tags); `registry_host` on the
  admin allowlist (`ApplicationSetting`, refuse-by-default like `fleet_targeting`);
  `signature` required by policy; reject embedded secret fields. Approval gating
  (`is_official` / admin) per (image, digest).

## Pipeline manifest (`deployment_pack.engine = "container"`)

```json
{
  "schema_version": 1,
  "module": { "name": "...", "path": "roksbnkctl/workspace", "version": "1.0.0",
              "category": "bnk", "description": "...", "provider": "ibm" },
  "deployment_pack": {
    "engine": "container",
    "runner_profile": "container-default",
    "working_directory": ".",
    "containers": [ { "name": "roksbnkctl-tools-runner", "version": "1.11.4" } ],
    "steps": {
      "apply": [
        { "name": "init",       "uses": "roksbnkctl-tools-runner",
          "with": { "args": ["init","-w","{{inputs.ws}}","--config-file","seed.yaml","--override-from-env"] } },
        { "name": "cluster up", "uses": "roksbnkctl-tools-runner",
          "with": { "args": ["-w","{{inputs.ws}}","cluster","up","--auto"] },
          "when": "{{inputs.cluster_create}}" },
        { "name": "bnk up",     "uses": "roksbnkctl-tools-runner",
          "with": { "args": ["-w","{{inputs.ws}}","bnk","up","--auto"] },
          "when": "{{inputs.install_bnk}}" }
      ],
      "destroy": [ { "name": "down", "uses": "roksbnkctl-tools-runner",
                     "with": { "args": ["-w","{{inputs.ws}}","down","--auto"] } } ]
    },
    "lifecycle": { "supports_init": true, "supports_plan": true, "supports_apply": true,
                   "supports_destroy": true, "supports_refresh": false, "supports_drift": false },
    "outputs_file": "outputs.json"
  },
  "inputs":  { "required": [], "optional": [] },
  "outputs": { "key_outputs": [] },
  "credentials": { "required": [ { "name": "ibmcloud", "type": "cloud", "description": "..." } ] }
}
```

Validator: every step's `uses` must be in `containers[]`; `with.args` a string
array templated from typed inputs only; no `image`/`command`/`shell`/`script` and
no host-path mounts; `apply` required; `supports_destroy ⇒ destroy` step-set.

## The container step runner — one interface, two substrates

```
ContainerRunner.run_step(image_digest, command, args, env, workspace, limits, timeout) -> StepResult
```
Both backends: pull/verify the pinned image, run `command+args`, mount the
**shared workspace** (state + outputs file carried across steps), inject
`credentials_env` (e.g. `IBMCLOUD_API_KEY`) without logging it, stream logs
(redacted), enforce a timeout, and surface the exit code + outputs file.

### A. Docker runner (default for docker-compose installs)

- Launches **sibling containers** via the host Docker engine the compose stack
  already runs. Requires the Docker socket reachable from the worker — mount
  `/var/run/docker.sock` into the `celery-worker` service, **ideally via a
  docker-socket-proxy** that exposes only `containers create/start/logs/wait`
  (no `exec`, no host-bind mounts, no privileged) — or rootless Docker.
- Workspace = a **named Docker volume** per deployment run, mounted into each step
  container at `working_dir`; persists across steps and into `destroy`.
- Credentials passed via `--env` from a short-lived in-memory value; image pulled
  by digest from the allowlisted registry (or the local mirror).
- Threat model: a docker-compose BNK Forge is typically **single-host /
  single-tenant**, and BNK Forge is already the trusted control plane on that host
  — so launching governed, signed, digest-pinned sibling containers is the
  accepted CI pattern (GitLab `docker` executor, self-hosted Actions). The
  socket-proxy + image governance are the hardening; do **not** expose the raw
  socket without the proxy in any shared install.

### B. Kubernetes runner (Helm/cluster installs, or a configured runner cluster)

- Launches **one Job per step** in a locked-down runner namespace: image by
  digest; workspace = a **PVC** mounted across step Jobs; credentials via a
  short-lived **Secret** → env; deny-by-default **NetworkPolicy** (allow only the
  egress the tool needs); resource limits; `activeDeadlineSeconds`; pull secret for
  the (mirrored) registry. Strong multi-tenant isolation — the right default when
  BNK Forge runs on Kubernetes.

### Substrate selection

- A deployment-level setting `container_runner.backend = docker | kubernetes`
  (default inferred: compose ⇒ docker, Helm ⇒ kubernetes). For the K8s backend, a
  `runner_kubeconfig`/context names **where Jobs land** — a dedicated runner
  cluster/namespace is recommended over the target cluster (avoids coupling a run
  to the cluster it provisions, and to a cluster that may not exist yet).
- The pack/manifest is **substrate-agnostic** — the same `steps[]` run on either
  backend. Only the deployment picks the runner.

## State / workspace model

The workspace volume (Docker named volume or K8s PVC) is mounted across **every
step**, so a stateful tool keeps state between steps and into `destroy`. For
roksbnkctl: set `ROKSBNKCTL_HOME` to the mounted workspace and use the `local`
backend (all tools in the all-in-one image). Document remote state (roksbnkctl
`state s3` → COS) as the durable-destroy fallback for ephemeral workspaces.
Retention/cleanup is a runner-profile policy.

## GitHub Actions parallel

| GitHub Actions | This spec |
|---|---|
| container action `uses: org/img@sha` | registry/container component (digest-pinned, signed, allowlisted) |
| `with:` inputs | `with.args` / env, templated from typed blueprint inputs |
| `$GITHUB_OUTPUT` file | `outputs_file` on the workspace volume |
| workspace across steps | named Docker volume / K8s PVC across steps |
| secrets | `credentials_env` → `--env` / Job Secret |
| ephemeral VM/container runner | Docker sibling container / Kubernetes Job |

## Lifecycle, dispatch, non-goals

- **Lifecycle**: `init`/`plan`/`apply`/`destroy` → step-sets; `apply` required;
  `destroy` requires a `destroy` set; truthful matrix.
- **Dispatch**: `execution_engine="container"`; engine-aware routing per EXT-005;
  the worker **submits + watches** the step (it does not exec the tool itself).
- **Non-goals**: no pack-supplied image refs/registries/floating tags; no
  pack-controlled host mounts or privileged containers; raw socket without a proxy
  is disallowed in shared installs; additive to OpenTofu/K8s/Ansible engines. The
  worker base image is unchanged except for socket access (Docker backend) or Job
  RBAC (K8s backend).

## Phased delivery

1. **Registry/container component**: `bnkforge.container.json` kind + validator +
   registry allowlist + signature/digest verification + approval gating.
2. **`ContainerRunner` interface + `DockerRunner`** (socket-proxy mount, named
   volume, env, logs, timeout) — unblocks docker-compose installs and the
   no-cluster-yet bootstrap.
3. **`KubernetesRunner`** (Job, PVC, Secret, NetworkPolicy, limits) + the
   where-Jobs-run config.
4. **`container` EngineSpec row + manifest validator + `container_engine`**: step
   resolution, substrate dispatch, outputs normalization, Celery lifecycle,
   redaction.
5. **Migrate the roksbnkctl module-source pack** to `engine: container` using
   `roksbnkctl-tools-runner` (drop the Ansible playbook wrapper).

## Acceptance criteria

1. On a **docker-compose** BNK Forge with **no Kubernetes**, a pack with
   `containers: [roksbnkctl-tools-runner@<digest>]` runs each step as a sibling
   Docker container; state persists across steps via a named volume; the cluster
   phase creates a ROKS cluster with **no pre-existing cluster** anywhere.
2. On a **Kubernetes** BNK Forge, the same pack runs each step as a Job (PVC +
   Secret + NetworkPolicy) — **identical pack, no changes**.
3. A floating tag, non-allowlisted registry, or failed signature is rejected; a
   pack supplying its own image ref or host mount is rejected at validation.
4. `IBMCLOUD_API_KEY` reaches the step as env and is redacted in logs; non-zero
   exit fails the run; `outputs.json` normalizes into module outputs.
5. `destroy` reuses the persisted workspace; air-gapped (mirror registry +
   pre-pulled digest) runs succeed with no public egress on either substrate.

## Worked example

The `roksbnkctl/workspace` pack with `engine: container`: each phase is a step that
`uses: roksbnkctl-tools-runner` with the same typed form inputs (`cluster_create`,
`install_bnk`, `testing_vpc`, `existing_transit_gateway`, …) as args. On a
compose install the `cluster up` step runs as a **sibling container on the BNK
Forge host's Docker**, talks to the IBM Cloud API, and creates the cluster — *no
target cluster exists yet, and none is needed to run the step*. roksbnkctl uses
its `local` backend in-image; `ROKSBNKCTL_HOME` is the mounted volume;
`IBMCLOUD_API_KEY` is injected as env. The identical pack runs as Kubernetes Jobs
on a Helm-deployed BNK Forge.

---

### Implementation note for the BNK Forge session

Verify the seams: `services/engine_registry.py`, `services/module_metadata.py`
(+ manifest denylist), `models/module.py` (`module_source_kind`,
`execution_engine`), `services/execution/{engine_interface,engine_router,task_dispatch}.py`,
`docker-compose.yml` (worker service — add socket-proxy access for the Docker
backend), the kubernetes client plumbing (Job backend),
`models/system.py::ApplicationSetting` (registry allowlist), and the
`credentials_service` path. Build the `DockerRunner` first — it's the
no-cluster-yet / compose-default path.
