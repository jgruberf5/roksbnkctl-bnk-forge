#!/usr/bin/env python3
"""Structural checks across every blueprint in this repo.

These are the mistakes that survive a JSON parse and only surface as a failed
deploy, sometimes an expensive one:

  * a module consuming ${x} the blueprint never declares
  * a depends_on naming a module that isn't in the blueprint
  * a pinned module version that doesn't match the pack on disk
  * a module whose OWN pack marks an input required that the blueprint never
    routes to it
  * a pack category outside the set Forge accepts (it rejects the module at
    sync time, which then invalidates every blueprint referencing it)
  * an input missing any of name/type/description/source, an invalid source, or
    a source="module" input without from_module/from_output — Forge rejects the
    whole pack for any of these, mirroring _validate_input() in its
    module_metadata.py

The last one cost a full debugging session: cwc-guard's pack was copied from
bnk-install and demanded prefix/cluster_name/existing_transit_gateway, which the
blueprint never sent it. Forge validates each module against its own pack and
reported the BLUEPRINT's variable names as missing, so the error pointed
everywhere except the module at fault, and every disconnected deploy was broken
until someone read the pack.

Exits non-zero on the first blueprint with problems. Run before syncing.
"""
import json
import glob
import os
import re
import sys


# Enforced by Forge at sync time; a bad value rejects the module and cascades
# into "N invalid" for every blueprint that references it.
CATEGORIES = {"infra", "k8s", "bnk", "app", "other"}
SOURCES = {"user", "module", "auto"}


def main() -> int:
    bad = 0
    for f in sorted(glob.glob("blueprints/*/forge-blueprint.json")):
        d = json.load(open(f))
        name = f.split("/")[1]
        declared = {x["name"] for x in d["inputs"].get("required", []) + d["inputs"].get("optional", [])}
        ids = {m["id"] for m in d["modules"]}
        probs = []
        # Blueprint inputs have the same requirement as pack inputs, and Forge
        # reports it as inputs.optional.<n>.description — a positional path that
        # tells you nothing about WHICH input, so catch it here by name.
        for grp in ("required", "optional"):
            for x in d["inputs"].get(grp, []):
                if not x.get("description"):
                    probs.append(f"blueprint input {x.get('name', '?')!r} has no description")
        for m in d["modules"]:
            for k, v in (m.get("inputs") or {}).items():
                for ref in re.findall(r"\$\{([^}]+)\}", v if isinstance(v, str) else ""):
                    if ref not in declared:
                        probs.append(f"{m['id']}.{k} -> ${{{ref}}} is not a declared blueprint input")
            for dep in m.get("depends_on", []):
                if dep not in ids:
                    probs.append(f"{m['id']} depends_on unknown module '{dep}'")
            pack = f"{m['module']}/bnkforge.pack.json"
            if not os.path.exists(pack):
                probs.append(f"{m['id']} -> no pack at {pack}")
                continue
            p = json.load(open(pack))
            cat = p["module"].get("category")
            if cat not in CATEGORIES:
                probs.append(f"{m['id']} pack category {cat!r} not in {sorted(CATEGORIES)}")
            for grp in ("required", "optional"):
                for x in p["inputs"].get(grp, []):
                    for field in ("name", "type", "description", "source"):
                        if not x.get(field):
                            probs.append(f"{m['id']} input {x.get('name', '?')!r} missing {field!r}")
                    if x.get("source") and x["source"] not in SOURCES:
                        probs.append(f"{m['id']} input {x.get('name')!r} source {x['source']!r} not in {sorted(SOURCES)}")
                    if x.get("source") == "module":
                        for field in ("from_module", "from_output"):
                            if field not in x:
                                probs.append(f"{m['id']} input {x.get('name')!r} is source=module without {field!r}")
            if p["module"]["version"] != m.get("version"):
                probs.append(f"{m['id']} pinned {m.get('version')} but pack on disk is {p['module']['version']}")
            missing = {x["name"] for x in p["inputs"].get("required", [])} - set((m.get("inputs") or {}).keys())
            if missing:
                probs.append(f"{m['id']} does not route its own required inputs: {sorted(missing)}")
        print(("OK   " if not probs else "BAD  ") + name)
        for p in probs:
            print("     " + p)
        bad += len(probs)
    print(f"-- {bad} problem(s) --")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
