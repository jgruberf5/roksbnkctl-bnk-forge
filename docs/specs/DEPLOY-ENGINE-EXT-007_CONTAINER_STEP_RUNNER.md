# DEPLOY-ENGINE-EXT-007 — Container Step Runner and Registry/Container Component

> Status: **Proposed** (draft for the BNK Forge team).
> Supersedes the earlier binary "tool store + pipeline-over-PATH" draft — the
> container is the correct unit; the registry/container ecosystem already does
> fetch/pin/verify/isolate that the binary approach was reinventing.

## Objective

Add a CI-style deployment model where a blueprint **stages invocations of a
pinned container image** — like a GitHub Action `uses:` — instead of running
binaries baked into the worker image or fetched as loose binaries. The unit of
tooling becomes a **registry/container component**: a signed, digest-pinned image
(e.g. `ghcr.io/jgruberf5/roksbnkctl-tools-runner`) that bundles a `ctl` tool and
everything it needs. A new **container step runner** executes each declared step
as a **Kubernetes Job**, injecting typed inputs as args/env, mounting a workspace
volume for state, and reading a structured outputs file.

This is the native home for the growing family of binary `ctl` tools: each ships
one all-in-one image; BNK Forge needs only the generic container-step machinery.

## Decision summary

### Adopt

1. **Registry/container component type** — a new catalog kind (`module_source_kind
   = "container"`), declared by `bnkforge.container.json`, that references an image
   by `registry@sha256:digest`, requires a signature, and resolves only against an
   admin **registry allowlist**. Admin-approvable per (image, digest).
2. **New engine `container`** — one `EngineSpec` row in `engine_registry.py`
   (governed runner profile `container-default`), added the way `ansible` was.
3. **Steps stage container invocations.** A pack's `steps[]` are
   `{uses: <container-component>, with: {args, env, mounts}}` — args/env templated
   from **typed inputs** and prior-step outputs only. No raw shell; no pack-supplied
   image refs (the component owns the digest/registry/signature).
4. **Execution substrate is the Kubernetes Job** — never the host Docker socket,
   never privileged docker-in-docker. Each step is a Job in a locked-down runner
   namespace, with NetworkPolicy, resource limits, RBAC, and image-pull secrets for
   the (possibly mirrored) registry.
5. **Reuse the existing spine** — Celery task lifecycle, deployment records, task
   logs, `credentials_env` injection (as a Job Secret), and the structured-outputs
   artifact contract (same as the Ansible engine).

### Why containers (and why this supersedes the binary draft)

| Binary tool-store + PATH (superseded) | Registry/container component (this spec) |
|---|---|
| fetch a binary, checksum, cache, PATH-inject | pull a pinned image — the registry ecosystem already does this |
| reinvents isolation (bounded workspace, argv) | the container *is* the isolation unit |
| dependency hell (roksbnkctl + terraform + providers on PATH) | one all-in-one image bundles the whole toolchain, reproducibly |
| `ansible-core` / worker-image baking problem | nothing baked into the worker but a way to launch Jobs |
| per-tool bespoke fetch logic | one generic container-invocation model for *all* ctl tools |

It also matches how roksbnkctl already thinks: roksbnkctl runs its tools as images
(`internal/exec/docker.go`, `k8s.go`) and ships the all-in-one
`roksbnkctl-tools-runner` whose docs say to use the `local` backend inside it.
And roksbnkctl's **registry-mirror** feature already solves air-gapped image
distribution.

### Not a generic "run any container" runner

The set of runnable images = the **resolved, admin-approved, signed,
digest-pinned, allowlist-registry** component set. A pack stages *invocations*
(args/env) of an approved image; it cannot introduce an image ref, registry, or
unsigned/floating tag. That governance — plus Job-level isolation — is what makes
this safe on shared workers, and distinct from "let packs run arbitrary containers."

## The execution substrate decision (the crux)

BNK Forge runs every engine today as a **subprocess on the worker** (tofu/ansible
from the worker PATH); there is **no container execution** and **no Docker socket**
mounted on the worker. So "run a container step" forces a substrate choice. On a
shared, persistent worker:

