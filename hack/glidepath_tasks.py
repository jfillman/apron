"""The per-task accounts of Glidepath's run admission, checked against the Glidepath apron pins (pipeline trust T5).

glidepath-api's PipelineRun policy (templates/30-policy/kyverno-policies/tower-identity-writes.yaml) allows, and for a build
requires, taskRunSpecs entries for exactly the (Pipeline, task) pairs Glidepath's glidepath-control-plane values name in
cicdRunAdmission.sourceTasks, pusherTasks and cloudDeployerTasks. A Kyverno policy cannot read a Helm chart's values, so
versions.yaml (glidepathRunTasks) carries the lists next to the Glidepath pin, and this check compares them with the pinned
Glidepath's values.yaml on every render: a list that differs refuses the render, naming the Pipeline and the tasks.

Where the values come from, first match:
  APRON_GLIDEPATH_CHECK=off            skipped (a warning)
  APRON_GLIDEPATH_VALUES=<file>        a glidepath-control-plane values.yaml (a checkout's, or a fixture)
  otherwise                            git fetches charts/glidepath-control-plane/values.yaml at versions.glidepath from
                                       https://<scm.host>/<scm.owner>/glidepath.git; if that cannot be fetched the render goes
                                       on with a warning (the check is then not made, which the warning says)
Needs PyYAML (the values use anchors, which Apron's own YAML reader refuses); without it the check is skipped with a warning.
"""
import os
import subprocess
import sys
import tempfile

from apronlib import ApronError, get

KEYS = ("sourceTasks", "pusherTasks", "cloudDeployerTasks")
VALUES_PATH = "charts/glidepath-control-plane/values.yaml"


def differences(want, have):
    """want, have: {key: {pipeline: [tasks]}} -> a list of readable differences (empty when they hold the same pairs)."""
    out = []
    for key in KEYS:
        w, h = (want.get(key) or {}), (have.get(key) or {})
        for pipeline in sorted(set(w) | set(h)):
            ws, hs = set(w.get(pipeline) or []), set(h.get(pipeline) or [])
            if ws != hs:
                bits = []
                if hs - ws:
                    bits.append("missing here: " + ", ".join(sorted(hs - ws)))
                if ws - hs:
                    bits.append("not in Glidepath: " + ", ".join(sorted(ws - hs)))
                out.append(f"{key}.{pipeline}: " + "; ".join(bits))
    return out


def fetch(host, owner, ref):
    """The pinned Glidepath's values.yaml text, or raises OSError."""
    url = f"https://{host}/{owner}/glidepath.git"
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    with tempfile.TemporaryDirectory() as d:
        for cmd in (["git", "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout", "--branch", ref, url, d],
                    ["git", "-C", d, "show", f"HEAD:{VALUES_PATH}"]):
            r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
            if r.returncode != 0:
                raise OSError((r.stderr or "git failed").strip().splitlines()[-1])
        return r.stdout


def check(v, warn=lambda m: print(f"warning: {m}", file=sys.stderr)):
    """Raises ApronError when versions.glidepathRunTasks differs from the pinned Glidepath's values."""
    if os.environ.get("APRON_GLIDEPATH_CHECK", "") == "off":
        warn("APRON_GLIDEPATH_CHECK=off: versions.glidepathRunTasks is not compared with Glidepath's values")
        return
    want = get(v, "versions.glidepathRunTasks", None)
    if not want:
        raise ApronError("versions.glidepathRunTasks is empty: glidepath-api's PipelineRun policy needs Glidepath's sourceTasks, "
                         "pusherTasks and cloudDeployerTasks (versions.yaml)")
    try:
        import yaml
    except ImportError:
        warn("PyYAML is not installed: versions.glidepathRunTasks is not compared with Glidepath's values")
        return
    path = os.environ.get("APRON_GLIDEPATH_VALUES", "")
    try:
        if path:
            with open(path) as f:
                text = f.read()
            origin = path
        else:
            ref = get(v, "versions.glidepath")
            text = fetch(get(v, "scm.host"), get(v, "scm.owner"), ref)
            origin = f"glidepath {ref}"
    except (OSError, subprocess.SubprocessError) as e:
        if path:
            raise ApronError(f"APRON_GLIDEPATH_VALUES={path}: {e}")
        warn(f"could not fetch Glidepath's values.yaml ({e}): versions.glidepathRunTasks is not compared with it; "
             "set APRON_GLIDEPATH_VALUES=<a checkout's charts/glidepath-control-plane/values.yaml> to compare")
        return
    try:
        doc = yaml.safe_load(text) or {}
    except yaml.YAMLError as e:
        raise ApronError(f"{origin}: not valid YAML: {str(e).splitlines()[0] if str(e) else e}")
    if not isinstance(doc, dict) or not isinstance(doc.get("cicdRunAdmission") or {}, dict):
        raise ApronError(f"{origin}: not a Helm values file (a mapping with cicdRunAdmission)")
    have = doc.get("cicdRunAdmission") or {}
    if not any(have.get(k) for k in KEYS):
        raise ApronError(f"{origin}: cicdRunAdmission has no sourceTasks, pusherTasks or cloudDeployerTasks: this Glidepath does not "
                         "define per-task accounts, so glidepath-api's PipelineRun policy for them does not belong with it")
    diffs = differences(want, have)
    if diffs:
        raise ApronError(f"versions.glidepathRunTasks differs from {origin} (cicdRunAdmission): " + " | ".join(diffs) +
                         ". glidepath-api's PipelineRun policy would refuse runs Glidepath creates, or allow an account Glidepath "
                         "does not; update versions.yaml with the glidepath pin")
