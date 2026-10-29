"""Unit tests for the AgentRun reaper script, loaded from the ConfigMap that ships it
(templates/55-autopilot/agentrun-reaper/reaper.yaml). No cluster needed."""

import pathlib
import sys
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOCS = list(yaml.safe_load_all((ROOT / "templates/55-autopilot/agentrun-reaper/reaper.yaml").read_text()))
SCRIPT = next(d for d in DOCS if d["kind"] == "ConfigMap")["data"]["reap.py"]
NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)


def load():
    ns = {"__name__": "reap"}
    exec(compile(SCRIPT, "reap.py", "exec"), ns)
    return ns


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def run(name, created, expires=None, phase="Running", deleting=False):
    r = {"metadata": {"name": name, "uid": f"uid-{name}", "creationTimestamp": iso(created)},
         "spec": {}, "status": {"phase": phase}}
    if expires is not None:
        r["spec"]["expiresAt"] = expires if isinstance(expires, str) else iso(expires)
    if deleting:
        r["metadata"]["deletionTimestamp"] = iso(NOW)
    return r


class Due(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def names(self, runs):
        return [r["metadata"]["name"] for r in self.m["due"](runs, NOW)]

    def test_deadline_plus_retention(self):
        h = timedelta(hours=1)
        runs = [run("live", NOW - h, NOW + h),
                run("just-expired", NOW - h, NOW - timedelta(minutes=59), phase="Expired"),
                run("due", NOW - 2 * h, NOW - timedelta(minutes=60), phase="Expired"),
                run("stale-status", NOW - 3 * h, NOW - 2 * h, phase="Running")]
        self.assertEqual(self.names(runs), ["due", "stale-status"])

    def test_far_future_expiry_is_capped_by_max_ttl(self):
        # A Rejected run that asked for more than the cap: reaped at creation + 240 + 60 minutes.
        runs = [run("over-cap", NOW - timedelta(minutes=300), "2099-01-01T00:00:00Z", phase="Rejected"),
                run("over-cap-young", NOW - timedelta(minutes=299), "2099-01-01T00:00:00Z", phase="Rejected")]
        self.assertEqual(self.names(runs), ["over-cap"])

    def test_missing_or_bad_expiry_falls_back_to_the_cap(self):
        runs = [run("none", NOW - timedelta(minutes=300)), run("bad", NOW - timedelta(minutes=300), "soon"),
                run("none-young", NOW - timedelta(minutes=10))]
        self.assertEqual(self.names(runs), ["none", "bad"])

    def test_already_deleting_is_skipped(self):
        self.assertEqual(self.names([run("going", NOW - timedelta(hours=6), NOW - timedelta(hours=5),
                                         deleting=True)]), [])


class Main(unittest.TestCase):
    def test_deletes_with_uid_precondition_and_reports_failures(self):
        m = load()
        old = datetime.now(timezone.utc) - timedelta(hours=6)
        items = [run("a", old, old + timedelta(minutes=10)), run("b", old, old + timedelta(minutes=10)),
                 run("gone", old, old + timedelta(minutes=10)), run("live", datetime.now(timezone.utc) - timedelta(hours=1), datetime.now(timezone.utc) + timedelta(hours=1))]
        calls = []

        def call(method, path, body=None):
            calls.append((method, path, body))
            if method == "GET":
                return {"items": items}
            name = path.rsplit("/", 1)[1]
            if name == "gone":
                raise urllib.error.HTTPError(path, 404, "not found", {}, None)
            if name == "b":
                raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)
            return {}

        m["call"] = call
        rc = m["main"]()
        deletes = [(p.rsplit("/", 1)[1], b["preconditions"]["uid"]) for meth, p, b in calls if meth == "DELETE"]
        self.assertEqual(deletes, [("a", "uid-a"), ("b", "uid-b"), ("gone", "uid-gone")])
        self.assertEqual(rc, 1)  # b failed; the 404 is not a failure

    def test_nothing_due_exits_zero(self):
        m = load()
        m["call"] = lambda method, path, body=None: {"items": []}
        self.assertEqual(m["main"](), 0)


class Manifest(unittest.TestCase):
    def test_role_is_list_and_delete_on_agentruns_only(self):
        role = next(d for d in DOCS if d["kind"] == "Role")
        self.assertEqual(role["metadata"]["namespace"], "autopilot-runs")
        self.assertEqual(role["rules"], [{"apiGroups": ["catalog.hangar.io"], "resources": ["agentruns"],
                                          "verbs": ["list", "delete"]}])

    def test_image_is_digest_pinned_and_pod_is_restricted(self):
        pod = next(d for d in DOCS if d["kind"] == "CronJob")["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        c = pod["containers"][0]
        self.assertRegex(c["image"], r"@sha256:[0-9a-f]{64}$")
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        self.assertEqual(c["securityContext"]["capabilities"], {"drop": ["ALL"]})
        self.assertFalse(c["securityContext"]["allowPrivilegeEscalation"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