- **Host Docker socket** → container escape = root on the worker. **Rejected.**
- **Privileged dind sidecar** → heavy + privilege-escalation surface. **Rejected.**
- **Rootless podman on the worker** → adds a runtime, weaker isolation, no
  scheduling/limits ecosystem. **Not recommended.**
- **Kubernetes Job** → BNK Forge already has cluster access + the kubernetes
  engine; gives namespace/RBAC/NetworkPolicy/resource-limit isolation, digest
  pinning, and pull secrets for a mirrored registry. **Adopt.** This is the
  Tekton / Argo / GitHub-Actions-on-Kubernetes pattern.

**Open decision for the team (flagged):** *where* the Jobs run.
- (a) a dedicated **runner namespace on a management/runner cluster** (recommended
  — strongest isolation, independent of any target cluster's lifecycle), or
- (b) the **target cluster** itself (fewer moving parts; couples the run to the
  cluster it's provisioning — circular for `cluster up`, so not for the cluster
  phase), or
- (c) a per-run **ephemeral namespace** with teardown.
The runner must accept an execution-context kubeconfig/credential (separate from
the deployment's cloud credential) identifying where Jobs land.

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
- Discovered like `bnkforge.pack.json` (a dir with this file ⇒ a
  `module_source_kind="container"` catalog entry; no engine; not independently
  deployable — it's a dependency).
- Validation: `image` + **`digest` required** (no floating tags); `registry_host`
  must be on the admin allowlist (`ApplicationSetting`, e.g.
  `containers.allowed_registries`, enforced refuse-by-default like
  `fleet_targeting`); `signature` required when policy demands; reject any
  embedded secret fields.
- Approval gating: `is_official` / admin approval per (image, digest) before it is
  runnable.

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
        { "name": "init",        "uses": "roksbnkctl-tools-runner",
          "with": { "args": ["init","-w","{{inputs.ws}}","--config-file","seed.yaml","--override-from-env"] } },
        { "name": "cluster up",  "uses": "roksbnkctl-tools-runner",
          "with": { "args": ["-w","{{inputs.ws}}","cluster","up","--auto"] },
          "when": "{{inputs.cluster_create}}" },
        { "name": "bnk up",      "uses": "roksbnkctl-tools-runner",
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

Validator rules: every step's `uses` must be in `containers[]` (resolves to an
approved registry/container component); `with.args` is a JSON string array
templated from typed inputs only; no `image`/`command`/`shell`/`script`/`mounts`
to arbitrary host paths; `apply` required; `supports_destroy ⇒ destroy` step-set.

## Container step runner (`container-default`)

Per step-set invocation, the runner:

1. **Resolves** each `uses` → its registry/container component → verifies the
   digest is pinned, the registry is allowlisted, the signature checks, and the
   (image, digest) is approved.
2. **Builds a Kubernetes Job** in the runner namespace: image by digest;
   `command` = component `default_command`; `args` = templated step args; a shared
   **workspace PVC** mounted at `working_dir` (carries state + the outputs file
   across steps); resource limits + a deny-by-default NetworkPolicy (allow only the
   egress the tool needs — e.g. IBM Cloud + the cluster API); pull secret for the
   registry/mirror; `activeDeadlineSeconds` (per-run cap, runner-profile constant).
3. **Injects credentials** as a short-lived Job Secret → env (e.g.
   `IBMCLOUD_API_KEY`); never logged (reuse the redaction pass).
4. **Runs steps in order**, streaming pod logs to the task log (redacted);
   non-zero exit ⇒ fail the run + deployment record.
5. **Reads `outputs_file`** from the workspace PVC after the last step; normalizes
   into module outputs (same contract as the Ansible engine).

Bounds: no host Docker socket; no privileged Jobs; no host-path mounts; only
approved images; per-run timeout; secret-safe logs.

## State / workspace model

The workspace **PVC is mounted across every step Job**, so a stateful tool keeps
its state between steps and into `destroy` (GitHub Actions' workspace model). For
roksbnkctl: set `ROKSBNKCTL_HOME` to the mounted workspace and let it use the
`local` backend (all tools in the all-in-one image). For ephemeral/parallel runs,
document remote state (roksbnkctl `state s3` → COS) as the durable-destroy
fallback. PVC retention/cleanup is a runner-profile policy.

## GitHub Actions parallel (done right)

| GitHub Actions | This spec |
|---|---|
| container action (`uses: org/img@sha`) | registry/container component (digest-pinned, signed, allowlisted) |
| `with:` inputs | `with.args` / env, templated from typed blueprint inputs |
| `$GITHUB_OUTPUT` file | `outputs_file` on the workspace PVC |
| workspace mount across steps | workspace PVC across step Jobs |
| secrets | `credentials_env` → Job Secret |
| ephemeral VM runner | Kubernetes Job in a locked runner namespace |

## Lifecycle, dispatch, non-goals

- **Lifecycle**: `init`/`plan`/`apply`/`destroy` map to step-sets; `apply`
  required; `destroy` requires a `destroy` step-set; truthful matrix.
- **Dispatch**: `execution_engine="container"`; engine-aware routing per EXT-005;
  runs on the worker queue (the worker submits + watches Jobs, it does not run the
  container itself).
- **Non-goals**: no host Docker socket / privileged dind; no pack-supplied image
  refs, registries, or floating tags; no arbitrary host mounts or network egress;
  not a replacement for the OpenTofu/Kubernetes/Ansible engines (additive). The
  worker base image and the engine itself stay as they are; only a Job-launch
  capability is added.

## Phased delivery

1. **Registry/container component**: `bnkforge.container.json` kind + validator +
   registry allowlist + signature/digest verification + approval gating.
2. **Job-launch capability**: a runner-namespace executor (build/submit/watch a
   Job, mount PVC + Secret, stream logs, enforce limits/NetworkPolicy/timeout).
   Decide the execution-context (where Jobs run) per the flagged decision.
3. **`container` EngineSpec row + manifest validator** (engine/containers/steps).
4. **`container_runner`**: step resolution, Job orchestration, credential Secret,
   outputs normalization, Celery dispatch + deployment records + redaction.
5. **Migrate the roksbnkctl module-source pack** to `engine: container` using
   `roksbnkctl-tools-runner` (drop the Ansible playbook wrapper).

## Acceptance criteria

1. A pack with `containers: [roksbnkctl-tools-runner@<digest>]` runs each step as a
   Kubernetes Job from that pinned, signed image; state persists across steps via a
   mounted PVC; outputs.json normalizes into module outputs.
2. A component with a floating tag (no digest), a non-allowlisted registry, or a
   failed signature is **rejected**; a pack referencing an image not in
   `containers[]`, or supplying its own image ref/host-mount, is **rejected at
   validation**.
3. No step runs via the host Docker socket or a privileged container; Jobs carry
   resource limits, a deny-by-default NetworkPolicy, and an `activeDeadlineSeconds`.
4. `IBMCLOUD_API_KEY` reaches the Job as env (via a short-lived Secret) and is
   redacted in logs; non-zero step exit fails the run.
5. `destroy` step-set tears down using the persisted workspace; air-gapped (mirror
   registry + pre-pulled digest) runs succeed with no public egress.

## Worked example

The `roksbnkctl/workspace` pack, re-expressed with `engine: container`: each phase
becomes a step that `uses: roksbnkctl-tools-runner` with the same typed form
inputs (`cluster_create`, `install_bnk`, `testing_vpc`, `existing_transit_gateway`,
…) as args. roksbnkctl runs its `local` backend inside the all-in-one image;
`ROKSBNKCTL_HOME` is the mounted PVC; `IBMCLOUD_API_KEY` is a Job Secret. No
`terraform`/`ansible-core`/roksbnkctl baked into the BNK Forge worker — the worker
only launches the Jobs.

---

### Implementation note for the BNK Forge session

Verify the seams first: `services/engine_registry.py`, `services/module_metadata.py`
(+ a manifest denylist), `models/module.py` (`module_source_kind`,
`execution_engine`), `services/execution/{engine_interface,engine_router,task_dispatch}.py`,
the kubernetes-engine client/kubeconfig plumbing (the Job-launch substrate),
`models/system.py::ApplicationSetting` (registry allowlist), and the
`credentials_service` / Secret path. Resolve the **where-do-Jobs-run** decision
before building the runner.
