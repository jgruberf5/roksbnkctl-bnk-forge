#!/usr/bin/env python3
"""Consistency check for the blueprint/module catalog.

Forge PINS a module version in every blueprint (modules[].version) and reads the
input schema from the module's OWN files. Nothing cross-checks the two, so the
failure mode is silent and late: a blueprint wires an input that the pinned
module version does not declare, Forge drops it, and the deployment runs with
the field simply absent — a BYO-VPC cluster quietly builds its own network.

That is not hypothetical. 5.6.0 added `existing_subnet_ids` to the
cluster-create artifact and to both new-cluster blueprints, but left the pinned
version and the pack manifest at 5.5.0, so every one of the three declarations
disagreed with the others.

Checks, per module and per blueprint:
  1. artifact.json version == pack.json module.version
  2. every blueprint modules[].version exists on disk (matches that module)
  3. every input a blueprint passes to a module is declared by that module
  4. every module's artifact and pack declare the same input names
  5. all modules pin the same runner image digest

Exit 1 on any mismatch. No network, no Forge, safe to run in CI.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
problems: list[str] = []
external: set[str] = set()


def load(p: pathlib.Path):
    try:
        return json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001 - report, don't crash the whole run
        problems.append(f"{p.relative_to(ROOT)}: unreadable ({e})")
        return None


def input_names(schema) -> set[str]:
    """inputs is {required:[...], optional:[...]} of {name: ...} entries."""
    if not isinstance(schema, dict):
        return set()
    return {
        i.get("name")
        for group in schema.values()
        if isinstance(group, list)
        for i in group
        if isinstance(i, dict) and i.get("name")
    }


modules: dict[str, dict] = {}
for artifact_path in sorted(ROOT.glob("roksbnkctl/*/bnkforge.artifact.json")):
    d = load(artifact_path)
    if d is None:
        continue
    mod = f"roksbnkctl/{artifact_path.parent.name}"
    pack = load(artifact_path.parent / "bnkforge.pack.json")

    art_inputs = input_names(d.get("inputs"))
    entry = {
        "version": d.get("version"),
        "inputs": art_inputs,
        "digest": (d.get("container_image") or {}).get("digest"),
        "path": artifact_path,
    }
    modules[mod] = entry

    if pack is not None:
        pack_version = (pack.get("module") or {}).get("version")
        if pack_version != entry["version"]:
            problems.append(
                f"{mod}: artifact version {entry['version']} != pack version {pack_version}"
            )
        missing = art_inputs - input_names(pack.get("inputs"))
        extra = input_names(pack.get("inputs")) - art_inputs
        for n in sorted(missing):
            problems.append(f"{mod}: input {n!r} in artifact but not in pack.json")
        for n in sorted(extra):
            problems.append(f"{mod}: input {n!r} in pack.json but not in artifact")

digests = {m["digest"] for m in modules.values() if m["digest"]}
if len(digests) > 1:
    problems.append(f"modules pin {len(digests)} different runner digests: {sorted(digests)}")

for bp_path in sorted(ROOT.glob("blueprints/*/forge-blueprint.json")):
    d = load(bp_path)
    if d is None:
        continue
    name = bp_path.parent.name
    for m in d.get("modules") or []:
        mod, pinned = m.get("module"), m.get("version")
        known = modules.get(mod)
        if known is None:
            # Blueprints may compose modules this repo does not own (harbor is
            # Forge's own). Nothing to cross-check, but say so — a typo in a
            # module path looks exactly like an external reference otherwise.
            external.add(f"{name} -> {mod} {pinned}")
            continue
        if pinned != known["version"]:
            problems.append(
                f"{name}: pins {mod} {pinned}, but the module on disk is {known['version']}"
            )
        for field in sorted(set(m.get("inputs") or {}) - known["inputs"]):
            problems.append(
                f"{name}: passes {field!r} to {mod}, which does not declare it"
            )

if problems:
    print(f"catalog check FAILED ({len(problems)} problem(s)):")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)

for e in sorted(external):
    print(f"  external (not in this repo, not checked): {e}")

print(f"catalog check OK — {len(modules)} modules, "
      f"{len(list(ROOT.glob('blueprints/*/forge-blueprint.json')))} blueprints, "
      f"runner digest {(digests.pop() if digests else 'unset')[:26]}")
