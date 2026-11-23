#!/usr/bin/env python3
"""The tenant-onboarding delete guard (tenantOnboarding.deleteGuard, W-46 (d);
templates/02-argocd-apps/tenant-onboarding/chart/templates/delete-guard.yaml) against a real kube-apiserver (envtest).

    KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) python3 tests/policy/test_tenant_delete_guard.py DENY_RENDER AUDIT_RENDER

DENY_RENDER and AUDIT_RENDER are apron renders with tenantOnboarding.deleteGuard enabled, validationActions Deny and Audit.
It installs an Application CRD stand-in, the rendered policy and binding, and Applications in argocd-apps with different
owners, then deletes them as argocd-apps' ApplicationSet controller (by impersonation, with the delete right it has on a
cluster) and as others:

  denied    the controller's delete of an Application tenant-onboarding or tenant-onboarding-gated controls
  allowed   the same delete by another ServiceAccount and by an admin; the controller's delete of an Application another
            ApplicationSet controls, of one whose tenant-onboarding reference is not the controller (controller: false, or no
            controller field), of one with no ownerReferences, of one whose controller is not an ApplicationSet, and of a
            tenant-onboarding Application in another namespace; the controller's update of a tenant Application
  audit     with validationActions Audit the controller's delete of a tenant Application is admitted

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
from test_agentrun_grants import Apiserver  # noqa: E402

GUARD = Path("02-argocd-apps/tenant-onboarding/chart/templates/delete-guard.yaml")
CONTROLLER = "system:serviceaccount:argocd-apps:argocd-applicationset-controller"
OTHER = "system:serviceaccount:argocd-apps:argocd-application-controller"
CRD = {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
       "metadata": {"name": "applications.argoproj.io"},
       "spec": {"group": "argoproj.io", "scope": "Namespaced",
                "names": {"kind": "Application", "plural": "applications", "singular": "application"},
                "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                              "schema": {"openAPIV3Schema": {"type": "object", "x-kubernetes-preserve-unknown-fields": True}}}]}}
RBAC = [
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "apps-rw"},
     "rules": [{"apiGroups": ["argoproj.io"], "resources": ["applications"], "verbs": ["get", "list", "patch", "update", "delete"]}]},
] + [
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "apps-rw", "namespace": n},
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "apps-rw"},
     "subjects": [{"kind": "ServiceAccount", "name": u.rsplit(":", 1)[1], "namespace": "argocd-apps"} for u in (CONTROLLER, OTHER)]}
    for n in ("argocd-apps", "argocd")]


def ref(name, kind="ApplicationSet", api="argoproj.io/v1alpha1", controller=True):
    r = {"apiVersion": api, "kind": kind, "name": name, "uid": "11111111-2222-3333-4444-555555555555"}
    if controller is not None:
        r["controller"] = controller
    return r


def app(name, owners, ns="argocd-apps"):
    md = {"name": name, "namespace": ns}
    if owners is not None:
        md["ownerReferences"] = owners
    return {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": md,
            "spec": {"project": "shop", "source": {"repoURL": "https://example.test/a", "path": "x"},
                     "destination": {"server": "https://kubernetes.default.svc", "namespace": "app-shop-dev"}}}


def main():
    assets = os.environ.get("KUBEBUILDER_ASSETS")
    if not assets or not (Path(assets) / "kube-apiserver").exists():
        if os.environ.get("APRON_REQUIRE_ENVTEST") == "1":  # CI: a skip is not a pass
            print("FAIL: APRON_REQUIRE_ENVTEST=1 but KUBEBUILDER_ASSETS has no kube-apiserver")
            return 1
        print("skipped: set KUBEBUILDER_ASSETS to envtest binaries (setup-envtest use 1.36.2 -p path)")
        return 0
    deny, audit = (Path(a) / GUARD for a in sys.argv[1:3])
    for p, want in ((deny, "[Deny]"), (audit, "[Audit]")):
        b = [d for d in yaml.safe_load_all(p.read_text()) if d and d["kind"] == "ValidatingAdmissionPolicyBinding"]
        if len(b) != 1 or f"[{', '.join(b[0]['spec']['validationActions'])}]" != want:
            print(f"FAIL: {p}: want one binding with validationActions {want}")
            return 1
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

        def delete(name, who, ns="argocd-apps"):
            return k.kubectl(["delete", "application", name, "-n", ns, "--wait=false"], as_user=who)

        def in_force(mode):
            # A server-side dry run of the controller's delete of a tenant Application: refused once Deny applies,
            # admitted once Audit replaced it. Polled, so a slow admission informer is not a failure.
            for _ in range(60):
                ok, out = k.kubectl(["delete", "application", "probe", "-n", "argocd-apps", "--dry-run=server"], as_user=CONTROLLER)
                if (mode == "Deny" and not ok and "may not delete" in out) or (mode == "Audit" and ok):
                    return
                time.sleep(1)
            raise RuntimeError(f"the {mode} binding did not take effect in 60s: {out}")

        def gone(name, ns="argocd-apps"):
            ok, out = k.kubectl(["get", "application", name, "-n", ns])
            return (not ok and "NotFound" in out, out)

        setup(["apply", "-f", "-"], CRD)
        setup(["wait", "--for=condition=Established", "crd/applications.argoproj.io", "--timeout=60s"])
        for n in ("argocd", "argocd-apps"):
            setup(["create", "ns", n])
        setup(["apply", "-f", "-"], RBAC)
        setup(["apply", "-f", str(deny)])
        apps = {
            "tenant-1": [ref("tenant-onboarding")], "tenant-2": [ref("tenant-onboarding")], "tenant-3": [ref("tenant-onboarding")],
            "gated-1": [ref("tenant-onboarding-gated")],
            "other-set": [ref("pr-envs")],
            "not-controller": [ref("tenant-onboarding", controller=False)],
            "no-controller-field": [ref("tenant-onboarding", controller=None)],
            "no-owners": None,
            "empty-owners": [],
            "owned-by-a-deployment": [ref("tenant-onboarding", kind="Deployment", api="apps/v1")],
            "two-owners": [ref("pr-envs", controller=False), ref("tenant-onboarding-gated")],
            "audit-1": [ref("tenant-onboarding")],
            "probe": [ref("tenant-onboarding")],
        }
        for name, owners in apps.items():
            setup(["create", "-f", "-"], app(name, owners))
        setup(["create", "-f", "-"], app("tenant-in-argocd", [ref("tenant-onboarding")], ns="argocd"))
        in_force("Deny")

        print("-- denied (validationActions Deny)")
        check("the controller deletes a tenant-onboarding Application", False, delete("tenant-1", CONTROLLER),
              "may not delete tenant Application tenant-1")
        check("the controller deletes a tenant-onboarding-gated Application", False, delete("gated-1", CONTROLLER),
              "may not delete tenant Application gated-1")
        check("the controller deletes a gated Application that also has a non-controller owner", False,
              delete("two-owners", CONTROLLER), "may not delete")
        check("the refused Applications are still there", True,
              (all(not gone(n)[0] for n in ("tenant-1", "gated-1", "two-owners")), "one was deleted"))
        print("-- allowed")
        check("another ServiceAccount deletes a tenant Application", True, delete("tenant-2", OTHER))
        check("an admin deletes a tenant Application (removing an environment by hand)", True,
              k.kubectl(["delete", "application", "tenant-3", "-n", "argocd-apps", "--wait=false"]))
        check("the controller updates a tenant Application (only DELETE is matched)", True,
              k.kubectl(["patch", "application", "tenant-1", "-n", "argocd-apps", "--type", "merge", "-p",
                         json.dumps({"metadata": {"labels": {"x": "y"}}})], as_user=CONTROLLER))
        for name, what in (("other-set", "another ApplicationSet controls"),
                           ("not-controller", "has tenant-onboarding as a non-controller owner"),
                           ("no-controller-field", "has a tenant-onboarding reference with no controller field"),
                           ("no-owners", "has no ownerReferences"),
                           ("empty-owners", "has an empty ownerReferences"),
                           ("owned-by-a-deployment", "is controlled by a Deployment named tenant-onboarding")):
            check(f"the controller deletes an Application that {what}", True, delete(name, CONTROLLER))
        check("the controller deletes a tenant-onboarding Application outside argocd-apps", True,
              delete("tenant-in-argocd", CONTROLLER, ns="argocd"))
        for name in ("tenant-2", "tenant-3", "other-set", "no-owners", "no-controller-field"):
            check(f"{name} is gone", True, gone(name))

        print("-- audit (validationActions Audit)")
        setup(["apply", "-f", str(audit)])
        in_force("Audit")
        check("the controller's delete of a tenant Application is admitted (recorded, not refused)", True,
              delete("audit-1", CONTROLLER))
        check("audit-1 is gone", True, gone("audit-1"))

    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
