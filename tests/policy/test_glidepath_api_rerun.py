#!/usr/bin/env python3
"""glidepath-api's PipelineRun policies (templates/30-policy/kyverno-policies/tower-identity-writes.yaml, pipeline trust T5).

Evaluates the RENDERED policies' own CEL (matchConditions, variables, validations) over fixtures with a real CEL
implementation (cel-python), so a typo or a has()-less field access fails here and not as a refused request under
failurePolicy Fail. The reruns are what glidepath-api's code builds (tests/policy/fixtures/glidepath-api-reruns.json, made by
glidepath/api/internal/pipelineruns Rerun() from PaC-shaped source runs; fixtures/glidepath-api-reruns.gen.go.txt is the generator).

    python3 tests/policy/test_glidepath_api_rerun.py DENY_DIR WARN_DIR

DENY_DIR / WARN_DIR are rendered cluster repos (tests/run.sh renders them; WARN_DIR sets glidepath.sourceIsolation: warn).
Without cel-python it prints "skipped" and exits 0 (pip install cel-python pyyaml).
"""
import copy
import json
import sys
import unittest
from pathlib import Path

try:
    import celpy
    import yaml
except ImportError:
    print("skipped: needs cel-python and pyyaml")
    sys.exit(0)

HERE = Path(__file__).resolve().parent
API = "system:serviceaccount:platform-system:glidepath-api"
NS = "app-sample-cicd"
ENV = celpy.Environment()
FIX = json.loads((HERE / "fixtures" / "glidepath-api-reruns.json").read_text())
POLICY_FILE = "30-policy/kyverno-policies/tower-identity-writes.yaml"
SHAPE, ISOLATION = "glidepath-api-pipelinerun-shape", "glidepath-api-pipelinerun-source-isolation"

DENY_DIR, WARN_DIR = sys.argv[1], sys.argv[2]
del sys.argv[1:3]


def load(d):
    docs = [x for x in yaml.safe_load_all((Path(d) / POLICY_FILE).read_text()) if x]
    return {x["metadata"]["name"]: x["spec"] for x in docs if x.get("kind") == "ValidatingPolicy"}


DENY, WARN = load(DENY_DIR), load(WARN_DIR)


def cel(expr, act):
    return ENV.program(ENV.compile(" ".join(expr.split()))).evaluate(act)


def evaluate(spec, obj, user=API, namespace=NS, operation="CREATE", old=None):
    """-> None when the policy does not apply, else the list of failing validation messages. A CEL error raises."""
    request = {"userInfo": {"username": user}, "namespace": namespace, "operation": operation}
    act = {"object": celpy.json_to_cel(obj), "oldObject": celpy.json_to_cel(old), "request": celpy.json_to_cel(request),
           "variables": celpy.json_to_cel({})}
    ops = [o for r in spec["matchConstraints"]["resourceRules"] for o in r["operations"]]
    if operation not in ops:
        return None
    for mc in spec["matchConditions"]:
        if not cel(mc["expression"], act):
            return None
    variables = {}
    for v in spec.get("variables", []):
        variables[v["name"]] = cel(v["expression"], act)
        act["variables"] = celpy.celtypes.MapType({celpy.celtypes.StringType(k): x for k, x in variables.items()})
    return [val["message"] for val in spec["validations"] if not cel(val["expression"], act)]


def rerun(name):
    return copy.deepcopy(FIX["rerun-" + name])


def promote():
    """startRun (environments.go) over the promote TriggerTemplate: Pipeline release, the initiator annotation, the origin stamp."""
    return {"apiVersion": "tekton.dev/v1", "kind": "PipelineRun",
            "metadata": {"name": "promote-prod-b01565a5-abcde", "namespace": NS,
                         "labels": {"hangar.io/app": "sample", "hangar.io/flow": "promote", "hangar.io/stage": "release"},
                         "annotations": {"hangar.io/initiator": "user:default/someone", "glidepath.hangar.io/idempotency-key-sha256": "a" * 64,
                                         "glidepath.io/origin-ref": "refs/heads/main", "glidepath.io/origin-sha": "b" * 40}},
            "spec": {"pipelineRef": FIX["rerun-release"]["spec"]["pipelineRef"],
                     "params": [{"name": "env", "value": "prod"}],
                     "workspaces": [{"name": "source", "emptyDir": {}}],
                     "taskRunTemplate": {"serviceAccountName": "pipeline-runner"}}}


