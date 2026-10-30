#!/usr/bin/env python3
"""argo.sync.lower's grant (templates/55-autopilot/clearance/argo-sync.yaml) against a real kube-apiserver (envtest).

It installs an Application CRD stand-in (preserve-unknown-fields, like Argo CD's for these fields), the Role, binding,
policy and binding from argo-sync.yaml, and two Applications in argocd-apps (gate-api-dev in gate-api-lower,
gate-api-prod in gate-api), then acts as system:serviceaccount:autopilot-system:clearance by impersonation:

  allowed   the adapter's exact merge patch (operation: initiatedBy, info, sync {}) on the lower app
  denied    the same on the upper app; a second sync while one is in flight; a patch that also changes spec, a
            label, an annotation or status, or moves the app into a -lower project; a sync with a source override,
            resources or a strategy; an operation other than sync; create and delete (RBAC); any write in argocd
  control   an admin's spec change and sync on the upper app are admitted (the policy matches Clearance only)

    KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) python3 tests/policy/test_argo_sync.py

Without KUBEBUILDER_ASSETS it prints "skipped" and exits 0.
"""
import json
import os
import sys
import time
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from test_agentrun_grants import CLEARANCE, Apiserver  # noqa: E402

POLICY = HERE.parents[1] / "templates" / "55-autopilot" / "clearance" / "argo-sync.yaml"
CRD = {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
       "metadata": {"name": "applications.argoproj.io"},
       "spec": {"group": "argoproj.io", "scope": "Namespaced",
                "names": {"kind": "Application", "plural": "applications", "singular": "application"},
                "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                              "schema": {"openAPIV3Schema": {"type": "object", "x-kubernetes-preserve-unknown-fields": True}}}]}}
OP = {"initiatedBy": {"username": "clearance:coding-agent"},
      "info": [{"name": "task", "value": "t-1"}, {"name": "session", "value": "s-1"}], "sync": {}}


def app(name, project, ns="argocd-apps"):
    return {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
            "metadata": {"name": name, "namespace": ns, "labels": {"hangar.io/app": "gate-api"}},
            "spec": {"project": project, "source": {"repoURL": "https://example.test/a", "path": "x"},
                     "destination": {"server": "https://kubernetes.default.svc", "namespace": "app-gate-api-dev"}}}


def main():
    assets = os.environ.get("KUBEBUILDER_ASSETS")
    if not assets or not (Path(assets) / "kube-apiserver").exists():
        print("skipped: set KUBEBUILDER_ASSETS to envtest binaries (setup-envtest use 1.36.2 -p path)")
        return 0
    results = []
    with Apiserver(assets) as k:
        def check(name, want_ok, got, needle=None):
            ok, out = got
            passed = ok == want_ok and (needle is None or needle in out)
            results.append(passed)
            print(("ok  " if passed else "FAIL") + f"  {name}" + ("" if passed else f"\n        {out[-400:]}"))

        def setup(args, doc=None):
            ok, out = k.kubectl(args, doc)
            if not ok:
                raise RuntimeError(f"setup {' '.join(args)}: {out}")

        def patch(name, body, ns="argocd-apps", who=CLEARANCE):
            return k.kubectl(["patch", "application", name, "-n", ns, "--type", "merge", "-p", json.dumps(body)],
                             as_user=who)

        def clear(name, ns="argocd-apps"):
            setup(["patch", "application", name, "-n", ns, "--type", "json", "-p",
                   json.dumps([{"op": "remove", "path": "/operation"}])])

        setup(["apply", "-f", "-"], CRD)
        setup(["wait", "--for=condition=Established", "crd/applications.argoproj.io", "--timeout=60s"])
        for n in ("argocd", "argocd-apps", "autopilot-system"):
            setup(["create", "ns", n])
        setup(["apply", "-f", str(POLICY)])
        for d in (app("gate-api-dev", "gate-api-lower"), app("gate-api-prod", "gate-api"),
                  app("platform-dev", "x-lower", ns="argocd")):
            setup(["create", "-f", "-"], d)
        time.sleep(3)  # policy and RBAC informers settle

        print("-- allowed")
        check("the adapter's sync of a lower app", True, patch("gate-api-dev", {"operation": OP}))
        print("-- denied")
        check("a second sync while one is in flight", False, patch("gate-api-dev", {"operation": OP}), "in flight")
        clear("gate-api-dev")
        check("a sync of an upper app", False, patch("gate-api-prod", {"operation": OP}), "-lower project")
        check("moving an upper app into a -lower project", False,
              patch("gate-api-prod", {"spec": {"project": "gate-api-lower"}, "operation": OP}), "-lower project")
        for what, extra, needle in (
                ("a spec change", {"spec": {"source": {"path": "evil"}}}, "spec"),
                ("a label change", {"metadata": {"labels": {"hangar.io/app": "other"}}}, "labels"),
                ("an annotation", {"metadata": {"annotations": {"a": "b"}}}, "annotations"),
                ("a status write", {"status": {"sync": {"status": "Synced"}}}, "status")):
            check(f"a sync that also makes {what}", False, patch("gate-api-dev", {**extra, "operation": OP}), needle)
        for what, sync in (("a source override", {"source": {"repoURL": "https://evil.test/x", "path": "y"}}),
                           ("named resources", {"resources": [{"kind": "Secret", "name": "x"}]}),
                           ("a strategy", {"syncStrategy": {"apply": {"force": True}}})):
            check(f"a sync with {what}", False, patch("gate-api-dev", {"operation": {**OP, "sync": sync}}), "own source")
        check("an operation that is not a sync", False,
              patch("gate-api-dev", {"operation": {"initiatedBy": {"username": "x"}}}), "own source")
        check("a write in argocd (RBAC)", False, patch("platform-dev", {"operation": OP}, ns="argocd"), "forbidden")
        check("create (RBAC)", False, k.kubectl(["create", "-f", "-"], app("new-dev", "gate-api-lower"), CLEARANCE),
              "forbidden")
        check("delete (RBAC)", False, k.kubectl(["delete", "application", "gate-api-dev", "-n", "argocd-apps"],
                                                as_user=CLEARANCE), "forbidden")
        print("-- control")
        check("an admin syncs and edits the upper app", True,
              k.kubectl(["patch", "application", "gate-api-prod", "-n", "argocd-apps", "--type", "merge", "-p",
                         json.dumps({"spec": {"source": {"path": "y"}}, "operation": OP})]))
        ok, out = k.kubectl(["get", "application", "gate-api-dev", "-n", "argocd-apps", "-o", "yaml"])
        doc = yaml.safe_load(out) if ok else {}
        check("the denied patches left the lower app as it was", True,
              (doc.get("spec", {}).get("source", {}).get("path") == "x" and "operation" not in doc
               and doc["metadata"].get("labels") == {"hangar.io/app": "gate-api"}, out))

    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
