#!/usr/bin/env python3
"""apron render: turn a cluster.yaml into the cluster's GitOps repo contents.

    python3 hack/render.py --cluster DIR/cluster.yaml --out DIR [--apron-root PATH] [--check]
    python3 hack/render.py --cluster DIR/cluster.yaml --print-values

Reads cluster.yaml, layers it over profiles/<profile>.yaml, runtimes/<runtime>.yaml and versions.yaml (cluster.yaml
wins), derives everything that follows from the cluster's name, then copies the selected templates/ paths
(templates/MANIFEST) into DIR, switching `#@if`/`#@end` lines and substituting @@TOKEN@@s strictly: an unknown token
or a leftover `@@` is an error naming file:line. Deterministic and re-runnable: files it rendered before and no longer
renders are removed (tracked in DIR/.apron-rendered); DIR/cluster.yaml and DIR/.git are never touched.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import ROOT, ApronError, evaluate, get, resolve  # noqa: E402

TOKEN = re.compile(r"@@([A-Z0-9_]+)@@")
STATE = ".apron-rendered"
KEEP = {"cluster.yaml", ".git", STATE, "clusters.yaml"}
NEVER_RENDER = {"MANIFEST", "TOKENS.md"}
# Tokens that may legitimately render empty (an optional value the chart treats as "not set").
MAY_BE_EMPTY = {"AUTOPILOT_GITHUB_WORKFLOWS", "GLIDEPATH_PROMOTER_REPO", "FLIGHT_PREFIX", "FLIGHT_PROMOTER_SUBJECT_RE", "TOWER_HOST_ALIAS_IP", "TOWER_BASE_URL", "ITSM_PROVIDER", "ITSM_WEBHOOK_URL"}


def tokens(v):
    """Every @@TOKEN@@ and where its value comes from (templates/TOKENS.md documents the same list)."""
    g = lambda k, d=None: get(v, k, d)  # noqa: E731
    scm_host = g("scm.host")
    t = {
        "CLUSTER_NAME": v["name"],
        "CLUSTER_DOMAIN": v["domain"],
        "ISSUER": v["issuer"],
        "REPO_URL": v["repoURL"],
        "TENANTS_REPO_URL": v["tenantsRepoURL"],
        "TENANTS_REPO_NAME": v["tenantsRepoName"],
        "FLEET_REPO_URL": g("fleet.repoURL") or v["repoURL"],
        "SCM_HOST": scm_host,
        "SCM_HOST_RE": re.escape(scm_host or ""),
        "SCM_OWNER": g("scm.owner"),
        "REGISTRY_HOST": g("registry.host"),
        "REGISTRY_OWNER": g("registry.owner"),
        "GATEWAY_NAMESPACE": g("gateway.namespace", "hangar-gateway"),
        "GATEWAY_NAME": g("gateway.name", "hangar"),
        "TRAEFIK_SERVICE_TYPE": g("traefik.serviceType"),
        "TRAEFIK_HTTP_NODEPORT": g("traefik.httpNodePort", ""),
        "TRAEFIK_HTTPS_NODEPORT": g("traefik.httpsNodePort", ""),
        "INFISICAL_URL": g("infisical.url", ""),
        "INFISICAL_NODEPORT": g("infisical.nodePort"),
        "INFISICAL_BOOTSTRAP_IMAGE_TAG": g("infisical.bootstrapImageTag"),
        "INFISICAL_PG_PASSWORD": g("generated.infisicalPgPassword", ""),
        "INFISICAL_REDIS_PASSWORD": g("generated.infisicalRedisPassword", ""),
        "REKOR_MYSQL_PASSWORD": g("generated.rekorMysqlPassword", ""),
        "REKOR_MYSQL_ROOT_PASSWORD": g("generated.rekorMysqlRootPassword", ""),
        "HUB_NAME": g("fleet.hub", ""),
        "HUB_DOMAIN": g("fleet.hubDomain", ""),
        "HUB_ADDRESS": g("fleet.hubAddress", ""),
        # The hub's API server, as this cluster reaches it (fleet.hubApiServer), its host for hostAliases, and its CA
        # (fleet.hubCaData, base64 PEM - public): where observability.remoteWrite sends trace metrics.
        "HUB_API_SERVER": g("fleet.hubApiServer", ""),
        "HUB_API_HOST": (g("fleet.hubApiServer", "") or "").split("://")[-1].split("/")[0].rsplit(":", 1)[0],
        "HUB_CA_DATA": g("fleet.hubCaData", ""),
        "RELAY_URL": g("fleet.relayUrl") or (f"http://{g('fleet.hubAddress') or g('fleet.hubDomain')}:30880"
                                             if (g("fleet.hubAddress") or g("fleet.hubDomain")) else ""),
        "TOWER_CLUSTER": g("tower.cluster", ""),
        "TOWER_ISSUER": g("tower.issuer", ""),
        "TOWER_NAMESPACE": g("tower.namespace"),
        "TOWER_BASE_URL": g("tower.baseUrl", ""),
        "TOWER_HOST_ALIAS_IP": g("tower.hostAliasIP", ""),
        "AWS_ACCOUNT_ID": g("aws.accountId", ""),
        # Who may sign in to Clearance as a person (D19 interim: people-dex's GitHub logins), comma-separated; empty
        # lets nobody in.
        "AUTOPILOT_PEOPLE": ",".join(g("autopilot.people", None) or []),
        "AUTOPILOT_PEOPLE_PRINCIPALS": ",".join(f"user:{p}" for p in (g("autopilot.people", None) or [])),
        # GitHub Actions workflows that may register deployments with Clearance (`clearance register`, clearance
        # provenance-app.md phase 2b): globs on the OIDC token's sub (repo:<owner>/<repo>:...). Empty: none, and the
        # gateway's GitHub OIDC verifier stays off.
        "AUTOPILOT_GITHUB_WORKFLOWS": ",".join(g("autopilot.githubWorkflows", None) or []),
        # Images a definition's runtime.image may pin beyond the runtime catalog (custom: an image built for an agent's
        # own repo), globs, e.g. ghcr.io/<owner>/*@sha256:*: the gateway checks definitions against them and clearance-api
        # lists them at GET /v1/runtimes for New agent. Empty: catalog images only.
        "AUTOPILOT_CUSTOM_IMAGES": ",".join(g("autopilot.customImages", None) or []),
        # The gateway's verifiers: Glidepath's gate checks, plus those workflows as Clearance principals (github:<sub>).
        "CLEARANCE_VERIFIERS": ",".join(["app-*-cicd/pipeline-runner"]
                                        + [f"github:{w}" for w in (g("autopilot.githubWorkflows", None) or [])]),
        # Glidepath's admin-owned release-signing policy (glidepath ADR-0027): YAML flow lists, "[]" when unset.
        "RELEASE_SIGNERS": json.dumps(list(g("releaseSigning.signers", None) or [])),
        "RELEASE_MERGERS": json.dumps(list(g("releaseSigning.mergers", None) or [])),
        # Apps whose GitHub-merge path is on, as a YAML flow map ("{}" when unset).
        "RELEASE_SIGNING_APPS": json.dumps(
            {a: {"githubMerge": {"enabled": True}} for a in (g("releaseSigning.githubMergeApps", None) or [])}
        ),
        # Glidepath's change-management gate (glidepath docs/admin/change-management.md); rendered only when set.
        "ITSM_PROVIDER": g("itsm.provider", ""),
        "ITSM_WEBHOOK_URL": g("itsm.webhookUrl", ""),
        # Glidepath's Ground/Flight registries and promotion (glidepath ADR-0029), YAML flow maps. Unset = the catalog
        # chart's defaults: ghcr.io under the GitHub owner for both, promotion and digest pinning off.
        "GLIDEPATH_REGISTRIES": json.dumps({
            zone: {"host": g(f"registries.{zone}.host", "") or "ghcr.io", "namespace": g(f"registries.{zone}.namespace", "") or ""}
            for zone in ("ground", "flight")
        }),
        "GLIDEPATH_PROMOTION": json.dumps({
            "enabled": bool(g("promotion.enabled", False)),
            "pinDigest": bool(g("promotion.pinDigest", False)),
            # The Flight promoter's dispatch repo (glidepath ADR-0029 phase 2), only when set.
            **({"promoter": {"repo": g("promotion.promoter.repo")}} if g("promotion.promoter.repo", "") else {}),
        }),
        "GLIDEPATH_PROMOTER_REPO": g("promotion.promoter.repo", ""),
        # Glidepath's per-app guardrail overrides ({app: {gate: {required: false}}}), a YAML flow map ("{}" when unset);
        # the catalog chart validates it (sast/provenance/image-promotion never advisory).
        "GLIDEPATH_GUARDRAIL_OVERRIDES_BY_APP": json.dumps(g("releaseGuardrailOverridesByApp", None) or {}),
        # Pipelines-as-Code's application-name (the check runs' name prefix), quoted: PaC's ConfigMap and the
        # glidepath-catalog's pipelinesAsCode.applicationName, which must match (glidepath docs/admin/github-app.md).
        "PAC_APPLICATION_NAME": json.dumps(g("pipelinesAsCode.applicationName", None) or "Glidepath"),
        **flight_admission_tokens(g),
        "AIRFRAME_CATALOG_VERSION": g("versions.airframe.catalog"),
        "AIRFRAME_REGISTRY_VERSION": g("versions.airframe.clusterRegistry"),
        "AIRFRAME_ANALYSIS_VERSION": g("versions.airframe.analysisCatalog"),
        "AIRFRAME_CHART_VERSION": g("versions.airframe.defaultChart"),
        "GLIDEPATH_VERSION": g("versions.glidepath"),
        "ARGOCD_CHART_VERSION": g("versions.argocdChart"),
        "CNPG_REPLICAS": g("cnpg.replicas"),
        "OBSERVABILITY_FULL": "true" if g("observability.full") else "false",
        "AI_TRIAGE_CPU_REQUEST": g("aiTriage.cpuRequest"),
        "AI_TRIAGE_MEMORY_REQUEST": g("aiTriage.memoryRequest"),
        "AI_TRIAGE_MEMORY_LIMIT": g("aiTriage.memoryLimit"),
        "XR_NAMESPACE_SUFFIX": "cicd" if v["isControlPlane"] else "xrs",
        "XR_APP_NAMESPACE": "argocd" if v["isControlPlane"] else "argocd-apps",
        "CALICO_VERSION": g("runtime.cni.version", ""),
        "KIND_POD_SUBNET": g("runtime.kind.podSubnet", ""),
        "KIND_MAX_PODS": g("runtime.kind.maxPods", ""),
        "KIND_HOST_HTTP_PORT": g("runtime.kind.hostHttpPort", ""),
        "KIND_HOST_HTTPS_PORT": g("runtime.kind.hostHttpsPort", ""),
    }
    return {k: ("" if x is None else str(x)) for k, x in t.items()}


def flight_admission_tokens(g):
    """Flight admission on an upper cluster (glidepath ADR-0029 phase 4): tenant pods run Flight images, each carrying
    the promotion attestation the promoter workflow signs, or an allow-listed third-party image. Audit+Warn until
    admission.flight.enforce; the tenant pull secret reads Flight only once admission.flight.pullFromFlight."""
    flight_ns = g("registries.flight.namespace", "") or ""
    promoter = g("promotion.promoter.repo", "") or ""
    on = bool(g("admission.flight.enabled", False))
    if on and not (flight_ns and promoter):
        raise ApronError("admission.flight.enabled needs registries.flight.namespace and promotion.promoter.repo")
    enforce = bool(g("admission.flight.enforce", False))
    return {
        "FLIGHT_PREFIX": f"{g('registries.flight.host', '') or 'ghcr.io'}/{flight_ns}/" if flight_ns else "",
        # The promoter workflow's keyless identity: GitHub Actions OIDC, the workflow file on main.
        "FLIGHT_PROMOTER_SUBJECT_RE": (f"^https://github\\.com/{re.escape(promoter)}/\\.github/workflows/promote\\.yaml"
                                       "@refs/heads/main$") if promoter else "",
        "FLIGHT_ADMISSION_ACTIONS": "[Deny]" if enforce else "[Audit, Warn]",
        "FLIGHT_ADMISSION_FAILURE_POLICY": "Fail" if enforce else "Ignore",
        "FLIGHT_ALLOWED_PREFIXES": json.dumps(list(g("admission.flight.allowedPrefixes", None) or [])),
        "REGISTRY_PULL_KEY": ("flight-registry-read-dockerconfigjson" if g("admission.flight.pullFromFlight", False)
                              else "registry-credentials-dockerconfigjson"),
    }


def manifest(root):
    rules = []
    with open(os.path.join(root, "templates", "MANIFEST")) as f:
        for n, line in enumerate(f, 1):
            s = line.split("#", 1)[0].strip() if not line.lstrip().startswith("#") else ""
            if not s:
                continue
            path, _, cond = s.partition(" ")
            rules.append((path, cond.strip(), n))
    return rules


def selected(rel, rules, v):
    best = None
    for path, cond, n in rules:
        if rel == path or (path.endswith("/") and rel.startswith(path)):
            if best is None or len(path) > len(best[0]):
                best = (path, cond, n)
    if best is None:
        return True
    try:
        return evaluate(best[1], v)
    except ApronError as e:
        raise ApronError(f"templates/MANIFEST:{best[2]}: {e}")


def render_text(text, rel, v, toks, errors):
    out, cond, start = [], None, 0
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if s.startswith("#@if "):
            if cond is not None:
                errors.append(f"{rel}:{n}: nested #@if (not supported)")
            try:
                cond = evaluate(s[5:], v)
            except ApronError as e:
                errors.append(f"{rel}:{n}: {e}")
                cond = False
            start = n
            continue
        if s == "#@end":
            if cond is None:
                errors.append(f"{rel}:{n}: #@end without #@if")
            cond = None
            continue
        if cond is False:
            continue

        def sub(m):
            k = m.group(1)
            if k not in toks:
                errors.append(f"{rel}:{n}: unknown token @@{k}@@")
                return m.group(0)
            if toks[k] == "" and k not in MAY_BE_EMPTY:
                errors.append(f"{rel}:{n}: token @@{k}@@ has no value for this cluster")
            return toks[k]

        line = TOKEN.sub(sub, line)
        if "@@" in line and not any(e.startswith(f"{rel}:{n}:") for e in errors):
            errors.append(f"{rel}:{n}: leftover '@@' after substitution")
        out.append(line)
    if cond is not None:
        errors.append(f"{rel}:{start}: #@if without #@end")
    return "\n".join(out)


def render(v, out_dir, root=ROOT):
    tdir = os.path.join(root, "templates")
    rules = manifest(root)
    toks = tokens(v)
    errors, files = [], {}
    for d, dirs, fs in os.walk(tdir):
        dirs.sort()
        for f in sorted(fs):
            rel = os.path.relpath(os.path.join(d, f), tdir)
            if rel in NEVER_RENDER or not selected(rel, rules, v):
                continue
            with open(os.path.join(d, f)) as fh:
                text = fh.read()
            files[rel] = render_text(text, rel, v, toks, errors)
    if errors:
        raise ApronError("render failed:\n  " + "\n  ".join(errors))
    for rel in files:
        if rel.split("/")[0] in KEEP:
            raise ApronError(f"templates/{rel} would overwrite a file Apron never touches")
    os.makedirs(out_dir, exist_ok=True)
    state = os.path.join(out_dir, STATE)
    before = set()
    if os.path.exists(state):
        with open(state) as fh:
            before = {l.strip() for l in fh if l.strip()}
    added, changed, removed = [], [], []
    for rel, text in sorted(files.items()):
        p = os.path.join(out_dir, rel)
        old = open(p).read() if os.path.exists(p) else None
        if old == text:
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)
        (changed if old is not None else added).append(rel)
    for rel in sorted(before - set(files)):
        if rel.split("/")[0] in KEEP:
            continue
        p = os.path.join(out_dir, rel)
        if os.path.exists(p):
            os.remove(p)
            removed.append(rel)
            d = os.path.dirname(p)
            while d != os.path.abspath(out_dir) and os.path.isdir(d) and not os.listdir(d):
                os.rmdir(d)
                d = os.path.dirname(d)
    with open(state, "w") as fh:
        fh.write("# Files apron render wrote here; it removes the ones it stops rendering. Do not edit.\n")
        fh.write("\n".join(sorted(files)) + "\n")
    return files, added, changed, removed


def cli_values(v):
    """The resolved values plus the derived keys the apron CLI reads (its contract)."""
    rt = get(v, "runtime.type")
    out = json.loads(json.dumps(v))
    out["context"] = v["name"]
    out["runtime"] = {
        "type": rt,
        "nodeExec": get(v, "runtime.nodeExec", ""),
        "kiac": get(v, "runtime.kiac") or {},
        "kind": {**(get(v, "runtime.kind") or {}), "config": get(v, "runtime.kind.config")} if rt == "kind" else {},
        "existing": get(v, "runtime.existing") or {},
    }
    if rt == "kind" and get(v, "runtime.cni.manifest"):
        out["cni"] = {"name": get(v, "runtime.cni.name"), "version": get(v, "runtime.cni.version"),
                      "manifest": get(v, "runtime.cni.manifest")}
    out["argocd"] = {"platform": {"install": "01-argocd-platform/install.yaml"},
                     "apps": {"application": "01-argocd-platform/argocd-apps-install/application.yaml"}}
    out["rootApp"] = "root-app-of-apps.yaml"
    # generated secret values never leave the cluster repo: drop them from the printed values
    out.pop("generated", None)
    secrets = [{
        "namespace": "argocd", "name": f"argocd-repo-creds-{get(v, 'scm.owner')}",
        "why": "Argo CD reads this cluster's private repos before External Secrets exists",
        "create": (f"kubectl --context {v['name']} -n argocd create secret generic argocd-repo-creds-"
                   f"{get(v, 'scm.owner')} --from-literal=type=git --from-literal=url=https://{get(v, 'scm.host')}/"
                   f"{get(v, 'scm.owner')} --from-literal=username=<value> --from-literal=password=<value> && "
                   f"kubectl --context {v['name']} -n argocd label secret argocd-repo-creds-{get(v, 'scm.owner')} "
                   "argocd.argoproj.io/secret-type=repo-creds"),
    }]
    if get(v, "infisical.host"):
        secrets += [
            {"namespace": "infisical", "name": "infisical-secrets",
             "why": "Infisical's root encryption key; losing it loses every secret",
             "create": (f"kubectl --context {v['name']} create namespace infisical; kubectl --context {v['name']} -n "
                        "infisical create secret generic infisical-secrets --from-literal=ENCRYPTION_KEY=<value: "
                        "openssl rand -hex 16> --from-literal=AUTH_SECRET=<value: openssl rand -base64 32> "
                        f"--from-literal=SITE_URL=http://infisical.{v['domain']}")},
            {"namespace": "infisical", "name": "infisical-bootstrap-credentials",
             "why": "first admin for the chart's autoBootstrap Job",
             "create": (f"kubectl --context {v['name']} -n infisical create secret generic "
                        "infisical-bootstrap-credentials --from-literal=INFISICAL_ADMIN_EMAIL=<value> "
                        "--from-literal=INFISICAL_ADMIN_PASSWORD=<value: openssl rand -base64 24> "
                        "--from-literal=INFISICAL_ADMIN_ORGANIZATION=hangar")},
        ]
    elif get(v, "components.externalSecrets"):
        secrets.append({
            "namespace": "crossplane-system", "name": "provider-infisical-creds",
            "why": "a universal-auth machine identity for this cluster, made in the hub's Infisical",
            "create": (f"kubectl --context {v['name']} create namespace crossplane-system; kubectl --context "
                       f"{v['name']} -n crossplane-system create secret generic provider-infisical-creds "
                       "--from-file=credentials=<value: a file holding {\"host\": \""
                       f"{(get(v, 'infisical.url') or '').removesuffix('/api')}"
                       "\", \"client_id\": \"...\", \"client_secret\": \"...\"}>")})
    out["bootstrapSecrets"] = secrets
    hosts = ["argocd", "argocd-apps"]
    if get(v, "infisical.host"):
        hosts.append("infisical")
    if get(v, "components.glidepath"):
        hosts += ["tekton", "rekor"]
    if get(v, "components.observability") and get(v, "observability.full"):
        hosts += ["grafana", "minio-console", "minio"]
    out["hostnames"] = [f"{h}.{v['domain']}" for h in hosts] if get(v, "components.gatewayRoutes") else []
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cluster", required=True, help="the cluster's cluster.yaml")
    ap.add_argument("--out", help="the cluster repo directory to render into (default: cluster.yaml's directory)")
    ap.add_argument("--apron-root", default=ROOT)
    ap.add_argument("--print-values", action="store_true", help="print the resolved values as JSON and exit")
    ap.add_argument("--no-check", action="store_true", help="render even if apron check fails (tests only)")
    a = ap.parse_args()
    try:
        v = resolve(a.cluster, a.apron_root)
        if a.print_values:
            json.dump(cli_values(v), sys.stdout, indent=2, sort_keys=True)
            print()
            return 0
        if not a.no_check:
            from check import violations
            bad = violations(v)
            if bad:
                for b in bad:
                    print(f"error: {b}", file=sys.stderr)
                return 1
        out = a.out or os.path.dirname(os.path.abspath(a.cluster))
        files, added, changed, removed = render(v, out, a.apron_root)
    except (ApronError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"rendered {v['name']} ({v['profile']} on {get(v, 'runtime.type')}) into {out}: {len(files)} files, "
          f"{len(added)} added, {len(changed)} changed, {len(removed)} removed")
    for label, lst in (("added", added), ("changed", changed), ("removed", removed)):
        for rel in lst:
            print(f"  {label:8} {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
