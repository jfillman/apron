"""Unit tests for the Clearance rollout-order hook (I-77): the script in the ConfigMap that argocd-apps-install's extraObjects
carry, loaded from a rendered application.yaml (ROLLOUT_ORDER_RENDER, set by tests/run.sh), run against a fake API.
No cluster needed."""

import copy
import json
import os
import pathlib
import unittest
import urllib.error

import yaml

APP = pathlib.Path(os.environ["ROLLOUT_ORDER_RENDER"])
DOC = yaml.safe_load(APP.read_text())
EXTRA = DOC["spec"]["source"]["helm"]["valuesObject"]["extraObjects"]
SCRIPT = next(o for o in EXTRA if o["kind"] == "ConfigMap")["data"]["order.py"]
JOB = next(o for o in EXTRA if o["kind"] == "Job")
CHECKS = json.loads(next(e["value"] for e in JOB["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "CHECKS"))

OLD = "ghcr.io/acme/clearance-wait@sha256:0000"
NEW = CHECKS["waitImage"]
AGENT_IMAGE = CHECKS["agent"]["image"]


def repo_server(wait, sidecar=True):
    cs = [{"name": "repo-server", "image": "quay.io/argoproj/argocd:v3.4.5"}]
    if sidecar:
        cs.append({"name": "clearance-cmp", "env": [{"name": "CLEARANCE_URL", "value": "http://x"},
                                                    {"name": "CLEARANCE_WAIT_IMAGE", "value": wait}]})
    return {"metadata": {"generation": 3}, "spec": {"replicas": 1, "template": {"spec": {"containers": cs}}},
            "status": {"observedGeneration": 3, "replicas": 1, "updatedReplicas": 1, "availableReplicas": 1}}


def agent(wait, image=None, replicas=2, updated=2, available=2, total=2, generation=5, observed=5, name="agent"):
    args = ["--cluster=hangar-prod", f"--wait-image={wait}", f"--wait-previous-image={OLD}"]
    return {"metadata": {"generation": generation},
            "spec": {"replicas": replicas, "template": {"spec": {"containers": [
                {"name": name, "image": image or AGENT_IMAGE, "args": args}]}}},
            "status": {"observedGeneration": observed, "replicas": total, "updatedReplicas": updated,
                       "availableReplicas": available}}


def vap(images, generation=4, observed=4):
    expr = "variables.waitctr.image in [%s]" % ", ".join(f"'{i}'" for i in images)
    return {"metadata": {"generation": generation}, "spec": {"validations": [{"expression": expr}]},
            "status": {"observedGeneration": observed}}


def kyverno(images, ready=True):
    return {"metadata": {"generation": 2}, "spec": {"variables": [{"name": "allowed", "expression": json.dumps(images)}]},
            "status": {"conditionStatus": {"ready": ready}}}


class Fake:
    """The objects the hook reads, by API path; an exception value is raised."""

    def __init__(self, objs):
        self.objs = objs
        self.paths = []

    def __call__(self, path):
        self.paths.append(path)
        v = self.objs.get(path)
        if isinstance(v, Exception):
            raise v
        return copy.deepcopy(v)


RS = "/apis/apps/v1/namespaces/argocd-apps/deployments/argocd-apps-repo-server"
AG = "/apis/apps/v1/namespaces/clearance-system/deployments/clearance-argocd-agent"
GE = "/apis/apps/v1/namespaces/clearance-system/deployments/clearance-grant-expiry"
VAP = "/apis/admissionregistration.k8s.io/v1/validatingadmissionpolicies/clearance-protected-writes"
KY = "/apis/policies.kyverno.io/v1/validatingpolicies/flight-only-images"


def rolled():
    """Everything a new-image sync waits for, in place."""
    return {RS: repo_server(OLD), VAP: vap([NEW, OLD]), KY: kyverno(["ghcr.io/cloudnative-pg/", NEW, OLD]),
            AG: agent(NEW), GE: agent(NEW, name="grant-expiry")}


class Order(unittest.TestCase):
    def setUp(self):
        self.ns = {"__name__": "order"}
        exec(compile(SCRIPT, "order.py", "exec"), self.ns)

    def run_main(self, objs, timeout=0, ticks=None):
        fake = Fake(objs)
        self.ns["get"] = fake
        t = {"now": 0}
        sleeps = []

        def sleep(s):
            sleeps.append(s)
            t["now"] += s
            if ticks:
                ticks(len(sleeps), objs)
        rc = self.ns["main"](CHECKS, timeout, interval=10, clock=lambda: t["now"], sleep=sleep)
        return rc, fake, sleeps

    # When the order does not matter, nothing is read past the repo-server and the hook passes at once.
    def test_first_install_passes(self):
        rc, fake, _ = self.run_main({})
        self.assertEqual(rc, 0)
        self.assertEqual(fake.paths, [RS])

    def test_unchanged_wait_image_passes_without_reading_policies_or_agent(self):
        rc, fake, _ = self.run_main({RS: repo_server(NEW)})
        self.assertEqual(rc, 0)
        self.assertEqual(fake.paths, [RS])

    # A wait-image change waits for the policies and the agent.
    def test_change_with_everything_rolled_passes_once_kyverno_settled(self):
        rc, _, sleeps = self.run_main(rolled(), timeout=600)
        self.assertEqual((rc, sum(sleeps)), (0, self.ns["SETTLE"]))

    def test_kyverno_ready_alone_is_not_enough(self):
        # Kyverno exposes no observedGeneration: a fresh spec with ready true from the previous one still settles first.
        objs = rolled()
        self.ns["get"] = Fake(objs)
        self.assertIn("settling", self.ns["pending"](CHECKS, 0)[0])
        self.assertIn("settling", self.ns["pending"](CHECKS, self.ns["SETTLE"] - 1)[0])
        self.assertEqual(self.ns["pending"](CHECKS, self.ns["SETTLE"]), [])

    def test_settle_restarts_when_the_image_leaves_the_spec(self):
        objs = rolled()
        self.ns["get"] = Fake(objs)
        self.ns["pending"](CHECKS, 0)
        objs[KY] = kyverno([OLD])
        self.ns["pending"](CHECKS, 10)
        objs[KY] = kyverno([NEW])
        self.assertIn("settling", self.ns["pending"](CHECKS, 35)[0])
        self.assertEqual(self.ns["pending"](CHECKS, 65), [])

    def test_gate_turned_on_is_a_change(self):
        objs = rolled()
        objs[RS] = repo_server("", sidecar=False)
        self.ns["get"] = Fake(objs)
        self.assertIn("(none)", self.ns["change"](CHECKS))

    def pending(self, objs):
        """What holds, once any Kyverno policy that admits the image has settled."""
        self.ns["get"] = Fake(objs)
        self.ns["pending"](CHECKS, 0)
        return self.ns["pending"](CHECKS, self.ns["SETTLE"])

    def test_policy_without_the_new_image_holds(self):
        objs = rolled()
        objs[VAP] = vap([OLD])
        self.assertEqual(self.pending(objs), [f"clearance-protected-writes: does not admit {NEW} yet"])

    def test_policy_not_yet_observed_holds(self):
        objs = rolled()
        objs[VAP] = vap([NEW], generation=5, observed=4)
        self.assertEqual(len(self.pending(objs)), 1)

    def test_kyverno_not_ready_holds(self):
        objs = rolled()
        objs[KY] = kyverno([NEW], ready=False)
        self.assertEqual(self.pending(objs), ["flight-only-images: not ready"])

    def test_missing_policy_holds(self):
        objs = rolled()
        del objs[KY]
        self.assertEqual(self.pending(objs), ["flight-only-images: not found"])

    def test_old_agent_holds(self):
        objs = rolled()
        objs[AG] = agent(OLD)
        self.assertEqual(len(self.pending(objs)), 1)
        self.assertIn("--wait-image=" + OLD, self.pending(objs)[0])

    def test_agent_on_another_image_holds(self):
        objs = rolled()
        objs[AG] = agent(NEW, image="ghcr.io/acme/clearance-argocd-agent:v0.1.0@sha256:dddd")
        self.assertIn("runs ghcr.io/acme/clearance-argocd-agent:v0.1.0", self.pending(objs)[0])

    def test_agent_mid_rollout_holds(self):
        for kw in ({"updated": 1}, {"available": 1}, {"total": 3}, {"generation": 6}):
            objs = rolled()
            objs[AG] = agent(NEW, **kw)
            self.assertEqual(len(self.pending(objs)), 1, kw)

    def test_grant_expiry_is_held_to_the_same_rule(self):
        objs = rolled()
        objs[GE] = agent(OLD, name="grant-expiry")
        self.assertIn("clearance-grant-expiry", self.pending(objs)[0])
        del objs[GE]
        self.assertEqual(self.pending(objs), ["clearance-system/clearance-grant-expiry: not found"])

    def test_waits_then_passes_once_rolled(self):
        objs = rolled()
        objs[AG] = agent(OLD)

        def tick(n, o):
            if n == 5:
                o[AG] = agent(NEW)
        rc, _, sleeps = self.run_main(objs, timeout=600, ticks=tick)
        self.assertEqual((rc, len(sleeps)), (0, 5))

    def test_gives_up_after_the_timeout(self):
        objs = rolled()
        objs[VAP] = vap([OLD])
        rc, _, sleeps = self.run_main(objs, timeout=60)
        self.assertEqual(rc, 1)
        self.assertEqual(sum(sleeps), 60)

    def test_api_error_while_waiting_is_one_more_wait(self):
        objs = rolled()
        objs[KY] = urllib.error.HTTPError(KY, 503, "unavailable", {}, None)

        def tick(n, o):
            o[KY] = kyverno([NEW])
        rc, _, sleeps = self.run_main(objs, timeout=600, ticks=tick)
        # one wait for the error, then the settle from the first good read
        self.assertEqual((rc, sum(sleeps)), (0, 10 + self.ns["SETTLE"]))

    def test_unreadable_repo_server_fails_closed(self):
        objs = {RS: urllib.error.HTTPError(RS, 403, "forbidden", {}, None)}
        with self.assertRaises(urllib.error.HTTPError):
            self.run_main(objs)


class Rendered(unittest.TestCase):
    """What the hook is given matches what the render puts in place."""

    def test_checks(self):
        self.assertEqual(CHECKS["repoServer"], "argocd-apps/argocd-apps-repo-server")
        self.assertEqual(CHECKS["container"], "clearance-cmp")
        self.assertEqual([p["name"] for p in CHECKS["policies"]], ["clearance-protected-writes", "flight-only-images"])
        self.assertEqual(CHECKS["agent"]["deployments"], ["clearance-system/clearance-argocd-agent", "clearance-system/clearance-grant-expiry"])
        sidecar = next(c for c in DOC["spec"]["source"]["helm"]["valuesObject"]["repoServer"]["extraContainers"] if c["name"] == "clearance-cmp")
        self.assertEqual(NEW, next(e["value"] for e in sidecar["env"] if e["name"] == "CLEARANCE_WAIT_IMAGE"))

    def test_agent_image_is_the_agent_applications(self):
        agent_app = yaml.safe_load((APP.parents[2] / "56-clearance-gate/agent/application.yaml").read_text())
        img = agent_app["spec"]["source"]["helm"]["valuesObject"]["image"]
        self.assertEqual(AGENT_IMAGE, f"{img['repository']}:{img['tag']}")

    def test_hooks(self):
        for o in EXTRA:
            ann = o["metadata"]["annotations"]
            self.assertEqual(ann["argocd.argoproj.io/hook"], "PreSync", o["kind"])
            self.assertEqual(ann["argocd.argoproj.io/hook-delete-policy"], "BeforeHookCreation", o["kind"])
            self.assertEqual(ann.get("argocd.argoproj.io/sync-wave"), None if o["kind"] == "Job" else "-1", o["kind"])
        self.assertEqual(JOB["spec"]["backoffLimit"], 0)
        self.assertGreater(JOB["spec"]["activeDeadlineSeconds"], int(next(
            e["value"] for e in JOB["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "TIMEOUT_SECONDS")))

    def test_rbac_is_get_on_named_objects_only(self):
        role = next(o for o in EXTRA if o["kind"] == "ClusterRole")
        for r in role["rules"]:
            self.assertEqual(r["verbs"], ["get"])
            self.assertTrue(r["resourceNames"])
        names = {n for r in role["rules"] for n in r["resourceNames"]}
        self.assertEqual(names, {"argocd-apps-repo-server", "clearance-argocd-agent", "clearance-grant-expiry",
                                 "clearance-protected-writes", "flight-only-images"})

    def test_retry(self):
        self.assertEqual(DOC["spec"]["syncPolicy"]["retry"]["limit"], 5)


if __name__ == "__main__":
    unittest.main()
