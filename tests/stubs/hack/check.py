#!/usr/bin/env python3
"""Test stub of the real hack/check.py (same interface): one line per violation, exit 1 on any."""
import argparse
import re
import sys
import yaml

p = argparse.ArgumentParser()
p.add_argument("--cluster", required=True)
p.add_argument("--fleet")
a = p.parse_args()
c = yaml.safe_load(open(a.cluster))
bad = []
if not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", str(c.get("name", ""))):
    bad.append(f"name: {c.get('name')!r} is not a DNS-1123 label")
if c.get("profile") not in ("dev", "prod"):
    bad.append("profile: must be dev or prod")
if not (c.get("scm") or {}).get("owner"):
    bad.append("scm.owner: required")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
