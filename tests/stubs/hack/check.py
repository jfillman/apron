#!/usr/bin/env python3
"""Test stub of hack/check.py (same interface): one line per violation, exit 1 on any."""
import argparse
import re
import sys
import yaml

p = argparse.ArgumentParser()
p.add_argument("--cluster", required=True)
p.add_argument("--fleet")
p.add_argument("--apron-root")
a = p.parse_args()
c = yaml.safe_load(open(a.cluster))
g = lambda path: __import__("functools").reduce(lambda d, k: (d or {}).get(k), path.split("."), c)
bad = []
name = str(c.get("name", ""))
if not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", name):
    bad.append(f"name: {name!r} is not a DNS-1123 label")
if c.get("profile") not in ("dev", "prod"):
    bad.append("profile: must be dev or prod")
if not g("scm.owner"):
    bad.append("scm.owner: required")
if c.get("profile") == "prod" and not (g("fleet.hub") and g("fleet.repoURL")):
    bad.append("fleet.hub and fleet.repoURL: required off the control plane")
if not g("tower.cluster"):
    bad.append("tower.cluster: required while Tower access is on")
ctx = g("runtime.existing.context")
if ctx and ctx != name and not g("runtime.existing.renameContext"):
    bad.append(f"runtime.existing.context {ctx!r} is not the cluster name {name!r}")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
