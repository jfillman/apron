#!/usr/bin/env python3
"""clearance G-ARGO-2: the RENDERED templates/56-clearance-gate (CRD + admission policies) against a real
kube-apiserver (envtest binaries). The full matrix lives in clearance's providers/argocd/crd/test_admission.py; this
proves what Apron renders from clearance.gate.enforce: the Warn render warns and admits, the Deny render refuses, and
the agent account is the configured one.

    KUBEBUILDER_ASSETS=$(setup-envtest use 1.36.2 -p path) python3 tests/policy/test_clearance_gate.py WARN_DIR ENFORCE_DIR [CA_DIR [PREV_DIR]]

WARN_DIR / ENFORCE_DIR are rendered cluster repos (tests/run.sh renders them; the enforce one sets
agentServiceAccount clearance-system:the-agent). CA_DIR is an enforcing render with clearance.gate.waitCAConfigMap
hangar-cluster-ca (I-43, A-17): the wait Job's optional CA volume is admitted exactly as the plugin builds it, and every
other volume, path, source or writable mount is refused by the policy's own message, never by a CEL error. PREV_DIR is an
enforcing render with clearance.gate.previousURL (A-19): a wait Job on the previous URL is admitted, any other URL refused. Without
KUBEBUILDER_ASSETS it prints "skipped" and exits 0; with APRON_REQUIRE_ENVTEST=1 (CI) a missing KUBEBUILDER_ASSETS fails.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_agentrun_grants import Apiserver  # noqa: E402

ARGO = "system:serviceaccount:argocd-apps:argocd-application-controller"
DEFAULT_AGENT = "system:serviceaccount:clearance-system:clearance-argocd-agent"
H = "a" * 64


def cm(name, rendered=None):
    md = {"name": name, "namespace": "prot"}
    if rendered:
        md["annotations"] = {"clearance.hangar.io/rendered": rendered}
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": md}


WAIT = "registry.invalid/clearance-wait@sha256:" + "1" * 64


def wait_job(name, image, url, args=None, env_url=None, alias=False, ctr_extra=None, pod_extra=None, drop_mount=False, drop_volume=False,
             ca=None, mutate=None):
    """The Job as the plugin builds it (clearance providers/argocd/cmp/job.go), with at most one deviation."""
    spec = {"restartPolicy": "Never", "automountServiceAccountToken": False,
            "securityContext": {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532,
                                "seccompProfile": {"type": "RuntimeDefault"}}, "containers": [{
        "name": "w", "image": image, "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                                         "capabilities": {"drop": ["ALL"]}}, "args": args or ["--change", "ch-1", "--timeout", "1h0m0s"],
        "env": [{"name": "CLEARANCE_URL", "value": env_url or url},
                {"name": "CLEARANCE_TOKEN_FILE", "value": "/var/run/secrets/tokens/clearance"}],
        "volumeMounts": [{"name": "clearance-token", "mountPath": "/var/run/secrets/tokens", "readOnly": True}]}],
        "volumes": [{"name": "clearance-token", "projected": {"sources": [{"serviceAccountToken": {"audience": "clearance", "path": "clearance"}}]}}]}
    spec["containers"][0].update(ctr_extra or {})
    spec.update(pod_extra or {})
    for k in (drop_mount and ["volumeMounts"] or []):
        del spec["containers"][0][k]
    if drop_volume:
        del spec["volumes"]
    if alias:
        spec["hostAliases"] = [{"ip": "10.9.9.9", "hostnames": ["x.invalid"]}]
    if ca:  # cmp/job.go with CLEARANCE_WAIT_CA_CONFIGMAP set: the CA mount and volume after the token's
        spec["containers"][0]["volumeMounts"].append({"name": "clearance-ca", "mountPath": "/etc/clearance-ca", "readOnly": True})
        spec["volumes"].append({"name": "clearance-ca", "configMap": {"name": ca, "items": [{"key": "ca.crt", "path": "ca.crt"}]}})
    if mutate:
        mutate(spec)
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": name, "namespace": "prot", "labels": {"clearance.hangar.io/injected": "wait"},
                         "annotations": {"argocd.argoproj.io/hook": "PreSync"}},
            "spec": {"template": {"spec": spec}}}


def run(rendered, agent, deny, ca=None, prev=None):
    res = []
    mode = ("Deny" if deny else "Warn") + (" +CA" if ca else "") + (" +previousURL" if prev else "")
    gate = Path(rendered) / "56-clearance-gate"
    # the pinned core URL: `value == '<url>'`, or the first of `value in ['<url>', '<previousURL>']`
    url = re.search(r"env\[0\]\.value (?:== |in \[)'(http[^']+)'", (gate / "admission.yaml").read_text()).group(1)
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
        if deny and agent != DEFAULT_AGENT:  # the default agent name is not the writer once agentServiceAccount is set
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
                          ("hostAliases when none is pinned", wait_job("wait-alias", WAIT, url, alias=True)),
                          ("a livenessProbe", wait_job("wait-probe", WAIT, url, ctr_extra={"livenessProbe": {"exec": {"command": ["true"]}}})),
                          ("a serviceAccountName", wait_job("wait-sa", WAIT, url, pod_extra={"serviceAccountName": "default"})),
                          ("runAsUser 0", wait_job("wait-root", WAIT, url, pod_extra={"securityContext": {"runAsNonRoot": False, "runAsUser": 0, "runAsGroup": 65532,
                                                                                         "seccompProfile": {"type": "RuntimeDefault"}}})),
                          ("seccomp Unconfined", wait_job("wait-seccomp", WAIT, url, pod_extra={"securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                                                          "runAsGroup": 65532, "seccompProfile": {"type": "Unconfined"}}})),
                          ("no volumeMounts", wait_job("wait-nomount", WAIT, url, drop_mount=True)),
                          ("neither the mount nor the volume", wait_job("wait-neither", WAIT, url, drop_mount=True, drop_volume=True)),
                          ("a dnsConfig", wait_job("wait-dns", WAIT, url, pod_extra={"dnsConfig": {"nameservers": ["10.9.9.9"]}})),
                          # With no clearance.gate.waitCAConfigMap the policy is unchanged: the CA volume is one volume too many.
                          *([] if ca else [("the CA volume when no CA is configured", wait_job("wait-ca-off", WAIT, url, ca="hangar-cluster-ca"))])):
            ok, out = k.kubectl(["create", "-f", "-"], job, ARGO)
            check(f"a labelled Job with {what} is " + ("refused" if deny else "warned"),
                  (not ok and "clearance-protected-writes" in out) if deny else (ok and "Warning" in out), out)
        if ca:
            ca_checks(k, check, url, ca, agent)
        if prev:
            # clearance.gate.previousURL (A-19): the previous core URL is admitted beside the current one, and nothing else is.
            ok, out = k.kubectl(["create", "-f", "-"], wait_job("wait-prev", WAIT, url, env_url=prev), ARGO)
            check("a wait Job on the previous URL is admitted without a stamp", ok and "Warning" not in out, out)
            for i, (what, other) in enumerate((("a third URL", "http://clearance-core.clearance-system.svc:9090"),
                                               ("the previous URL with a path", prev + "/x"),
                                               ("the previous URL as a prefix", prev + "x.invalid"))):
                ok, out = k.kubectl(["create", "-f", "-"], wait_job(f"wait-prev-bad{i}", WAIT, url, env_url=other), ARGO)
                # refused by the policy's own message (the Job is not exempt, so it needs a stamp), never by a CEL error
                check(f"a wait Job on {what} is refused", not ok and "clearance-protected-writes" in out
                      and "no clearance.hangar.io/rendered annotation on batch/Job/" in out, out)
        ok, out = k.kubectl(["create", "-f", "-"], cm("by-other"), "system:serviceaccount:default:other")
        check("another writer is not matched", ok and "Warning" not in out, out)
        k.kubectl(["delete", "clearancegrant", "g1", "-n", "prot"])
        ok, out = k.kubectl(["create", "-f", "-"], cm("ok2", H), ARGO)
        check("no active grant: " + ("refused" if deny else "admitted"), ok == (not deny), out)
    return res


def ca_checks(k, check, url, ca, agent):
    """clearance.gate.waitCAConfigMap on (Deny): the plugin's CA volume and mount are admitted exactly; every deviation is
    refused, and by the policy's own message (the exemption evaluated to false), not by a CEL evaluation error."""
    n = [0]

    def create(job_name, **kw):
        n[0] += 1
        return k.kubectl(["create", "-f", "-"], wait_job(f"{job_name}-{n[0]}", WAIT, url, **kw), ARGO)

    def caf(spec):  # the CA volume and mount of a spec built with ca=
        return spec["volumes"][1], spec["containers"][0]["volumeMounts"][1]

    def setv(**kv):
        return lambda spec: caf(spec)[0].update(kv)

    def setcm(**kv):
        return lambda spec: caf(spec)[0]["configMap"].update(kv)

    def setm(**kv):
        return lambda spec: caf(spec)[1].update(kv)

    def delm(key):
        return lambda spec: caf(spec)[1].pop(key)

    def swap(spec):
        spec["volumes"].reverse()
        spec["containers"][0]["volumeMounts"].reverse()

    def mounts_only(spec):
        del spec["volumes"][1]

    def volumes_only(spec):
        del spec["containers"][0]["volumeMounts"][1]

    def third(spec):
        spec["volumes"].append({"name": "extra", "emptyDir": {}})
        spec["containers"][0]["volumeMounts"].append({"name": "extra", "mountPath": "/extra", "readOnly": True})

    def token_twice(spec):  # the token volume mounted a second time where the CA goes
        caf(spec)[1]["name"] = "clearance-token"
        del spec["volumes"][1]
        spec["volumes"].append({"name": "clearance-ca", "configMap": {"name": ca, "items": [{"key": "ca.crt", "path": "ca.crt"}]}})

    def replace_vol(src):
        def f(spec):
            spec["volumes"][1] = {"name": "clearance-ca", **src}
        return f

    for what, kw in (("the CA volume and mount exactly as the plugin builds them", {"ca": ca}),
                     ("the CA volume with the API server's defaultMode 420 spelled out", {"ca": ca, "mutate": setcm(defaultMode=420)}),
                     ("no CA at all (the plugin before its CA is configured)", {})):
        ok, out = create("wait-ca-ok", **kw)
        check(f"a wait Job with {what} is admitted", ok and "Warning" not in out, out)
    refused = (
        ("the CA mount writable (readOnly false)", setm(readOnly=False)),
        ("the CA mount with no readOnly", delm("readOnly")),
        ("the CA mount at /etc/ssl/certs", setm(mountPath="/etc/ssl/certs")),
        ("the CA mount at /etc/clearance-ca/ (another spelling)", setm(mountPath="/etc/clearance-ca/")),
        ("the CA mount with a subPath", setm(subPath="ca.crt")),
        ("the CA mount with mountPropagation", setm(mountPropagation="HostToContainer")),
        ("the CA mount with recursiveReadOnly", setm(recursiveReadOnly="Enabled")),
        ("the CA mount under another name", lambda spec: (setm(name="other")(spec), setv(name="other")(spec))),
        ("another ConfigMap", setcm(name="evil-ca")),
        ("a ConfigMap volume of the whole ConfigMap (no items)", lambda spec: caf(spec)[0]["configMap"].pop("items")),
        ("the item tls.key", setcm(items=[{"key": "tls.key", "path": "ca.crt"}])),
        ("the item at another path", setcm(items=[{"key": "ca.crt", "path": "other.crt"}])),
        ("two items", setcm(items=[{"key": "ca.crt", "path": "ca.crt"}, {"key": "tls.crt", "path": "tls.crt"}])),
        ("an item with a mode", setcm(items=[{"key": "ca.crt", "path": "ca.crt", "mode": 511}])),
        ("defaultMode 0777", setcm(defaultMode=511)),
        ("the ConfigMap optional", setcm(optional=True)),
        ("a Secret volume in its place", replace_vol({"secret": {"secretName": ca}})),
        ("a hostPath volume in its place", replace_vol({"hostPath": {"path": "/etc/ssl/certs"}})),
        ("a projected ConfigMap volume in its place", replace_vol({"projected": {"sources": [{"configMap": {"name": ca, "items": [{"key": "ca.crt", "path": "ca.crt"}]}}]}})),
        ("an emptyDir in its place", replace_vol({"emptyDir": {}})),
        ("the CA volume and mount before the token's", swap),
        ("the CA volume without its mount", volumes_only),
        ("the CA volume and no mounts at all", lambda spec: spec["containers"][0].pop("volumeMounts")),
        ("a third volume and mount", third),
        ("the token mounted a second time in the CA's place", token_twice),
    )
    # A mount of no volume never reaches admission: the API server's own validation refuses the pod first.
    ok, out = create("wait-ca-nomvol", ca=ca, mutate=mounts_only)
    check("a wait Job with the CA mount but no CA volume is refused", not ok and "volumemounts[1].name: not found" in out.lower(), out)
    for what, mut in refused:
        ok, out = create("wait-ca-bad", ca=ca, mutate=mut)
        if ok:
            check(f"a wait Job with {what} is refused", False, "admitted: " + out)
            continue
        # The policy refused it with its own message (exempt was false); a schema refusal of the object itself is not this test.
        by_policy = "clearance-protected-writes" in out and "no clearance.hangar.io/rendered annotation on batch/Job/" in out
        check(f"a wait Job with {what} is refused by the policy, not by a CEL error", by_policy, out)
    # The exemption only ever widens: a Job the grant lists at its hash is admitted by the grant rule whatever its shape, even
    # one that looks like a broken wait Job (a third volume, a Secret, a mount without readOnly).
    ok, out = k.kubectl(["patch", "clearancegrant", "g1", "-n", "prot", "--type=merge", "-p",
                         json.dumps({"spec": {"objects": {"batch/Job/listed-job": {"rendered": H}}}})], as_user=agent)
    if not ok:
        raise RuntimeError("grant patch: " + out)
    time.sleep(1)

    def odd(spec):
        spec["volumes"].append({"name": "s", "secret": {"secretName": "x"}})
        spec["containers"][0]["volumeMounts"].append({"name": "s", "mountPath": "/s"})
    job = wait_job("listed-job", WAIT, url, ca=ca, mutate=odd)
    job["metadata"]["annotations"]["clearance.hangar.io/rendered"] = H
    ok, out = k.kubectl(["create", "-f", "-"], job, ARGO)
    check("a listed Job shaped like a broken wait Job is admitted by its grant entry", ok and "Warning" not in out, out)


