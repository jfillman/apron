#!/usr/bin/env python3
"""clearance G-ARGO-2: the RENDERED templates/56-clearance-gate (CRD + admission policies) against a real
kube-apiserver (envtest binaries). The full matrix lives in clearance's providers/argocd/crd/test_admission.py; this
proves what Apron renders from clearance.gate.enforce: the Warn render warns and admits, the Deny render refuses, and
the agent account is the configured one.

    KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) python3 tests/policy/test_clearance_gate.py WARN_DIR ENFORCE_DIR

WARN_DIR / ENFORCE_DIR are rendered cluster repos (tests/run.sh renders them; the enforce one sets
agentServiceAccount clearance-system:the-agent). Without KUBEBUILDER_ASSETS it prints "skipped" and exits 0.
"""
import os
import re
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_agentrun_grants import Apiserver  # noqa: E402

ARGO = "system:serviceaccount:argocd-apps:argocd-application-controller"
H = "a" * 64


def cm(name, rendered=None):
    md = {"name": name, "namespace": "prot"}
    if rendered:
        md["annotations"] = {"clearance.hangar.io/rendered": rendered}
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": md}


WAIT = "registry.invalid/clearance-wait@sha256:" + "1" * 64


def wait_job(name, image, url, args=None, env_url=None, alias=False):
    """The Job as the plugin builds it (clearance providers/argocd/cmp/job.go), with at most one deviation."""
    spec = {"restartPolicy": "Never", "containers": [{
        "name": "w", "image": image, "args": args or ["--change", "ch-1", "--timeout", "1h0m0s"],
        "env": [{"name": "CLEARANCE_URL", "value": env_url or url},
                {"name": "CLEARANCE_TOKEN_FILE", "value": "/var/run/secrets/tokens/clearance"}]}],
        "volumes": [{"name": "t", "projected": {"sources": [{"serviceAccountToken": {"audience": "clearance", "path": "clearance"}}]}}]}
    if alias:
        spec["hostAliases"] = [{"ip": "10.9.9.9", "hostnames": ["x.invalid"]}]
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": name, "namespace": "prot", "labels": {"clearance.hangar.io/injected": "wait"},
                         "annotations": {"argocd.argoproj.io/hook": "PreSync"}},
            "spec": {"template": {"spec": spec}}}


