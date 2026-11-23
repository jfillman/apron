"""Unit tests for the Clearance rollout-order hook (I-77): the script in the ConfigMap that argocd-apps-install's extraObjects
carry, loaded from a rendered application.yaml (ROLLOUT_ORDER_RENDER, set by tests/run.sh), run against a fake API.
No cluster needed."""

import copy
import http.client
import json
import os
import pathlib
import signal
import ssl
import tempfile
import time
import types
import unittest
import urllib.error
import urllib.request

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


def kyverno(images, ready=True, uid="u1", generation=2):
    return {"metadata": {"uid": uid, "generation": generation}, "spec": {"variables": [{"name": "allowed", "expression": json.dumps(images)}]},
            "status": {"conditionStatus": {"ready": ready}}}


class Fake:
    """The objects the hook reads, by API path; an exception value is raised."""

    def __init__(self, objs):
        self.objs = objs
        self.paths = []
        self.timeouts = []

    def __call__(self, path, timeout=30):
        self.paths.append(path)
        self.timeouts.append(timeout)
        v = self.objs.get(path)
        if isinstance(v, list):  # a sequence of answers, the last one repeated
            v = v.pop(0) if len(v) > 1 else v[0]
        if isinstance(v, Exception):
            raise v
        return copy.deepcopy(v)


