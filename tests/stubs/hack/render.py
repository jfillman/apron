#!/usr/bin/env python3
"""Test stub of hack/render.py (same interface and --print-values shape as the real one on apron-up)."""
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
p.add_argument("--no-check", action="store_true")
a = p.parse_args()
c = yaml.safe_load(open(a.cluster))
name, profile, rtype = c["name"], c["profile"], c["runtime"]["type"]
dev = profile == "dev"
owner = c["scm"]["owner"]
domain = c.get("domain") or f"{name}.local"
rt = {"type": rtype, "nodeExec": {"kiac": "container exec -i", "kind": "docker exec -i"}.get(rtype, ""),
      "kiac": {}, "kind": {}, "existing": c["runtime"].get("existing") or {}}
if rtype == "kiac":
    rt["kiac"] = {"cni": "cilium", "cpMemory": "32G", "cpus": 10, "kernel": "full", "workers": 0}
if rtype == "kind":
    rt["kind"] = {"config": "hack/kind-config.yaml"}
sec = [{"namespace": "argocd", "name": f"argocd-repo-creds-{owner}", "why": "repo access",
        "create": f"kubectl --context {name} -n argocd create secret generic argocd-repo-creds-{owner} --from-literal=password=<value>"}]
if dev:
    sec += [{"namespace": "infisical", "name": n, "why": "Infisical",
             "create": f"kubectl --context {name} -n infisical create secret generic {n} --from-literal=K=<value>"}
            for n in ("infisical-secrets", "infisical-bootstrap-credentials")]
else:
    sec += [{"namespace": "crossplane-system", "name": "provider-infisical-creds", "why": "provider",
             "create": f"kubectl --context {name} -n crossplane-system create secret generic provider-infisical-creds --from-file=credentials=<path>"}]
v = {
    "name": name, "profile": profile, "context": name, "runtime": rt,
    "zone": "lower" if dev else "upper",
    "roles": ["control-plane", "workloads"] if dev else ["workloads", "platform-services"],
    "domain": domain, "issuerBase": "issuer.example.test", "issuer": f"https://issuer.example.test/oidc/{name}",
    "repoURL": c.get("repoURL"), "tenantsRepo": c.get("tenantsRepo") or c["repoURL"].rsplit("/", 1)[-1].removesuffix(".git") + "-tenants",
    "scm": c.get("scm"), "registry": c.get("registry") or {"owner": owner},
    "infisical": {"host": dev, "url": "http://infisical.example.test/api"},
    "cni": {"name": "calico", "version": "v3.29.1", "manifest": "https://cni.example.test/calico.yaml"} if rtype == "kind" else None,
    "argocd": {"platform": {"install": "01-argocd-platform/install.yaml"}},
    "rootApp": "root-app-of-apps.yaml", "bootstrapSecrets": sec,
    "hostnames": [f"argocd.{domain}", f"argocd-apps.{domain}"],
}
if a.print_values:
    json.dump(v, sys.stdout)
    sys.exit(0)
out = a.out or os.path.dirname(a.cluster)
files = {"01-argocd-platform/install.yaml": "# argocd\n", "root-app-of-apps.yaml": f"# root for {name}\n"}
if rtype == "kind":
    files["hack/kind-config.yaml"] = f"kind: Cluster\nname: {name}\n"
for rel, body in files.items():
    path = os.path.join(out, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(body)