def main():
    if not os.environ.get("KUBEBUILDER_ASSETS"):
        if os.environ.get("APRON_REQUIRE_ENVTEST") == "1":
            print("FAIL: APRON_REQUIRE_ENVTEST=1 but KUBEBUILDER_ASSETS is not set")
            return 1
        print("skipped: KUBEBUILDER_ASSETS is not set (setup-envtest use 1.36.2 -p path)")
        return 0
    warn_dir, enforce_dir = sys.argv[1], sys.argv[2]
    res = run(warn_dir, "system:serviceaccount:clearance-system:clearance-argocd-agent", False)
    res += run(enforce_dir, "system:serviceaccount:clearance-system:the-agent", True)
    if len(sys.argv) > 3:
        res += run(sys.argv[3], "system:serviceaccount:clearance-system:clearance-argocd-agent", True, ca="hangar-cluster-ca")
    if len(sys.argv) > 4:
        prev = re.search(r"env\[0\]\.value in \['[^']+', '(http[^']+)'\]", (Path(sys.argv[4]) / "56-clearance-gate" / "admission.yaml").read_text()).group(1)
        res += run(sys.argv[4], "system:serviceaccount:clearance-system:clearance-argocd-agent", True, prev=prev)
    print(f"{sum(res)}/{len(res)} checks passed")
    return 0 if all(res) else 1


if __name__ == "__main__":
    sys.exit(main())
