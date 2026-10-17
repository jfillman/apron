#!/usr/bin/env python3
"""Test stub of the real hack/new_cluster.py (same interface): print a starter cluster.yaml."""
import argparse
import sys
import yaml

p = argparse.ArgumentParser()
p.add_argument("--profile", required=True, choices=["dev", "prod"])
p.add_argument("--name", required=True)
p.add_argument("--runtime", required=True, choices=["existing", "kiac", "kind"])
p.add_argument("--set", action="append", default=[])
a = p.parse_args()
doc = {"name": a.name, "profile": a.profile, "runtime": a.runtime}
for kv in a.set:
    k, v = kv.split("=", 1)
    cur = doc
    *path, last = k.split(".")
    for part in path:
        cur = cur.setdefault(part, {})
    cur[last] = v
yaml.safe_dump(doc, sys.stdout, sort_keys=False)
