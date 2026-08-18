#!/usr/bin/env python3
"""Generate the orphan-scan / orphan-reap artifacts from their shell scripts.

The container runner mounts the deployment workspace, not this repo, so a module
cannot read a script from the source tree at run time — the body has to travel
inside the artifact's argv. Keeping the scripts as real .sh files and generating
the JSON means they stay reviewable, shellcheck-able and testable on their own,
instead of living as an unreadable one-line string someone has to unescape to
audit. Run this after editing either script; check-catalog.py asserts the two
have not drifted.
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNNER = {
    "registry_host": "ghcr.io",
    "repository": "jgruberf5/roksbnkctl-tools-runner",
    "digest": "sha256:16169df3e0718b9bd171fc1ce3e4d9cbd7a1aab48d4a976699de89f3a659f1d8",
}
VERSION = "5.7.0"

FORGE_ENV = {
    "BNK_FORGE_URL": "{{inputs.bnkforge_url}}",
    "BNK_FORGE_USER": "{{inputs.bnkforge_username}}",
    "BNK_FORGE_PASSWORD": "{{inputs.bnkforge_password}}",
    "BNK_FORGE_INSECURE": "{{inputs.bnkforge_insecure}}",
}
BASE_ENV = {
    "HOME": "/home/runner",
    "IBMCLOUD_API_KEY": "{{inputs.ibmcloud_api_key}}",
    "ORPHAN_NAME_PREFIXES": "{{inputs.name_prefixes}}",
    "ORPHAN_REGION": "{{inputs.region}}",
}


def artifact(name, desc, script_path, extra_env, outputs_file):
    body = (ROOT / script_path).read_text()
    env = {**BASE_ENV, **extra_env}
    if outputs_file:
        env["ORPHAN_OUTPUTS_FILE"] = f"/work/{outputs_file}"
    return {
        "schema_version": 1,
        "name": name,
        "version": VERSION,
        "kind": "container_image",
        "description": desc,
        "container_image": RUNNER,
        "lifecycle": {"supports_apply": True, "supports_destroy": True},
        "credentials": {"cloud": "ibmcloud"},
        "state": {
            "mount_path": "/work",
            # Reap owns nothing and emits nothing; only the scan publishes an
            # inventory for the next module to consume.
            **({"outputs_file": outputs_file} if outputs_file else {}),
            "home_env": {"HOME": "/home/runner"},
            "scope": "deployment",
        },
        "execution": {"engine": "container", "limits": {"cpus": "1", "memory": "1g"}},
        "steps": {
            "apply": [{"name": name.split("-", 1)[1], "env": env,
                       "args": ["bash", "-c", body], "timeout_seconds": 3600}],
            # Nothing to undo: these modules hold no state and own no resources.
            # A destroy that deleted things would make tearing the PROJECT down a
            # second, unreviewed reap.
            "destroy": [{"name": "noop", "env": {"HOME": "/home/runner"},
                         "args": ["bash", "-c", "echo 'orphan modules own no state - nothing to destroy'"],
                         "timeout_seconds": 60}],
        },
        "inputs": {"required": [], "optional": []},
    }


def main():
    scan = artifact(
        "roksbnkctl-orphan-scan",
        "Report IBM Cloud clusters, VPCs and Transit Gateways matching a name allowlist that no BNK Forge project owns. Read-only.",
        "roksbnkctl/orphan-scan/scan.sh", FORGE_ENV, "orphan-scan.json")
    reap = artifact(
        "roksbnkctl-orphan-reap",
        "Delete the orphans reported by roksbnkctl-orphan-scan. Destructive, and does nothing unless explicitly confirmed.",
        "roksbnkctl/orphan-reap/reap.sh",
        {"ORPHAN_CONFIRM": "{{inputs.confirm}}",
         "ORPHAN_CLUSTER_NAMES": "{{inputs.orphan_cluster_names}}",
         "ORPHAN_VPC_IDS": "{{inputs.orphan_vpc_ids}}",
         "ORPHAN_GATEWAY_IDS": "{{inputs.orphan_gateway_ids}}"},
        None)

    for mod, art in (("orphan-scan", scan), ("orphan-reap", reap)):
        pack = json.loads((ROOT / f"roksbnkctl/{mod}/bnkforge.pack.json").read_text())
        art["inputs"] = pack["inputs"]
        out = ROOT / f"roksbnkctl/{mod}/bnkforge.artifact.json"
        out.write_text(json.dumps(art, indent=2) + "\n")
        print(f"  wrote {out.relative_to(ROOT)} ({len(json.dumps(art))} bytes)")


if __name__ == "__main__":
    sys.exit(main())
