# roksbnkctl-bnk-forge

A [BNK Forge](https://github.com/jgruberf5) **module source** that runs
[roksbnkctl](https://github.com/jgruberf5/roksbnkctl) from a blueprint to
provision an IBM Cloud ROKS cluster and install BIG-IP Next for Kubernetes (BNK).

It ships a BNK Forge **artifact component** (`kind: container_image`) that wraps
the published `roksbnkctl-tools-runner` image, plus a **blueprint** that turns a
form into a roksbnkctl deployment. BNK Forge's **container engine** runs each
roksbnkctl phase as a governed container step (argv only, no shell), on either a
**Docker** or **Kubernetes** substrate.

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

- **Form → env → `config.yaml`.** Blueprint `inputs` render the deploy form; the
  artifact's `init` step maps them to `ROKSBNKCTL_*` env vars and runs
  `roksbnkctl init --non-interactive`, which builds `config.yaml` from the
  environment alone (no file, no prompt — roksbnkctl ≥ the `--non-interactive`
  release). Subsequent steps run `cluster up` / `cluster register` / `bnk up` /
  `testing up` / `gateway up`, each gated by a typed input.
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

## Requirements

- A **BNK Forge** with the container-engine + Container Registries features
  (the artifact-component model).
- A **Container Registry** Access Method for `ghcr.io` (the runner image is public,
  but BNK Forge resolves a registry per image host) and an **IBM Cloud credential
  template** on the project.
- The `roksbnkctl-tools-runner` image pinned in
  [`roksbnkctl/workspace/bnkforge.artifact.json`](roksbnkctl/workspace/bnkforge.artifact.json)
  must be a build that includes `init --non-interactive` (roksbnkctl ≥ that release).

## Using it

1. Register this repo as a Git **module source** in BNK Forge — the sync ingests
   the artifact component and the blueprint.
2. On a project with an IBM credential template selected, deploy the **IBM ROKS +
   BNK (roksbnkctl)** blueprint and fill the form.

A step-by-step UI walkthrough lives in [`docs/USING-WITH-BNK-FORGE.md`](docs/USING-WITH-BNK-FORGE.md).

## Layout

```
roksbnkctl/workspace/bnkforge.artifact.json   # kind: container_image + steps + state
forge-blueprint.json                          # the form + artifact wiring (cloud_provider: ibm)
docs/USING-WITH-BNK-FORGE.md                  # UI walkthrough for a manual test
docs/specs/                                   # the design specs (historical; bnk-forge has since implemented them)
```

Validated against BNK Forge's `validate_artifact_manifest` + `BlueprintManifest`.