class Shape(unittest.TestCase):
    def refused(self, obj, want, policies=DENY, **kw):
        got = evaluate(policies[SHAPE], obj, **kw)
        self.assertTrue(got, f"admitted; expected a refusal containing {want!r}")
        self.assertTrue(any(want in m for m in got), f"refused for {got}, expected {want!r}")

    def admitted(self, obj, policies=DENY, **kw):
        self.assertEqual(evaluate(policies[SHAPE], obj, **kw), [])

    # what glidepath-api builds today and after the Glidepath release, for every Pipeline it reruns
    def test_real_reruns_are_admitted(self):
        self.assertEqual(sorted(FIX), ["rerun-build", "rerun-build-pr", "rerun-build-pre-hardening", "rerun-deploy",
                                       "rerun-release", "rerun-test"])
        for name in FIX:
            with self.subTest(name):
                self.admitted(rerun(name[len("rerun-"):]))
        self.admitted(promote())

    def test_the_rerun_carries_what_the_isolation_needs(self):
        # guards the fixture: the hardened build rerun really has the entries and the origin stamp the rules look at
        b = rerun("build")
        self.assertEqual(len(b["spec"]["taskRunSpecs"]), 6)
        self.assertIn("glidepath.io/origin-ref", b["metadata"]["annotations"])
        self.assertNotIn("taskRunSpecs", rerun("build-pre-hardening")["spec"])

    def test_per_task_accounts_are_the_platforms_pairs_only(self):
        for task, sa in [("unit-test", "image-pusher"), ("build-source", "glidepath-cloud-deployer"),
                         ("push-image", "source-runner"), ("push-image", "pipeline-runner"),
                         ("unit-test", "pipeline-runner"), ("unit-test", "pipeline-trigger"), ("unit-test", "default"),
                         ("notify-backstage", "source-runner"), ("deploy-aws-lambda", "source-runner")]:
            with self.subTest(task=task, sa=sa):
                o = rerun("build")
                o["spec"]["taskRunSpecs"] = [{"pipelineTaskName": task, "serviceAccountName": sa}]
                self.refused(o, "taskRunSpecs entries")
        # a cloud deployer entry is a pair only for the Pipeline that lists it
        o = rerun("build")
        o["spec"]["taskRunSpecs"].append({"pipelineTaskName": "deploy-aws-lambda", "serviceAccountName": "glidepath-cloud-deployer"})
        self.refused(o, "taskRunSpecs entries")
        o = rerun("deploy")
        o["spec"]["taskRunSpecs"][0]["serviceAccountName"] = "source-runner"
        self.refused(o, "taskRunSpecs entries")
        o = rerun("test")
        o["spec"]["taskRunSpecs"][0]["pipelineTaskName"] = "build-source"
        self.refused(o, "taskRunSpecs entries")

    def test_entries_carry_two_fields_once_per_task(self):
        for extra in [{"podTemplate": {"hostAliases": []}}, {"computeResources": {}}, {"stepSpecs": []}, {"sidecarSpecs": []},
                      {"metadata": {"labels": {"a": "b"}}}, {"timeout": "1h"}]:
            with self.subTest(extra=list(extra)):
                o = rerun("build")
                o["spec"]["taskRunSpecs"][0].update(extra)
                self.refused(o, "no other override")
        o = rerun("build")
        o["spec"]["taskRunSpecs"].append(dict(o["spec"]["taskRunSpecs"][0]))
        self.refused(o, "once per task")
        o = rerun("build")
        o["spec"]["taskRunSpecs"].append({"pipelineTaskName": "unit-test", "serviceAccountName": "image-pusher"})
        self.refused(o, "once per task")
        for bad_list in ["x", {"pipelineTaskName": "unit-test"}]:
            o = rerun("build")
            o["spec"]["taskRunSpecs"] = bad_list
            self.refused(o, "taskRunSpecs entries")
        o = rerun("build")
        o["spec"]["taskRunSpecs"].append("not-an-object")
        self.refused(o, "taskRunSpecs entries")
        for bad in [{}, {"pipelineTaskName": "unit-test"}, {"serviceAccountName": "source-runner"}, {"pipelineTaskName": 7, "serviceAccountName": "x"}]:
            with self.subTest(bad=bad):
                o = rerun("build")
                o["spec"]["taskRunSpecs"] = [bad]
                self.refused(o, "taskRunSpecs entries")

    def test_run_wide_account_and_pod_template_unchanged(self):
        o = rerun("build")
        o["spec"]["taskRunTemplate"]["serviceAccountName"] = "source-runner"
        self.refused(o, "must be pipeline-runner")
        o = rerun("build")
        o["spec"]["taskRunTemplate"]["podTemplate"]["volumes"] = []
        self.refused(o, "may only set hostAliases")
        o = rerun("build")
        o["spec"]["pipelineSpec"] = {}
        self.refused(o, "No inline pipelineSpec")
        o = rerun("build")
        o["spec"]["pipelineRef"]["params"][2]["value"] = "other"
        self.refused(o, "platform-catalog")

    def test_annotations_are_an_explicit_allowlist(self):
        for k in ["glidepath.io/origin-ref", "glidepath.io/origin-sha", "glidepath.io/origin-event", "glidepath.hangar.io/rerun-of",
                  "glidepath.hangar.io/idempotency-key-sha256", "hangar.io/initiator"]:
            o = rerun("build")
            o["metadata"]["annotations"][k] = "v"
            self.admitted(o)
        for k in ["pipelinesascode.tekton.dev/event-type", "pipelinesascode.tekton.dev/sha", "glidepath.io/other",
                  "glidepath.hangar.io/other", "hangar.io/other", "tekton.dev/x", "chains.tekton.dev/signed", "example.com/x"]:
            with self.subTest(k):
                o = rerun("build")
                o["metadata"]["annotations"][k] = "v"
                self.refused(o, "annotation")
        o = rerun("build")
        o["metadata"].pop("annotations")
        self.admitted(o)

    def test_workspace_volume_claim_templates_are_bounded(self):
        def spec(o):
            return o["spec"]["workspaces"][0]["volumeClaimTemplate"]["spec"]
        for k, v in [("dataSource", {"kind": "PersistentVolumeClaim", "name": "x"}),
                     ("dataSourceRef", {"kind": "PersistentVolumeClaim", "name": "x"}), ("volumeName", "pv-1"),
                     ("selector", {"matchLabels": {"a": "b"}}), ("storageClassName", "fast"), ("volumeMode", "Block"),
                     ("accessModes", ["ReadWriteMany"])]:
            with self.subTest(k):
                o = rerun("build")
                spec(o)[k] = v
                self.refused(o, "volumeClaimTemplate")
        for storage in ["500Gi", "51Gi", "1Ti", "5", "2G", "-1Gi", "100Mi", ""]:
            with self.subTest(storage=storage):
                o = rerun("build")
                spec(o)["resources"]["requests"]["storage"] = storage
                self.refused(o, "volumeClaimTemplate")
        for storage in ["2Gi", "5Gi", "10Gi", "20Gi", "50Gi"]:
            o = rerun("build")
            spec(o)["resources"]["requests"]["storage"] = storage
            self.admitted(o)
        o = rerun("build")
        spec(o)["resources"]["limits"] = {"storage": "1Gi"}
        self.refused(o, "volumeClaimTemplate")
        o = rerun("build")
        spec(o)["resources"]["requests"]["cpu"] = "1"
        self.refused(o, "volumeClaimTemplate")
        o = rerun("build")
        del spec(o)["resources"]
        self.refused(o, "volumeClaimTemplate")
        o = rerun("build")
        o["spec"]["workspaces"][0]["volumeClaimTemplate"]["metadata"] = {"labels": {"a": "b"}}
        self.refused(o, "volumeClaimTemplate")
        o = rerun("build")
        o["spec"]["workspaces"][0]["volumeClaimTemplate"]["metadata"] = {"creationTimestamp": None}
        o["spec"]["workspaces"][0]["volumeClaimTemplate"]["status"] = {}
        self.admitted(o)
        o = rerun("build")
        o["spec"]["workspaces"][0]["volumeClaimTemplate"]["apiVersion"] = "v1"
        o["spec"]["workspaces"][0]["volumeClaimTemplate"]["dataSourceRef"] = {"name": "x"}
        self.refused(o, "volumeClaimTemplate")
        o = rerun("build")
        o["spec"]["workspaces"].append({"name": "x", "persistentVolumeClaim": {"claimName": "someone-elses"}})
        self.refused(o, "emptyDir or volumeClaimTemplate")
        o = rerun("build")
        o["spec"]["workspaces"].append({"name": "x", "secret": {"secretName": "s"}})
        self.refused(o, "emptyDir or volumeClaimTemplate")

    def test_storage_class_is_unset_unless_the_cluster_allowlists_it(self):
        # DENY_DIR sets no glidepath.runStorageClasses; WARN_DIR sets [fast]
        for pol, class_name, ok in [(DENY, "fast", False), (WARN, "fast", True), (WARN, "other", False)]:
            o = rerun("build")
            o["spec"]["workspaces"][0]["volumeClaimTemplate"]["spec"]["storageClassName"] = class_name
            with self.subTest(class_name=class_name, ok=ok):
                if ok:
                    self.admitted(o, policies=pol)
                else:
                    self.refused(o, "volumeClaimTemplate", policies=pol)

    def test_scope_is_unchanged(self):
        self.assertEqual(DENY[SHAPE]["failurePolicy"], "Fail")
        self.assertEqual(DENY[SHAPE]["validationActions"], ["Deny"])
        self.assertIsNone(evaluate(DENY[SHAPE], rerun("build"), user="system:serviceaccount:app-sample-cicd:pipeline-runner"))
        self.assertIsNone(evaluate(DENY[SHAPE], rerun("build"), user="system:serviceaccount:platform-system:other"))
        self.assertTrue(any("-cicd namespace" in m for m in evaluate(DENY[SHAPE], rerun("build"), namespace="argocd")))
        self.assertTrue(any("-cicd namespace" in m for m in evaluate(DENY[SHAPE], rerun("build"), namespace="app-sample-prod")))
        self.admitted(rerun("build"), namespace="infra-sample-cicd")

    def test_cancel_still_changes_status_only(self):
        old = rerun("build")
        new = copy.deepcopy(old)
        new["spec"]["status"] = "CancelledRunFinally"
        self.assertEqual(evaluate(DENY[SHAPE], new, operation="UPDATE", old=old), [])
        new["spec"]["taskRunSpecs"][0]["serviceAccountName"] = "pipeline-runner"
        self.assertTrue(any("only change spec.status" in m for m in evaluate(DENY[SHAPE], new, operation="UPDATE", old=old)))

    def test_no_expression_raises_on_an_unexpected_shape(self):
        shapes = [{}, {"spec": {}}, {"metadata": {}, "spec": {}}, {"spec": {"taskRunSpecs": []}}, {"spec": {"taskRunSpecs": [{}]}},
                  {"spec": {"taskRunSpecs": [{"pipelineTaskName": None, "serviceAccountName": None}]}},
                  {"spec": {"taskRunSpecs": [{"pipelineTaskName": 3}]}}, {"spec": {"pipelineRef": {}}},
                  {"spec": {"pipelineRef": {"params": [{}]}}}, {"spec": {"pipelineRef": {"params": [{"name": "name"}]}}},
                  {"spec": {"pipelineRef": {"params": [{"name": "name", "value": 5}]}}},
                  {"spec": {"workspaces": [{}]}}, {"spec": {"workspaces": [{"volumeClaimTemplate": {}}]}},
                  {"spec": {"workspaces": [{"volumeClaimTemplate": {"spec": {}}}]}},
                  {"spec": {"workspaces": [{"volumeClaimTemplate": {"spec": {"resources": {"requests": {"storage": 5}}}}}]}},
                  {"spec": {"workspaces": [{"volumeClaimTemplate": {"spec": {"accessModes": "x"}}}]}},
                  {"metadata": {"annotations": {}}, "spec": {}}, {"metadata": {"annotations": {"a": "b"}}, "spec": {"taskRunTemplate": {}}},
                  {"spec": {"taskRunTemplate": {"podTemplate": {}}}}]
        for s in shapes:
            for pol in (DENY[SHAPE], DENY[ISOLATION], WARN[ISOLATION]):
                for op in ("CREATE",):
                    with self.subTest(shape=s):
                        evaluate(pol, s, operation=op)  # must return, never raise