def err(path, code):
    return urllib.error.HTTPError(path, code, "error", {}, None)


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

    def run_main(self, objs, timeout=600, ticks=None, t=None, fake=None):
        fake = fake or Fake(objs)
        self.ns["get"] = fake
        t = t if t is not None else {"now": 0}
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
        self.assertIn("settling", self.ns["pending"](CHECKS, lambda: 0)[0])
        self.assertIn("settling", self.ns["pending"](CHECKS, lambda: self.ns["SETTLE"] - 1)[0])
        self.assertEqual(self.ns["pending"](CHECKS, lambda: self.ns["SETTLE"]), [])

    def test_settle_restarts_when_the_image_leaves_the_spec(self):
        objs = rolled()
        self.ns["get"] = Fake(objs)
        self.ns["pending"](CHECKS, lambda: 0)
        objs[KY] = kyverno([OLD])
        self.ns["pending"](CHECKS, lambda: 10)
        objs[KY] = kyverno([NEW])
        self.assertIn("settling", self.ns["pending"](CHECKS, lambda: 35)[0])
        self.assertEqual(self.ns["pending"](CHECKS, lambda: 65), [])

    def test_settle_restarts_on_delete_recreate_or_a_new_generation(self):
        S = self.ns["SETTLE"]
        for change in ("recreate", "delete", "generation"):
            self.ns["seen"].clear()
            objs = rolled()
            self.ns["get"] = Fake(objs)
            self.assertIn("settling", self.ns["pending"](CHECKS, lambda: 0)[0])
            self.assertEqual(self.ns["pending"](CHECKS, lambda: S), [], change)
            if change == "recreate":
                objs[KY] = kyverno([NEW], uid="u2")
            elif change == "generation":
                objs[KY] = kyverno([NEW], generation=3)
            else:
                del objs[KY]
                self.assertEqual(self.ns["pending"](CHECKS, lambda: S + 5), ["flight-only-images: not found"])
                objs[KY] = kyverno([NEW])
            self.assertIn("settling", self.ns["pending"](CHECKS, lambda: S + 10)[0], change)
            self.assertEqual(self.ns["pending"](CHECKS, lambda: 2 * S + 10), [], change)

    def test_settle_is_timed_from_after_the_read(self):
        # The clock is read after the policy GET: a slow read does not count toward the settle.
        objs = rolled()
        t = {"now": 0, "slow": True}

        def slow_get(path, timeout=30):
            if path == KY and t["slow"]:
                t["now"] += 20
                t["slow"] = False
            return copy.deepcopy(objs.get(path))
        self.ns["get"] = slow_get
        self.ns["pending"](CHECKS, lambda: t["now"])   # first seen at 20, not 0
        t["now"] = 40
        self.assertIn("settling", self.ns["pending"](CHECKS, lambda: t["now"])[0])

    def test_gate_turned_on_is_a_change(self):
        objs = rolled()
        objs[RS] = repo_server("", sidecar=False)
        self.ns["get"] = Fake(objs)
        self.assertIn("(none)", self.ns["change"](CHECKS))

    def pending(self, objs):
        """What holds, once any Kyverno policy that admits the image has settled."""
        self.ns["get"] = Fake(objs)
        self.ns["pending"](CHECKS, lambda: 0)
        return self.ns["pending"](CHECKS, lambda: self.ns["SETTLE"])

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

    # I-79 (3): a transient read error is read again with backoff, inside the poll and inside the budget.
    def test_transient_error_while_waiting_is_read_again(self):
        objs = rolled()
        objs[KY] = [err(KY, 503), kyverno(["ghcr.io/cloudnative-pg/", NEW, OLD])]
        rc, fake, sleeps = self.run_main(objs, timeout=600)
        # one 1s backoff for the error, then the settle timed from the good read (at 1s)
        self.assertEqual((rc, sleeps[0], sum(sleeps)), (0, 1, 1 + self.ns["SETTLE"]))
        self.assertEqual(fake.paths.count(KY), 5)

    def test_transient_repo_server_read_is_read_again(self):
        for e in (err(RS, 500), err(RS, 429), ConnectionResetError("reset"), TimeoutError("timed out"),
                  urllib.error.URLError(ConnectionRefusedError("refused")), http.client.RemoteDisconnected("gone")):
            rc, fake, sleeps = self.run_main({RS: [e, e, repo_server(NEW)]}, timeout=600)
            self.assertEqual((rc, sleeps, fake.paths), (0, [1, 2], [RS, RS, RS]), e)

    def test_unreadable_repo_server_fails_closed(self):
        # a refusal is not transient: no retry, and the sync fails rather than letting the repo-server roll
        rc, fake, sleeps = self.run_main({RS: err(RS, 403)}, timeout=600)
        self.assertEqual((rc, sleeps, fake.paths), (1, [], [RS]))

    def test_repo_server_down_past_the_budget_fails_closed(self):
        rc, fake, sleeps = self.run_main({RS: err(RS, 503)}, timeout=60)
        self.assertEqual(rc, 1)
        self.assertEqual(sleeps[:5], [1, 2, 4, 8, 8])
        self.assertLessEqual(sum(sleeps), 60)

    def test_persistent_transient_error_stays_within_the_budget(self):
        objs = rolled()
        objs[KY] = err(KY, 502)
        t = {"now": 0}
        fake = Fake(objs)
        rc, _, sleeps = self.run_main(objs, timeout=120, t=t, fake=fake)
        self.assertEqual(rc, 1)
        self.assertLessEqual(t["now"], 120)
        self.assertTrue(all(0 < x <= 30 for x in fake.timeouts), fake.timeouts)

    def test_read_timeout_is_held_to_what_is_left(self):
        objs = rolled()
        objs[AG] = agent(OLD)
        fake = Fake(objs)
        self.run_main(objs, timeout=45, fake=fake)
        self.assertEqual(fake.timeouts[0], 30)
        self.assertEqual(min(fake.timeouts), 5)  # the poll at 40s: only the 5s left, and no read at or past 45s

    def test_refusal_while_waiting_is_not_retried(self):
        objs = rolled()
        objs[KY] = err(KY, 403)
        rc, _, sleeps = self.run_main(objs, timeout=30)
        self.assertEqual((rc, sleeps), (1, [10, 10, 10]))

    def test_transient_classification(self):
        tr = self.ns["transient"]
        for e in (err(RS, 500), err(RS, 503), err(RS, 429), ConnectionResetError(), ConnectionRefusedError(), TimeoutError(),
                  http.client.RemoteDisconnected(), http.client.IncompleteRead(b""), urllib.error.URLError("dns")):
            self.assertTrue(tr(e), e)
        for e in (err(RS, 400), err(RS, 401), err(RS, 403), err(RS, 409), ValueError("bad json"),
                  urllib.error.URLError(ssl.SSLCertVerificationError("bad cert"))):
            self.assertFalse(tr(e), e)

    def test_no_read_starts_past_the_deadline(self):
        fake = Fake({VAP: vap([NEW])})
        self.ns["get"] = fake
        self.ns["CLOCK"], self.ns["DEADLINE"] = (lambda: 10), 10
        with self.assertRaises(TimeoutError):
            self.ns["read"](VAP)
        self.assertEqual(fake.paths, [])
        self.ns["DEADLINE"] = 10.25
        self.assertEqual(self.ns["read"](VAP)["metadata"]["generation"], 4)
        self.assertEqual(fake.timeouts, [0.25])  # what is left, no floor

    # I-79 follow-up (gitops-hangar-dev#221): a poll whose reads retried is not accepted; nothing read late is accepted.
    def test_poll_with_a_retry_is_not_accepted(self):
        objs = rolled()
        a = agent(NEW)
        objs[AG] = [a, a, a, err(AG, 503), a]  # the 4th poll (30s) would pass, but its agent read retried
        rc, _, sleeps = self.run_main(objs, timeout=600)
        self.assertEqual((rc, sleeps), (0, [10, 10, 10, 1, 10]))

    def test_policy_gone_during_a_retry_is_seen_by_the_next_poll(self):
        objs = rolled()
        a = agent(NEW)
        objs[AG] = [a, a, a, err(AG, 503), a]

        def tick(n, o):
            if n == 4:  # the 1s backoff of the agent read: the policy is removed meanwhile
                del o[KY]
        rc, _, _ = self.run_main(objs, timeout=60, ticks=tick)
        self.assertEqual(rc, 1)

    def test_retries_are_counted(self):
        self.ns["get"] = Fake({VAP: [err(VAP, 503), err(VAP, 502), vap([NEW])]})
        self.ns["CLOCK"], self.ns["SLEEP"], self.ns["DEADLINE"] = (lambda: 0), (lambda s: None), 600
        self.ns["read"](VAP)
        self.assertEqual(self.ns["RETRIES"], 2)

    def test_read_finished_past_the_deadline_is_refused(self):
        t = {"now": 0}

        def slow(path, timeout=30):
            t["now"] = 11  # started in budget (timeout 10s per call), the whole response ends after it
            return vap([NEW])
        self.ns["get"] = slow
        self.ns["CLOCK"], self.ns["DEADLINE"] = (lambda: t["now"]), 10
        with self.assertRaises(TimeoutError):
            self.ns["read"](VAP)

    def test_late_initial_read_is_not_accepted(self):
        # an unchanged wait image would pass at once, but the repo-server read ended past the deadline
        for rs in ({RS: repo_server(NEW)}, {}):
            t = {"now": 0}
            fake = Fake(rs)

            def slow(path, timeout=30):
                t["now"] = 700
                return fake(path, timeout)
            rc, _, _ = self.run_main(rs, timeout=600, t=t, fake=slow)
            self.assertEqual(rc, 1, rs)

    # A hard limit on the whole request (CodeRabbit on gitops-hangar-dev#221): a response that keeps trickling in is cut off.
    def test_bounded_stops_a_blocked_call(self):
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.ns["bounded"](0.2, lambda: time.sleep(5))
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL)[0], 0)
        self.assertIs(signal.getsignal(signal.SIGALRM), signal.SIG_DFL)

    def test_bounded_is_not_swallowed_by_an_oserror_handler(self):
        # socket.create_connection tries the next address on any OSError: the timer must get through such a handler
        def connect_fallback():
            for _ in range(2):
                try:
                    time.sleep(5)
                except OSError:
                    continue
            return "carried on"
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.ns["bounded"](0.2, connect_fallback)
        self.assertLess(time.monotonic() - start, 2)

    def test_bounded_returns_and_clears_its_timer(self):
        self.assertEqual(self.ns["bounded"](5, lambda: 7), 7)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL)[0], 0)
        with self.assertRaises(ValueError):
            self.ns["bounded"](5, lambda: int("x"))
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL)[0], 0)

    def stub_api(self, body):
        """get() against a stub urlopen: body() is what reading the response does."""
        sa = tempfile.mkdtemp()
        pathlib.Path(sa, "token").write_text("t")
        self.ns["SA"] = sa
        self.ns["ssl"] = types.SimpleNamespace(create_default_context=lambda cafile: None,
                                               SSLCertVerificationError=ssl.SSLCertVerificationError)

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self, *a):
                return body()
        self.ns["urllib"] = types.SimpleNamespace(
            request=types.SimpleNamespace(Request=urllib.request.Request, urlopen=lambda req, context, timeout: Resp()),
            error=urllib.error)

    def test_get_stops_a_response_that_trickles_past_its_timeout(self):
        # each socket read would stay under the per-call timeout; the whole response does not
        def trickle():
            time.sleep(5)
            return b"{}"
        self.stub_api(trickle)
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.ns["get"](VAP, timeout=0.3)
        self.assertLess(time.monotonic() - start, 2)

    def test_get_bounds_its_setup_too(self):
        # the token read and TLS setup count against the same timer as the request
        self.stub_api(lambda: b"{}")

        def slow_context(cafile):
            time.sleep(5)
        self.ns["ssl"].create_default_context = slow_context
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.ns["get"](VAP, timeout=0.3)
        self.assertLess(time.monotonic() - start, 2)

    def test_setup_and_response_share_one_timer(self):
        # 0.2s of setup and 0.2s of response each fit a 0.3s timer alone, not together
        self.stub_api(lambda: (time.sleep(0.2), b"{}")[1])

        def slowish_context(cafile):
            time.sleep(0.2)
        self.ns["ssl"].create_default_context = slowish_context
        with self.assertRaises(TimeoutError):
            self.ns["get"](VAP, timeout=0.3)

    def test_get_returns_a_prompt_response(self):
        self.stub_api(lambda: json.dumps(vap([NEW])).encode())
        self.assertEqual(self.ns["get"](VAP, timeout=5)["metadata"]["generation"], 4)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL)[0], 0)

    def test_no_retry_without_a_deadline(self):
        # pending() called on its own (no main): an error is raised at once, never slept on
        self.ns["get"] = Fake({VAP: err(VAP, 503)})
        with self.assertRaises(urllib.error.HTTPError):
            self.ns["read"](VAP)

    # I-79 (4): nothing is accepted past the deadline.
    def test_ready_read_past_the_deadline_is_not_accepted(self):
        objs = rolled()
        t = {"now": 0}
        fake = Fake(objs)

        def slow(path, timeout=30):
            if t["now"] == 30 and path == AG:  # the poll that would pass starts in budget and ends after it
                t["now"] = 40
            return fake(path, timeout)
        rc, _, _ = self.run_main(objs, timeout=35, t=t, fake=slow)
        self.assertEqual((rc, t["now"]), (1, 40))
        # the same poll in budget passes
        self.ns["seen"].clear()
        rc, _, _ = self.run_main(rolled(), timeout=35)
        self.assertEqual(rc, 0)

    def test_last_sleep_is_held_to_the_deadline(self):
        objs = rolled()
        objs[VAP] = vap([OLD])
        rc, _, sleeps = self.run_main(objs, timeout=25)
        self.assertEqual((rc, sleeps), (1, [10, 10, 5]))

    # I-79 (1): a ValidatingAdmissionPolicy's observedGeneration is not taken as its admission plugin having loaded the spec.
    def test_vap_observed_alone_is_not_enough(self):
        objs = rolled()
        objs[VAP] = vap([NEW], generation=5, observed=4)
        self.ns["get"] = Fake(objs)
        self.assertIn("not observed yet", self.ns["pending"](CHECKS, lambda: 0)[0])
        objs[VAP] = vap([NEW], generation=5, observed=5)
        S = self.ns["SETTLE"]
        self.assertIn("clearance-protected-writes: admits", self.ns["pending"](CHECKS, lambda: 10)[0])
        self.assertIn("settling", self.ns["pending"](CHECKS, lambda: 10 + S - 1)[0])
        self.assertEqual(self.ns["pending"](CHECKS, lambda: 10 + S), [])

    def test_vap_settle_restarts_on_a_new_generation(self):
        objs = rolled()
        self.ns["get"] = Fake(objs)
        S = self.ns["SETTLE"]
        self.ns["pending"](CHECKS, lambda: 0)
        self.assertEqual(self.ns["pending"](CHECKS, lambda: S), [])
        objs[VAP] = vap([NEW], generation=6, observed=6)
        self.assertIn("clearance-protected-writes: admits", self.ns["pending"](CHECKS, lambda: S + 1)[0])
        self.assertEqual(self.ns["pending"](CHECKS, lambda: 2 * S + 1), [])


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
            # I-79 (2): nothing privileged outlives the sync operation; the Job only when it failed (for its log)
            want = "BeforeHookCreation,HookSucceeded" if o["kind"] == "Job" else "BeforeHookCreation,HookSucceeded,HookFailed"
            self.assertEqual(ann["argocd.argoproj.io/hook-delete-policy"], want, o["kind"])
            self.assertEqual(ann.get("argocd.argoproj.io/sync-wave"), None if o["kind"] == "Job" else "-1", o["kind"])
        self.assertEqual(JOB["spec"]["backoffLimit"], 0)
        self.assertEqual(JOB["spec"]["ttlSecondsAfterFinished"], 86400)
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
