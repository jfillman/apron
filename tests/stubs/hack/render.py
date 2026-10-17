#!/usr/bin/env python3
"""Test stub of the real hack/render.py (same interface). Renders a token tree; --print-values prints JSON."""
import argparse
import json
import os
import sys
import yaml

p = argparse.ArgumentParser()
p.add_argument("--cluster", required=True)
p.add_argument("--out")
p.add_argument("--apron-root")
p.add_argument("--print-values", action="store_true")
a = p.parse_args()
c = yaml.safe_load(open(a.cluster))
name, profile, runtime = c["name"], c["profile"], c["runtime"]
rt = {"type": runtime}
if runtime == "kiac":
    rt["kiac"] = {"cpus": 4, "cpMemory": "16G", "workers": 0, "cni": "cilium", "kernel": "full"}
if runtime == "kind":
    rt["kind"] = {"config": "hack/kind-config.yaml"}
v = {
    "name": name, "profile": profile, "runtime": rt, "context": name,
    "zone": "lower" if profile == "dev" else "upper",
    "roles": ["control-plane", "workloads"] if profile == "dev" else ["workloads", "platform-services"],
    "domain": c.get("domain") or f"{name}.local",
    "repoURL": c.get("repoURL"), "tenantsRepo": c.get("tenantsRepo"),
    "scm": c.get("scm") or {}, "registry": c.get("registry") or {},
    "traefik": {"serviceType": "NodePort" if runtime != "existing" else "LoadBalancer"},
    "components": {}, "infisical": {"host": profile == "dev", "url": "http://infisical.example/api"},
    "issuerBase": "issuer.example.test",
}
if runtime == "kind":
    v["cni"] = {"manifest": "https://cni.example.test/calico.yaml"}
if a.print_values:
    json.dump(v, sys.stdout)
    sys.exit(0)
out = a.out or sys.exit("--out required")
for rel, body in {
    "01-argocd-platform/install.yaml": "# argocd\n",
    "root-app-of-apps.yaml": f"# root for {name}\n",
    "hack/kind-config.yaml": f"kind: Cluster\nname: {name}\n",
}.items():
    if rel.startswith("hack/kind") and runtime != "kind":
        continue
    path = os.path.join(out, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(body)