class Isolation(unittest.TestCase):
    def refused(self, obj, want="source-runner", policies=DENY):
        got = evaluate(policies[ISOLATION], obj)
        self.assertTrue(got, "admitted; expected a refusal")
        self.assertTrue(any(want in m for m in got), got)

    def test_hardened_reruns_are_admitted(self):
        for name in ["build", "build-pr", "test", "release", "deploy"]:
            with self.subTest(name):
                self.assertIn(evaluate(DENY[ISOLATION], rerun(name)), ([], None))
        self.assertEqual(evaluate(DENY[ISOLATION], rerun("build")), [])
        self.assertEqual(evaluate(DENY[ISOLATION], rerun("test")), [])
        # a Pipeline with no source tasks is not this policy's concern
        self.assertIsNone(evaluate(DENY[ISOLATION], rerun("release")))
        self.assertIsNone(evaluate(DENY[ISOLATION], rerun("deploy")))
        self.assertIsNone(evaluate(DENY[ISOLATION], promote()))

    def test_a_rerun_that_drops_the_isolation_is_refused(self):
        self.refused(rerun("build-pre-hardening"))
        o = rerun("build")
        del o["spec"]["taskRunSpecs"]
        self.refused(o)
        o = rerun("test")
        del o["spec"]["taskRunSpecs"]
        self.refused(o)
        for i in range(5):  # each source task, one at a time
            o = rerun("build")
            del o["spec"]["taskRunSpecs"][i]
            with self.subTest(dropped=i):
                self.refused(o)
        o = rerun("build")
        o["spec"]["taskRunSpecs"][0]["serviceAccountName"] = "pipeline-runner"
        self.refused(o)

    def test_the_pusher_must_be_image_pusher(self):
        o = rerun("build")
        del o["spec"]["taskRunSpecs"][5]
        self.refused(o, "image-pusher")
        o = rerun("build")
        o["spec"]["taskRunSpecs"][5]["serviceAccountName"] = "pipeline-runner"
        self.refused(o, "image-pusher")

    def test_upgrade_mode_warns_instead_of_denying(self):
        self.assertEqual(DENY[ISOLATION]["validationActions"], ["Deny"])
        self.assertEqual(WARN[ISOLATION]["validationActions"], ["Warn", "Audit"])
        self.assertEqual(DENY[ISOLATION]["failurePolicy"], "Fail")
        # the allow side stays Deny in both modes: warn mode admits today's runs, never a credentialed account on source code
        self.assertEqual(WARN[SHAPE]["validationActions"], ["Deny"])
        o = rerun("build-pre-hardening")
        self.assertEqual(evaluate(WARN[SHAPE], o), [])
        o = rerun("build")
        o["spec"]["taskRunSpecs"][0]["serviceAccountName"] = "image-pusher"
        self.assertTrue(evaluate(WARN[SHAPE], o))

    def test_only_glidepath_api_creates_are_in_scope(self):
        o = rerun("build-pre-hardening")
        self.assertIsNone(evaluate(DENY[ISOLATION], o, user="system:serviceaccount:tekton-pipelines:pipelines-as-code-controller"))
        self.assertIsNone(evaluate(DENY[ISOLATION], o, namespace="argocd"))
        self.assertIsNone(evaluate(DENY[ISOLATION], o, operation="UPDATE", old=o))


if __name__ == "__main__":
    unittest.main(verbosity=1)
