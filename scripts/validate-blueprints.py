#!/usr/bin/env python3
"""Structural checks across every blueprint in this repo.

These are the mistakes that survive a JSON parse and only surface as a failed
deploy, sometimes an expensive one:

  * a module consuming ${x} the blueprint never declares
  * a depends_on naming a module that isn't in the blueprint
  * a pinned module version that doesn't match the pack on disk
  * a module whose OWN pack marks an input required that the blueprint never
    routes to it

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


def main() -> int:
    bad = 0
    for f in sorted(glob.glob("blueprints/*/forge-blueprint.json")):
        d = json.load(open(f))
        name = f.split("/")[1]
        declared = {x["name"] for x in d["inputs"].get("required", []) + d["inputs"].get("optional", [])}
        ids = {m["id"] for m in d["modules"]}
        probs = []
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
