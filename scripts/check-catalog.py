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


# Discover by PACK manifest, not by artifact: an opentofu module (harbor) has a
# pack and no artifact, and globbing only roksbnkctl/*/bnkforge.artifact.json
# silently treated it as somebody else's module. It is not — and while it was
# invisible here the harbor-registry blueprint pinned harbor 5.5.0 against a
# module still declaring 5.4.0, so every Harbor deploy failed at the API with
# "Required modules missing from catalog: harbor".
#
# A blueprint's modules[].module matches the pack's module.path, which is how
# `harbor` and `roksbnkctl/far-mirror` are both addressed.
modules: dict[str, dict] = {}
for pack_path in sorted(ROOT.glob("**/bnkforge.pack.json")):
    if "node_modules" in pack_path.parts:
        continue
    pack = load(pack_path)
    if pack is None:
        continue
    meta = pack.get("module") or {}
    mod = meta.get("path") or str(pack_path.parent.relative_to(ROOT))
    pack_inputs = input_names(pack.get("inputs"))

    artifact_path = pack_path.parent / "bnkforge.artifact.json"
    art = load(artifact_path) if artifact_path.exists() else None

    entry = {
        "version": meta.get("version"),
        "inputs": pack_inputs,
        "digest": ((art or {}).get("container_image") or {}).get("digest"),
        "engine": (pack.get("deployment_pack") or {}).get("engine"),
        "path": pack_path,
    }
    modules[mod] = entry

    if art is not None:
        if art.get("version") != entry["version"]:
            problems.append(
                f"{mod}: artifact version {art.get('version')} != pack version {entry['version']}"
            )
        art_inputs = input_names(art.get("inputs"))
        entry["inputs"] = pack_inputs | art_inputs
        for n in sorted(art_inputs - pack_inputs):
            problems.append(f"{mod}: input {n!r} in artifact but not in pack.json")
        for n in sorted(pack_inputs - art_inputs):
            problems.append(f"{mod}: input {n!r} in pack.json but not in artifact")

# Forge REJECTS a pack whose optional input lacks `source`, with
# "Optional input missing 'source' field" at manifest_parse_validate — the module
# is then silently not updated ("9 found, 0 updated") while this checker passed.
# 39 new inputs were written without it and the catalog looked healthy locally.
for mod, meta in modules.items():
    pack_path = meta["path"]
    try:
        pack_raw = json.loads(pack_path.read_text())
    except Exception:
        continue
    for group, items in (pack_raw.get("inputs") or {}).items():
        if not isinstance(items, list):
            continue
        for entry in items:
            if isinstance(entry, dict) and "source" not in entry:
                problems.append(
                    f"{mod}: pack input {entry.get('name')!r} in {group!r} has no 'source' "
                    f"— Forge rejects the pack and silently does not update the module"
                )

# Line-specific fields must SAY which line they belong to.
#
# roksbnkctl drives 2.3 and 2.4 from one build, selected solely by
# manifest_version — there is deliberately no separate line field, because a
# second way to say which release this is can disagree with the manifest being
# installed. Forge follows that: one set of modules, one set of blueprints.
#
# The cost is that 22 of ~217 settings do nothing on the other line, and a flat
# list of inputs cannot show that. So every field roksbnkctl marks 2.3-only or
# 2.4-only carries the line in its description. This check fails if one does not,
# which is what stops the labelling rotting the first time a field is added.
LINE_FIELDS = ROOT / "scripts" / "bnk-line-fields.json"
if LINE_FIELDS.exists():
    lf = json.loads(LINE_FIELDS.read_text())

    def line_of(name: str) -> str | None:
        if name in lf.get("2.4", []):
            return "2.4"
        if name in lf.get("2.3", []):
            return "2.3"
        # zone1_int_vlan_cidr and friends are the per-zone form of a 2.3-only base.
        # Match on a _ boundary so `ibmcloud_api_key` cannot end-match `api_key`.
        if any(name == b or name.endswith("_" + b) for b in lf.get("2.3", [])):
            return "2.3"
        return None

    for bp_path2 in sorted(ROOT.glob("blueprints/*/forge-blueprint.json")):
        d2 = load(bp_path2)
        if d2 is None:
            continue
        for group in (d2.get("inputs") or {}).values():
            if not isinstance(group, list):
                continue
            for item in group:
                nm = item.get("name")
                want = line_of(nm) if nm else None
                if want and not (item.get("description") or "").startswith(f"[BNK {want} only]"):
                    problems.append(
                        f"{bp_path2.parent.name}: input {nm!r} is {want}-only per roksbnkctl "
                        f"but its description does not say so"
                    )

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
