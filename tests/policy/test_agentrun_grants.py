#!/usr/bin/env python3
"""D15 (d): provider-kubernetes's AgentRun grant is confined by its ValidatingAdmissionPolicy, proven against a real
kube-apiserver (envtest binaries: etcd + kube-apiserver, no cluster, no network).

It starts a throwaway etcd and kube-apiserver (RBAC on), installs exactly templates/55-autopilot/agentrun-grants/
(the ClusterRole + binding, the policy + binding, Clearance's Role) and a Sandbox CRD, then acts as
system:serviceaccount:crossplane-system:provider-kubernetes by impersonation:

  allowed   every object function-agentrun renders for a run (fixtures/agentrun-objects.yaml), an update, the deletes
  denied    a Job in default (RBAC: the role has no jobs), a Sandbox in default, a label patch on kube-system, a
            pod-security label change on an agent-r-* namespace, a namespace outside agent-r-*, one without the run
            label, one with the PR-sweep label, one created privileged, a NetworkPolicy/ResourceQuota/ServiceAccount
            outside a run namespace, a ServiceAccount other than run, a Sandbox not running as run, deleting an app
            namespace
  control   the same Sandbox in default created by an admin is admitted (the policy matches the provider only), and
            Clearance can create/patch agentruns in autopilot-runs and nothing elsewhere

    KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) python3 tests/policy/test_agentrun_grants.py [--sandbox-crd CRD.yaml]

Without KUBEBUILDER_ASSETS it prints "skipped" and exits 0 (tests/run.sh calls it that way).
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
APRON = HERE.parents[1]
GRANTS = APRON / "templates" / "55-autopilot" / "agentrun-grants"
PROVIDER = "system:serviceaccount:crossplane-system:provider-kubernetes"
CLEARANCE = "system:serviceaccount:platform-system:clearance"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Apiserver:
    def __init__(self, assets):
        self.assets = Path(assets)
        self.dir = Path(tempfile.mkdtemp(prefix="apron-vap-"))
        self.procs = []

    def __enter__(self):
        d = self.dir
        subprocess.run(["openssl", "genrsa", "-out", d / "sa.key", "2048"], check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", d / "sa.key", "-pubout", "-out", d / "sa.pub"], check=True, capture_output=True)
        (d / "tokens.csv").write_text("admintoken,admin,admin,system:masters\n")
        ec, ep, ap = free_port(), free_port(), free_port()
        log = open(d / "etcd.log", "w")
        self.procs.append(subprocess.Popen([self.assets / "etcd", "--data-dir", d / "etcd",
                                            "--listen-client-urls", f"http://127.0.0.1:{ec}",
                                            "--advertise-client-urls", f"http://127.0.0.1:{ec}",
                                            "--listen-peer-urls", f"http://127.0.0.1:{ep}"], stdout=log, stderr=log))
        log = open(d / "apiserver.log", "w")
        self.procs.append(subprocess.Popen([self.assets / "kube-apiserver", "--etcd-servers", f"http://127.0.0.1:{ec}",
                                            "--cert-dir", d / "certs", "--secure-port", str(ap), "--bind-address", "127.0.0.1",
                                            "--service-account-issuer", "https://apron-vap.test",
                                            "--service-account-key-file", d / "sa.pub",
                                            "--service-account-signing-key-file", d / "sa.key",
                                            "--token-auth-file", d / "tokens.csv", "--authorization-mode", "RBAC",
                                            "--service-cluster-ip-range", "10.0.0.0/24"], stdout=log, stderr=log))
        (d / "kubeconfig").write_text(yaml.safe_dump({
            "apiVersion": "v1", "kind": "Config", "current-context": "t",
            "clusters": [{"name": "t", "cluster": {"server": f"https://127.0.0.1:{ap}", "insecure-skip-tls-verify": True}}],
            "users": [{"name": "admin", "user": {"token": "admintoken"}}],
            "contexts": [{"name": "t", "context": {"cluster": "t", "user": "admin"}}]}))
        self.kubeconfig = str(d / "kubeconfig")
        for _ in range(90):
            if self.kubectl(["get", "--raw", "/readyz"])[0]:
                return self
            time.sleep(1)
        raise RuntimeError(f"kube-apiserver did not become ready; see {d}/apiserver.log")

    def __exit__(self, *exc):
        for p in reversed(self.procs):
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(self.dir, ignore_errors=True)

    def kubectl(self, args, doc=None, as_user=None):
        cmd = [shutil.which("kubectl") or "kubectl", "--kubeconfig", self.kubeconfig]
        if as_user:
            cmd += ["--as", as_user, "--as-group", "system:serviceaccounts", "--as-group", "system:authenticated"]
        r = subprocess.run(cmd + args, input=(yaml.safe_dump_all(doc) if isinstance(doc, list) else json.dumps(doc)) if doc else None,
                           capture_output=True, text=True)
        return r.returncode == 0, (r.stdout + r.stderr).strip()


def ns(name, labels=None):
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels or {}}}


RUN_LABELS = {"hangar.io/agent-run": "true", "pod-security.kubernetes.io/enforce": "restricted",
              "pod-security.kubernetes.io/enforce-version": "latest"}


def sandbox(namespace, sa="run", automount=False):
    spec = {"serviceAccountName": sa, "containers": [{"name": "agent", "image": "busybox"}]}
    if automount is not None:
        spec["automountServiceAccountToken"] = automount
    return {"apiVersion": "agents.x-k8s.io/v1beta1", "kind": "Sandbox", "metadata": {"name": "agent", "namespace": namespace},
            "spec": {"shutdownTime": "2099-01-01T00:00:00Z", "shutdownPolicy": "Delete", "podTemplate": {"spec": spec}}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sandbox-crd", default=str(HERE / "fixtures" / "sandbox-crd-stub.yaml"))
    a = ap.parse_args()
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

        setup(["apply", "-f", a.sandbox_crd])
        setup(["wait", "--for=condition=Established", "crd/sandboxes.agents.x-k8s.io", "--timeout=60s"])
        for n in ("crossplane-system", "platform-system", "autopilot-runs", "app-flight-api-dev"):
            setup(["create", "ns", n])
        # what a real cluster has and envtest (no controller-manager) does not
        setup(["label", "ns", "kube-system", "pod-security.kubernetes.io/enforce=privileged"])
        setup(["create", "sa", "default", "-n", "default"])
        # AgentRun CRD stand-in for the Clearance Role check (only its existence matters to RBAC)
        setup(["apply", "-f", "-"], {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
                                     "metadata": {"name": "agentruns.catalog.hangar.io"},
                                     "spec": {"group": "catalog.hangar.io", "scope": "Namespaced",
                                              "names": {"kind": "AgentRun", "plural": "agentruns", "singular": "agentrun"},
                                              "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                                                            "schema": {"openAPIV3Schema": {"type": "object", "x-kubernetes-preserve-unknown-fields": True}}}]}})
        for f in sorted(GRANTS.glob("*.yaml")):
            if f.name != "application.yaml":
                setup(["apply", "-f", str(f)])
        setup(["wait", "--for=condition=Established", "crd/agentruns.catalog.hangar.io", "--timeout=60s"])
        time.sleep(3)  # policy and RBAC informers settle

        P = PROVIDER
        objs = [d for d in yaml.safe_load_all((HERE / "fixtures" / "agentrun-objects.yaml").read_text()) if d]
        run_ns = objs[0]["metadata"]["name"]

        print("-- allowed: what an AgentRun renders")
        for d in objs:
            check(f"create {d['kind']} {d['metadata'].get('namespace', '')}/{d['metadata']['name']}", True,
                  k.kubectl(["create", "-f", "-"], d, P))
        check("update the run's ResourceQuota", True,
              k.kubectl(["patch", "resourcequota", "run", "-n", run_ns, "--type=merge", "-p", '{"spec":{"hard":{"pods":"3"}}}'], as_user=P))
        check("relabel the run namespace without touching pod-security", True,
              k.kubectl(["label", "ns", run_ns, "hangar.io/task=t-ffffff", "--overwrite"], as_user=P))

        print("-- denied: outside a run namespace")
        job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "x", "namespace": "default"},
               "spec": {"template": {"spec": {"restartPolicy": "Never", "containers": [{"name": "x", "image": "busybox"}]}}}}
        check("a Job in default (RBAC: the role grants no jobs)", False, k.kubectl(["create", "-f", "-"], job, P), "forbidden")
        check("a Job in the run namespace (RBAC)", False,
              k.kubectl(["create", "-f", "-"], {**job, "metadata": {"name": "x", "namespace": run_ns}}, P), "forbidden")
        check("a Sandbox in default", False, k.kubectl(["create", "-f", "-"], sandbox("default"), P), "agent-r-*")
        check("a label patch on kube-system", False,
              k.kubectl(["label", "ns", "kube-system", "owned=yes"], as_user=P), "autopilot-agentrun-provider-confinement")
        check("dropping pod-security from kube-system", False,
              k.kubectl(["label", "ns", "kube-system", "pod-security.kubernetes.io/enforce-"], as_user=P), "agent-r-*")
        check("a NetworkPolicy in default", False, k.kubectl(["create", "-f", "-"], {
            "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "x", "namespace": "default"},
            "spec": {"podSelector": {}}}, P), "agent-r-*")
        check("a ResourceQuota in kube-system", False, k.kubectl(["create", "quota", "x", "-n", "kube-system", "--hard=pods=1"], as_user=P), "agent-r-*")
        check("a ServiceAccount in default", False, k.kubectl(["create", "sa", "run", "-n", "default"], as_user=P), "agent-r-*")
        check("deleting an app namespace", False, k.kubectl(["delete", "ns", "app-flight-api-dev", "--wait=false"], as_user=P), "agent-r-*")
        check("deleting the default ServiceAccount in default", False,
              k.kubectl(["delete", "sa", "default", "-n", "default", "--wait=false"], as_user=P), "agent-r-*")

        print("-- denied: namespaces that are not run namespaces")
        check("a namespace not named agent-r-*", False, k.kubectl(["create", "-f", "-"], ns("tools", RUN_LABELS), P), "agent-r-*")
        check("an agent-r-* namespace without the run label", False,
              k.kubectl(["create", "-f", "-"], ns("agent-r-000001", {"pod-security.kubernetes.io/enforce": "restricted"}), P), "hangar.io/agent-run")
        check("an agent-r-* namespace with the PR-sweep label", False,
              k.kubectl(["create", "-f", "-"], ns("agent-r-000002", {**RUN_LABELS, "hangar.io/ephemeral-env": "true"}), P), "ephemeral-env")
        check("an agent-r-* namespace created privileged", False,
              k.kubectl(["create", "-f", "-"], ns("agent-r-000003", {**RUN_LABELS, "pod-security.kubernetes.io/enforce": "privileged"}), P), "restricted")
        check("an agent-r-* namespace with no pod-security label", False,
              k.kubectl(["create", "-f", "-"], ns("agent-r-000004", {"hangar.io/agent-run": "true"}), P), "restricted")
        check("an agent-r-* namespace with an extra pod-security label", False,
              k.kubectl(["create", "-f", "-"], ns("agent-r-000005", {**RUN_LABELS, "pod-security.kubernetes.io/warn": "privileged"}), P), "restricted")

        print("-- denied: changes to a live run namespace")
        check("changing pod-security enforce on agent-r-*", False,
              k.kubectl(["label", "ns", run_ns, "pod-security.kubernetes.io/enforce=privileged", "--overwrite"], as_user=P), "pod-security")
        check("removing pod-security enforce-version on agent-r-*", False,
              k.kubectl(["label", "ns", run_ns, "pod-security.kubernetes.io/enforce-version-"], as_user=P), "pod-security")
        check("adding pod-security audit on agent-r-*", False,
              k.kubectl(["label", "ns", run_ns, "pod-security.kubernetes.io/audit=privileged"], as_user=P), "pod-security")
        check("adding the PR-sweep label to agent-r-*", False,
              k.kubectl(["label", "ns", run_ns, "hangar.io/ephemeral-env=true"], as_user=P), "ephemeral-env")
        check("removing the run label from agent-r-*", False,
              k.kubectl(["label", "ns", run_ns, "hangar.io/agent-run-"], as_user=P), "hangar.io/agent-run")
        check("a ServiceAccount other than run", False, k.kubectl(["create", "sa", "admin", "-n", run_ns], as_user=P), "only ServiceAccount")
        k.kubectl(["delete", "sandbox", "agent", "-n", run_ns], as_user=P)
        check("a Sandbox running as another service account", False,
              k.kubectl(["create", "-f", "-"], sandbox(run_ns, sa="default"), P), "serviceAccountName run")
        check("a Sandbox that automounts a token", False,
              k.kubectl(["create", "-f", "-"], sandbox(run_ns, automount=True), P), "automountServiceAccountToken")
        check("a Sandbox that leaves automount unset", False,
              k.kubectl(["create", "-f", "-"], sandbox(run_ns, automount=None), P), "automountServiceAccountToken")
        check("a Sandbox with the deprecated serviceAccount alias set", False,
              k.kubectl(["create", "-f", "-"], {**sandbox(run_ns), "spec": {**sandbox(run_ns)["spec"], "podTemplate": {"spec": {
                  **sandbox(run_ns)["spec"]["podTemplate"]["spec"], "serviceAccount": "default"}}}}, P), "serviceAccountName run")

        print("-- controls")
        check("an admin's Sandbox in default is admitted (the policy matches only the provider)", True,
              k.kubectl(["create", "-f", "-"], sandbox("default", sa="default", automount=None)))
        check("the revision-hashed provider name gets no grant (RBAC)", False,
              k.kubectl(["get", "ns"], as_user="system:serviceaccount:crossplane-system:provider-kubernetes-f6665ef36536"), "forbidden")
        run = {"apiVersion": "catalog.hangar.io/v1alpha1", "kind": "AgentRun", "metadata": {"name": "r-1a2b3c", "namespace": "autopilot-runs"}, "spec": {}}
        check("Clearance can create an AgentRun in autopilot-runs", True, k.kubectl(["create", "-f", "-"], run, CLEARANCE))
        check("Clearance can patch it (spec.frozen)", True,
              k.kubectl(["patch", "agentrun", "r-1a2b3c", "-n", "autopilot-runs", "--type=merge", "-p", '{"spec":{"frozen":true}}'], as_user=CLEARANCE))
        check("Clearance cannot create an AgentRun in default", False,
              k.kubectl(["create", "-f", "-"], {**run, "metadata": {"name": "r-1a2b3c", "namespace": "default"}}, CLEARANCE), "forbidden")
        check("Clearance cannot create a Sandbox", False, k.kubectl(["create", "-f", "-"], sandbox(run_ns), CLEARANCE), "forbidden")
        check("Clearance cannot read Secrets in autopilot-runs", False, k.kubectl(["get", "secrets", "-n", "autopilot-runs"], as_user=CLEARANCE), "forbidden")

        print("-- allowed: teardown")
        for d in reversed(objs[1:]):
            if d["kind"] == "Sandbox":
                continue
            check(f"delete {d['kind']} {d['metadata']['name']}", True,
                  k.kubectl(["delete", d["kind"].lower(), d["metadata"]["name"], "-n", run_ns, "--wait=false"], as_user=P))
        check("delete the run namespace", True, k.kubectl(["delete", "ns", run_ns, "--wait=false"], as_user=P))

    print(f"\n{sum(results)}/{len(results)} policy checks pass")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
