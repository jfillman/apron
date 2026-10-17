#!/usr/bin/env python3
"""Test stub of hack/new_cluster.py (same flags as the real one on apron-up): print a starter cluster.yaml."""
import argparse
import sys
import yaml

p = argparse.ArgumentParser()
p.add_argument("--profile", required=True, choices=["dev", "prod"])
p.add_argument("--name", required=True)
p.add_argument("--runtime", required=True, choices=["existing", "kiac", "kind"])
for f in ("repo-url", "tenants-repo", "scm-owner", "scm-host", "registry-owner", "registry-host", "domain",
          "fleet-hub", "fleet-repo-url", "tower-cluster", "context", "apron-root"):
    p.add_argument("--" + f)
p.add_argument("--set", action="append", default=[])
a = p.parse_args()
doc = {"name": a.name, "profile": a.profile, "runtime": {"type": a.runtime}}
if a.context:
    doc["runtime"]["existing"] = {"context": a.context}
for key, v in (("repoURL", a.repo_url), ("tenantsRepo", a.tenants_repo), ("domain", a.domain),
               ("scm.host", a.scm_host), ("scm.owner", a.scm_owner), ("registry.owner", a.registry_owner),
               ("fleet.hub", a.fleet_hub), ("fleet.repoURL", a.fleet_repo_url), ("tower.cluster", a.tower_cluster)):
    if v:
        a.set.append(f"{key}={v}")
for kv in a.set:
    k, v = kv.split("=", 1)
    cur = doc
    *path, last = k.split(".")
    for part in path:
        cur = cur.setdefault(part, {})
    cur[last] = {"true": True, "false": False}.get(v, v)
yaml.safe_dump(doc, sys.stdout, sort_keys=False)