def run(rendered, agent, deny):
    res = []
    mode = "Deny" if deny else "Warn"
    gate = Path(rendered) / "56-clearance-gate"
    url = re.search(r"value == '(http[^']+)'", (gate / "admission.yaml").read_text()).group(1)  # the pinned core URL
    with Apiserver(os.environ["KUBEBUILDER_ASSETS"]) as k:
        def need(args, doc=None, as_user=None):
            ok, out = k.kubectl(args, doc, as_user)
            if not ok:
                raise RuntimeError(f"{args}: {out}")
            return out

        def check(name, good, detail=""):
            res.append(good)
            print(("PASS " if good else "FAIL ") + f"[{mode}] {name}" + ("" if good else f"\n     {detail[:300]}"))

        need(["apply", "-f", str(gate / "clearancegrant-crd.yaml")])
        need(["wait", "--for=condition=Established", "crd/clearancegrants.clearance.hangar.io", "--timeout=60s"])
        # RBAC allows every account the checks use (the default agent name too), so only the policies can refuse.
        for who in {ARGO, agent, "system:serviceaccount:default:other",
                    "system:serviceaccount:clearance-system:clearance-argocd-agent"}:
            need(["create", "clusterrolebinding", "t-" + who.split(":")[-1], "--clusterrole=cluster-admin", "--user=" + who])
        need(["create", "-f", "-"], {"apiVersion": "v1", "kind": "Namespace",
                                     "metadata": {"name": "prot", "labels": {"clearance.hangar.io/protected": "true"}}})
        docs = [d for d in yaml.safe_load_all((gate / "admission.yaml").read_text()) if d]
        need(["apply", "-f", "-"], docs and {"apiVersion": "v1", "kind": "List", "items": docs})
        grant = {"apiVersion": "clearance.hangar.io/v1", "kind": "ClearanceGrant",
                 "metadata": {"name": "g1", "namespace": "prot", "labels": {"clearance.hangar.io/active": "true"}},
                 "spec": {"subject": {"tree": "d" * 64}, "expiresAt": "2099-01-01T00:00:00Z",
                          "objects": {"/ConfigMap/ok": {"rendered": H}}}}
        for _ in range(60):  # the policy controller needs a moment; the first writer-refusal shows it is live
            ok, out = k.kubectl(["create", "-f", "-"], grant, "system:serviceaccount:default:other")
            if ("only the Clearance grant-sync agent" in out) or (ok and "Warning:" in out):
                break
            if ok:
                k.kubectl(["delete", "clearancegrant", "g1", "-n", "prot"])
            time.sleep(1)
        else:
            raise RuntimeError("policies never took effect: " + out)
        k.kubectl(["delete", "clearancegrant", "g1", "-n", "prot", "--ignore-not-found"])
        time.sleep(2)
        check("the configured agent account creates the grant", k.kubectl(["create", "-f", "-"], grant, agent)[0])
        ok, out = k.kubectl(["patch", "clearancegrant", "g1", "-n", "prot", "--subresource=status", "--type=merge", "-p",
                             '{"status":{"valid":true}}'], as_user="system:serviceaccount:default:other")  # always sent
        if deny:
            check("a non-agent account cannot write grant status", not ok and "only the Clearance grant-sync agent" in out, out)
        else:
            check("a non-agent grant-status write is admitted with the policy warning",
                  ok and "clearance-grant-writer" in out and "only the Clearance grant-sync agent" in out, out)
        if deny:  # the default agent name is not the writer once agentServiceAccount is set
            ok, out = k.kubectl(["patch", "clearancegrant", "g1", "-n", "prot", "--subresource=status", "--type=merge", "-p",
                                 '{"status":{"valid":true}}'], as_user="system:serviceaccount:clearance-system:clearance-argocd-agent")
            check("the default agent account is not the writer when the account is configured (the policy, not RBAC)",
                  not ok and "clearance-grant-writer" in out and "only the Clearance grant-sync agent" in out, out)
        need(["patch", "clearancegrant", "g1", "-n", "prot", "--subresource=status", "--type=merge", "-p", '{"status":{"valid":true}}'], as_user=agent)
        ok, out = k.kubectl(["create", "-f", "-"], cm("ok", H), ARGO)
        check("a listed object at its hash is admitted without a warning", ok and "Warning" not in out, out)
        ok, out = k.kubectl(["create", "-f", "-"], cm("unlisted", H), ARGO)
        if deny:
            check("an unlisted object is refused", not ok and "does not list /ConfigMap/unlisted" in out, out)
        else:
            check("an unlisted object is admitted with a warning", ok and "does not list /ConfigMap/unlisted" in out, out)
        ok, out = k.kubectl(["create", "-f", "-"], wait_job("wait-ok", WAIT, url), ARGO)
        check("the Job exactly as the plugin builds it is admitted without a stamp", ok and "Warning" not in out, out)
        for what, job in (("another image", wait_job("wait-bad", "busybox", url)),
                          ("an extra --url arg", wait_job("wait-args", WAIT, url, args=["--change", "c", "--timeout", "1h", "--url", "http://evil"])),
                          ("CLEARANCE_URL pointed elsewhere", wait_job("wait-url", WAIT, url, env_url="http://evil.example")),
                          ("hostAliases when none is pinned", wait_job("wait-alias", WAIT, url, alias=True))):
            ok, out = k.kubectl(["create", "-f", "-"], job, ARGO)
            check(f"a labelled Job with {what} is " + ("refused" if deny else "warned"),
                  (not ok and "clearance-protected-writes" in out) if deny else (ok and "Warning" in out), out)
        ok, out = k.kubectl(["create", "-f", "-"], cm("by-other"), "system:serviceaccount:default:other")
        check("another writer is not matched", ok and "Warning" not in out, out)
        k.kubectl(["delete", "clearancegrant", "g1", "-n", "prot"])
        ok, out = k.kubectl(["create", "-f", "-"], cm("ok2", H), ARGO)
        check("no active grant: " + ("refused" if deny else "admitted"), ok == (not deny), out)
    return res


def main():
    if not os.environ.get("KUBEBUILDER_ASSETS"):
        print("skipped: KUBEBUILDER_ASSETS is not set (setup-envtest use 1.36.2 -p path)")
        return 0
    warn_dir, enforce_dir = sys.argv[1], sys.argv[2]
    res = run(warn_dir, "system:serviceaccount:clearance-system:clearance-argocd-agent", False)
    res += run(enforce_dir, "system:serviceaccount:clearance-system:the-agent", True)
    print(f"{sum(res)}/{len(res)} checks passed")
    return 0 if all(res) else 1


if __name__ == "__main__":
    sys.exit(main())
