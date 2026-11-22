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
import fnmatch
import ipaddress
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import LAB_ONLY_KEYS, ROOT, ApronError, clearance_slack_problems, clearance_slack_url, evaluate, get, lab_networking, parse_vkey, resolve  # noqa: E402

TOKEN = re.compile(r"@@([A-Z0-9_]+)@@")
STATE = ".apron-rendered"
# signing-pki/ holds the cluster's public certificates (docs/signing-pki.md): committed by hand, never rendered over.
KEEP = {"cluster.yaml", ".git", STATE, "clusters.yaml", "signing-pki"}
NEVER_RENDER = {"MANIFEST", "TOKENS.md"}
# Tokens that may legitimately render empty (an optional value the chart treats as "not set").
MAY_BE_EMPTY = {"CLEARANCE_LEDGER_TOWER_HOSTNAMES_MORE", "CLEARANCE_GITHUB_APP_ID", "CLEARANCE_GATE_HOST_ALIAS", "GLIDEPATH_PROMOTER_REPO", "FLIGHT_PREFIX", "FLIGHT_PROMOTER_SUBJECT_RE", "TOWER_HOST_ALIAS_IP", "TOWER_BASE_URL", "ITSM_PROVIDER", "ITSM_WEBHOOK_URL", "CLEARANCE_GATE_WAIT_IMAGE", "CLEARANCE_LEDGER_HOST_ALIASES_MORE", "AUTOPILOT_GO_IMAGE", "AUTOPILOT_GO_BROKER_URL", "AUTOPILOT_GO_GITHUB_OWNERS", "AUTOPILOT_GO_AIRFRAME_OWNER", "AUTOPILOT_GO_UPPER_CLUSTERS", "AUTOPILOT_GO_XR_NAMESPACES", "AUTOPILOT_GO_XR_NAMES", "AUTOPILOT_GO_DELEGATES", "AUTOPILOT_GO_NOTIFIERS", "AUTOPILOT_GO_AUDITORS"}


def signing_file(v, name):
    """A public file from the cluster repo's signing-pki/ directory (render() sets v["_dir"]), as a JSON string: valid
    YAML double-quoted, so a PEM bundle or a JSON document goes into a values file on one line. "" without a directory
    (a test that only lists the tokens); a missing or empty file is an error, because the flag that reads it is on."""
    d = v.get("_dir")
    if not d:
        return ""
    path = os.path.join(d, "signing-pki", name)
    try:
        with open(path) as fh:
            text = fh.read()
    except OSError:
        raise ApronError(f"signing-pki/{name} is missing in {d}: build it with hack/build-trust-root.sh (docs/signing-pki.md)")
    if not text.strip():
        raise ApronError(f"signing-pki/{name} is empty")
    return json.dumps(text)


def signing_dir_check(out_dir):
    """Every file in signing-pki/ must be public: refuse a private key in any of them, not only the two a template reads."""
    d = os.path.join(out_dir, "signing-pki")
    if not os.path.isdir(d):
        return
    for f in sorted(os.listdir(d)):
        path = os.path.join(d, f)
        if os.path.isfile(path):
            with open(path, errors="replace") as fh:
                if "PRIVATE KEY" in fh.read():
                    raise ApronError(f"signing-pki/{f} holds a private key: only public certificates and keys belong here")


def allowed_chart_repos(g):
    """cluster.yaml `allowedChartRepos`: operator-approved chart repository URLs a tenant's deploy.chart may name."""
    raw = g("allowedChartRepos", None)
    if raw is None:
        return []
    if not isinstance(raw, list) or not all(isinstance(r, str) for r in raw):
        raise ApronError("allowedChartRepos must be a list of repository URL strings")
    out = list(raw)
    for r in out:
        if not re.fullmatch(r"(https|http|ssh|git|oci)://[^\s,'\"\\?#]+", r):
            raise ApronError(f"allowedChartRepos: {r!r} is a repository URL (https://host/path), with no space, comma or quote")
        if not urllib.parse.urlparse(r).hostname:
            raise ApronError(f"allowedChartRepos: {r!r} has no host name (https://host/path)")
    return out


def gate_ledger_writer(g):
    """cluster.yaml promotion.gateLedger.writer: "" when unset, else direct or api (glidepath docs/admin/api.md, Gate verdicts)."""
    w = g("promotion.gateLedger.writer", None)
    if w in (None, ""):
        return ""
    if w not in ("direct", "api"):
        raise ApronError(f"promotion.gateLedger.writer is {w!r}: direct (the catalog's default) or api")
    return w


def gate_reports_transport(g):
    """cluster.yaml glidepath.gateReports.transport: "" when unset, else configmap or log (glidepath catalog gateReports.transport,
    pipeline trust T4, W-8: how api-compat-gate and policy-validation-gate hand their report to comment-pr-check-result)."""
    t = g("glidepath.gateReports.transport", None)
    if t in (None, ""):
        return ""
    if t not in ("configmap", "log"):
        raise ApronError(f"glidepath.gateReports.transport is {t!r}: configmap (the catalog's default) or log")
    return t


def tokens(v):
    """Every @@TOKEN@@ and where its value comes from (templates/TOKENS.md documents the same list)."""
    lab = lab_networking(v)
    # Lab-only keys read as unset off a lab runtime (docs/lab-networking.md): no hostAlias or lab address is ever rendered.
    g = lambda k, d=None: (d if (k in LAB_ONLY_KEYS and not lab) else get(v, k, d))  # noqa: E731
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
        # The chart repositories a tenant AppProject allows (sourceRepos) besides Airframe's: `allowedChartRepos` in
        # cluster.yaml. The AppProjects and the Clearance plugin's allow list read this one list, so they cannot differ.
        "ALLOWED_CHART_REPOS_LIST": json.dumps(allowed_chart_repos(g)),
        "CLEARANCE_GATE_CHART_REPOS": ",".join([f"https://{scm_host}/{g('scm.owner')}/airframe.git"] + allowed_chart_repos(g)),
        "REGISTRY_OWNER": g("registry.owner"),
        "GATEWAY_NAMESPACE": g("gateway.namespace", "hangar-gateway"),
        "GATEWAY_NAME": g("gateway.name", "hangar"),
        # How browsers and other clusters reach this gateway's hostnames: https where TLS ends at a cloud load balancer
        # (runtime eks), http on the lab's NodePorts.
        "GATEWAY_SCHEME": g("gateway.scheme", "") or "http",
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
        **tower_user_tokens(g),
        **autopilot_go_tokens(g),
        **traefik_lb_tokens(g),
        "AWS_ACCOUNT_ID": g("aws.accountId", ""),
        # Who may sign in to Clearance as a person (D19 interim: people-dex's GitHub logins), comma-separated; empty
        # lets nobody in.
        "AUTOPILOT_PEOPLE": ",".join(g("autopilot.people", None) or []),
        "AUTOPILOT_PEOPLE_PRINCIPALS": ",".join(f"user:{p}" for p in (g("autopilot.people", None) or [])),
        # Images a definition's runtime.image may pin beyond the runtime catalog (custom: an image built for an agent's
        # own repo), globs, e.g. ghcr.io/<owner>/*@sha256:*: the gateway checks definitions against them and clearance-api
        # lists them at GET /v1/runtimes for New agent. Empty: catalog images only.
        "AUTOPILOT_CUSTOM_IMAGES": ",".join(g("autopilot.customImages", None) or []),
        # Autopilot's hardened sandbox tier (autopilot.hardenedRuntime): function-agentrun's HANGAR_RUNTIME_CLASSES, the
        # same key that renders 55-autopilot/sandbox-runtime/. "{}" when unset: hardened runs are Rejected.
        "AUTOPILOT_RUNTIME_CLASSES": json.dumps({"hardened": g("autopilot.hardenedRuntime")}, separators=(",", ":"))
        if g("autopilot.hardenedRuntime", None) else "{}",
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
            # Who writes the gate ledger (glidepath promotion.gateLedger.writer, pipeline trust T4, W-8), only when set: unset
            # renders no key, so the catalog's own default (direct) stands and the render is unchanged.
            **({"gateLedger": {"writer": gate_ledger_writer(g)}} if gate_ledger_writer(g) else {}),
        }),
        "GLIDEPATH_PROMOTER_REPO": g("promotion.promoter.repo", ""),
        # Glidepath's per-app guardrail overrides ({app: {gate: {required: false}}}), a YAML flow map ("{}" when unset);
        # the catalog chart validates it (sast/provenance/image-promotion never advisory).
        "GLIDEPATH_GUARDRAIL_OVERRIDES_BY_APP": json.dumps(g("releaseGuardrailOverridesByApp", None) or {}),
        # Glidepath's per-cluster guardrail overrides ({gate: {required: bool}}), a YAML flow map ("{}" when unset, and the
        # catalog's key is then not rendered at all: a cluster that sets none renders byte-for-byte what it did before).
        "GLIDEPATH_GUARDRAIL_OVERRIDES": json.dumps(g("releaseGuardrailOverrides", None) or {}),
        # The catalog's gateReports ({transport: configmap|log}), a YAML flow map ("{}" when unset, and the catalog's key is then not
        # rendered at all: only used under `#@if glidepath.gateReports.transport`, so an unset cluster renders what it did before).
        "GLIDEPATH_GATE_REPORTS": json.dumps({"transport": gate_reports_transport(g)} if gate_reports_transport(g) else {}),
        # Pipelines-as-Code's application-name (the check runs' name prefix), quoted: PaC's ConfigMap and the
        # glidepath-catalog's pipelinesAsCode.applicationName, which must match (glidepath docs/admin/github-app.md).
        "PAC_APPLICATION_NAME": json.dumps(g("pipelinesAsCode.applicationName", None) or "Glidepath"),
        **flight_admission_tokens(g),
        **glidepath_run_tokens(g),
        # Kyverno's TTL cleanup interval (chart key features.ttlController.reconciliationInterval, chart default 1m) and the
        # AgentRun reaper's cron schedule (offset so it does not fire with the other platform CronJobs).
        "KYVERNO_TTL_INTERVAL": cron_free_duration(g("kyverno.ttlReconciliationInterval", "") or "1m", "kyverno.ttlReconciliationInterval"),
        "AGENTRUN_REAPER_SCHEDULE": cron_schedule(g("autopilot.reaperSchedule", "") or "7-59/10 * * * *", "autopilot.reaperSchedule"),
        **signing_tokens(v, g),
        **clearance_tokens(g),
        **clearance_tls_tokens(g),
        **clearance_slack_tokens(v, g),
        **clearance_gate_tokens(g),
        **clearance_ledger_tokens(g),
        **clearance_witness_tokens(g),
        **clearance_observe_tokens(v, g),
        **clearance_observe_aws_tokens(g),
        **clearance_targets_tokens(v, g),
        **clearance_attest_tokens(v, g),
        **clearance_admission_tokens(g),
        "AIRFRAME_CATALOG_VERSION": g("versions.airframe.catalog"),
        "AIRFRAME_REGISTRY_VERSION": g("versions.airframe.clusterRegistry"),
        "AIRFRAME_ANALYSIS_VERSION": g("versions.airframe.analysisCatalog"),
        "AIRFRAME_CHART_VERSION": g("versions.airframe.defaultChart"),
        "GLIDEPATH_VERSION": g("versions.glidepath"),
        # trust-manager's chart (and its image's tag) and image index digest (components.trustManager; versions.yaml).
        "TRUST_MANAGER_CHART_VERSION": g("versions.trustManager.chart", ""),
        "TRUST_MANAGER_IMAGE_DIGEST": g("versions.trustManager.imageDigest", ""),
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
        "CP_LEASE_DURATION": g("runtime.controlPlane.leaderElection.leaseDuration", ""),
        "CP_RENEW_DEADLINE": g("runtime.controlPlane.leaderElection.renewDeadline", ""),
        "CP_RETRY_PERIOD": g("runtime.controlPlane.leaderElection.retryPeriod", ""),
    }
    return {k: ("" if x is None else str(x)) for k, x in t.items()}


def autopilot_go_selected(g):
    """True when cluster.yaml says autopilot.gateway.implementation: go (default and anything else: the Python gateway)."""
    return (g("autopilot.gateway.implementation", None) or "python") == "go"


def autopilot_provider_version(g):
    """The version the Clearance core registers for the Autopilot gateway: it must be the image's own tag, which the
    gateway reports (AUTOPILOT_GATEWAY_VERSION) when it publishes its definitions."""
    if autopilot_go_selected(g):
        # autopilot.gateway.go.registeredVersion holds the registration where it is (the switch then does not touch the Clearance
        # Application, so the core is not restarted by it); unset: the Go image's tag, as before.
        return g("autopilot.gateway.go.registeredVersion", "") or g("autopilot.gateway.go.tag", "") or g("versions.autopilot.gateway")
    return g("versions.autopilot.gateway")


def autopilot_go_tokens(g):
    """The Go gateway's settings (autopilot.gateway.go.*; docs/clusters-file.md). Always computed, rendered only by the
    templates MANIFEST selects when autopilot.gateway.implementation is go (55-autopilot/gateway/*-go.yaml)."""
    go = "autopilot.gateway.go"
    lst = lambda k: ",".join(str(x) for x in (g(f"{go}.{k}", None) or []))  # noqa: E731
    host, owner = g("registry.host", ""), g("registry.owner", "")
    tag, digest = g(f"{go}.tag", "") or "", g(f"{go}.digest", "") or ""
    names = g(f"{go}.agentXRs.names", None) or {}
    tower = g("tower.cluster", "")
    tower_sa = f"{tower}/{g('tower.namespace', '')}/backstage-ingestor" if tower else ""
    people = [f"user:{p}" for p in (g("autopilot.people", None) or [])]
    rules = lambda cidrs: json.dumps([{"ipBlock": {"cidr": c}} for c in cidrs])  # noqa: E731
    return {
        "AUTOPILOT_GO_IMAGE": f"{host}/{owner}/autopilot-gateway-go:{tag}@{digest}" if tag and digest else "",
        # The secret the read API's DSN comes from (key uri): by default the one the Python read API already uses
        # (templates/55-autopilot/gateway/postgres.yaml, a CNPG-managed read-only role that passes the Go API's role check).
        # The migrate Job's name carries the image (a Job's pod template is immutable): a new image is a new Job.
        "AUTOPILOT_GO_MIGRATE_JOB": ("autopilot-gateway-migrate-" + re.sub(r"[^a-z0-9]+", "-", tag.removeprefix("gateway-go-").lower()).strip("-")
                                     + "-" + digest.removeprefix("sha256:")[:8]) if tag and digest else "",
        "AUTOPILOT_GO_READER_SECRET": g(f"{go}.readerSecret", "") or "autopilot-pg-reader",
        "AUTOPILOT_GO_BROKER_URL": g(f"{go}.brokerUrl", "") or "",
        "AUTOPILOT_GO_GITHUB_OWNERS": lst("githubOwners"),
        "AUTOPILOT_GO_AIRFRAME_OWNER": g(f"{go}.airframeOwner", "") or "",
        "AUTOPILOT_GO_UPPER_CLUSTERS": lst("airframeUpperClusters"),
        "AUTOPILOT_GO_XR_NAMESPACES": lst("agentXRs.namespaces"),
        "AUTOPILOT_GO_XR_NAMES": ",".join(f"{k}={v}" for k, v in sorted(names.items())),
        # Who may act for a person: Tower's backend (when there is a Tower) and any more the cluster names.
        "AUTOPILOT_GO_DELEGATES": ",".join(([tower_sa] if tower_sa else []) + list(g(f"{go}.delegates", None) or [])),
        "AUTOPILOT_GO_NOTIFIERS": ",".join(([tower_sa] if tower_sa else []) + list(g(f"{go}.notifiers", None) or [])),
        "AUTOPILOT_GO_AUDITORS": ",".join(people + list(g(f"{go}.auditors", None) or [])),
        # NetworkPolicy egress: the API server's addresses (cluster-specific, so said, never guessed) and any more.
        "AUTOPILOT_GO_API_SERVER_RULES": rules(g(f"{go}.egress.apiServerCIDRs", None) or []),
        "AUTOPILOT_GO_EXTRA_EGRESS_RULES": rules(g(f"{go}.egress.extraCIDRs", None) or []),
    }


def tower_user_tokens(g):
    """The Kubernetes user Tower's ServiceAccounts become on a cluster that trusts Tower's cluster.

    tower.trust structured (kubeadm/kind/kiac): 00-bootstrap/cluster-identity's JWT authenticator maps the token to
    hangar:<tower cluster>:<serviceAccount>. tower.trust eks-oidc (EKS, which takes no API server flags): an EKS OIDC
    identity provider config for Tower's cluster's issuer, usernameClaim sub and usernamePrefix hangar:<tower cluster>:,
    so the user is hangar:<tower cluster>:system:serviceaccount:<namespace>:<serviceAccount>."""
    tower, ns = g("tower.cluster", "") or "", g("tower.namespace", "") or ""
    eks = (g("tower.trust", "") or "structured") == "eks-oidc"

    def user(namespace, sa):
        if not tower:
            return ""
        return f"hangar:{tower}:system:serviceaccount:{namespace}:{sa}" if eks else f"hangar:{tower}:{sa}"
    return {
        "TOWER_USER_INGESTOR": user(ns, "backstage-ingestor"),
        "TOWER_USER_ACTOR": user(ns, "tower-actor"),
        "TOWER_USER_PROMETHEUS": user("observability", "kube-prometheus-stack-prometheus"),
    }


def traefik_lb_tokens(g):
    """Traefik's Service on a cloud load balancer (runtime eks): EKS Auto Mode's NLB, TLS ending at the NLB with an ACM
    certificate and forwarded to Traefik's plain-HTTP entrypoint, reachable only from traefik.loadBalancer.sourceRanges."""
    return {
        "TRAEFIK_LB_CLASS": g("traefik.loadBalancer.class", "") or "",
        "TRAEFIK_LB_SCHEME": g("traefik.loadBalancer.scheme", "") or "internet-facing",
        "TRAEFIK_LB_CERT_ARN": g("traefik.loadBalancer.certificateArn", "") or "",
        "TRAEFIK_LB_SOURCE_RANGES": json.dumps(list(g("traefik.loadBalancer.sourceRanges", None) or [])),
    }


def signing_tokens(v, g):
    """The Hangar signing PKI (C-2a, docs/signing-pki.md): the public chain and trusted root from signing-pki/, read only
    while the flag that uses each is on, and where Clearance's keyless attestation finds the platform's Fulcio and Rekor."""
    return {
        "SIGNING_FULCIO_CHAIN": signing_file(v, "fulcio-chain.pem") if g("signing.managedKeys") else "",
        "SIGNING_TRUSTED_ROOT": signing_file(v, "trusted-root.json") if g("signing.trustedRoot") else "",
        "CLEARANCE_FULCIO_URL": g("clearance.attestation.fulcioUrl", "") or "http://fulcio-server.fulcio-system.svc",
        "CLEARANCE_REKOR_URL": g("clearance.attestation.rekorUrl", "") or "http://rekor-server.rekor-system.svc",
        "CLEARANCE_ATTEST_AUDIENCE": g("clearance.attestation.audience", "") or "sigstore",
    }


def clearance_tokens(g):
    """Clearance as its own component (55-clearance, spec R-7): the clearance chart's pins and its values, from
    cluster.yaml's clearance: block. Each key falls back to the autopilot: key that configured Clearance before the
    split, so a cluster.yaml written for the old layout renders the same people and workflows. Lists render as YAML
    flow lists (JSON) for the Application's valuesObject."""
    c = lambda k, d=None: g(f"clearance.{k}", None) if g(f"clearance.{k}", None) is not None else d  # noqa: E731
    people = c("people", g("autopilot.people", None)) or []
    workflows = c("githubWorkflows", g("autopilot.githubWorkflows", None)) or []
    tower = g("tower.cluster", "")
    tower_sa = f"{tower}/{g('tower.namespace')}/backstage-ingestor" if tower else ""
    foreign = ([f"{g('tower.namespace')}/backstage-ingestor"] if tower else []) + list(c("foreignServiceAccounts", []) or [])
    # The target registry's publishers (docs/clearance-map.md): one provider per source, with the right to publish that
    # source's targets and nothing else; the remote ones are Tower's cluster's tokens, so their account is a foreign one.
    pubs = targets_publishers(g)
    publishers = [{"name": f"targets-{x['cluster']}", "version": str(g("versions.clearance.chart")),
                   "principals": [f"{x['namespace']}/clearance-targets" if not x["remote"]
                                  else f"{x['cluster']}/{x['namespace']}/clearance-targets"],
                   # `"kinds": []` grants no record kinds (Clearance 0.46.0+, clearance#158; an ABSENT kinds still means
                   # every non-observation kind): the publisher may only PUT its own source's targets.
                   "kinds": [], "targets": [x["cluster"]]} for x in pubs]
    for ns in sorted({x["namespace"] for x in pubs if x["remote"]}):
        foreign.append(f"{ns}/clearance-targets")
    flight = g("registries.flight.namespace", "") or ""
    flight_default = [f"{g('registries.flight.host', '') or 'ghcr.io'}/{flight}/"] if flight else []
    registries = c("trustedRegistries", flight_default) or []
    for r in registries:
        if not str(r).endswith("/"):
            raise ApronError(f"clearance.trustedRegistries: {r!r} must end in '/' (the core's check is a prefix test)")
    return {
        "CLEARANCE_CHART_VERSION": g("versions.clearance.chart"),
        "CLEARANCE_IMAGE_DIGEST": g("versions.clearance.imageDigest"),
        # The namespace the chart installs into: clearance-system unless clearance.namespace says otherwise (R-10d moved
        # hangar-dev's core, clearance-pg and the ledger volume there from autopilot-system).
        "CLEARANCE_NAMESPACE": c("namespace", "clearance-system"),
        # The Autopilot gateway's pod label app.kubernetes.io/name, the one place the core's and the api's NetworkPolicies
        # (and the pg_dump job's) learn it. The gateway stays in autopilot-system, a different namespace from the core's,
        # so each rule is a namespaceSelector plus this podSelector.
        "CLEARANCE_GATEWAY_POD_NAMES": json.dumps(list(c("gatewayPodNames", None) or ["autopilot-gateway"])),
        # The nightly pg_dump of clearance-pg (clearance-config backup.yaml, clearance.backup.enabled): cron schedule,
        # how many dumps the PVC keeps, and its size.
        "CLEARANCE_BACKUP_SCHEDULE": str(g("clearance.backup.schedule", "") or "17 2 * * *"),
        "CLEARANCE_BACKUP_KEEP": str(g("clearance.backup.keep", "") or 7),
        "CLEARANCE_BACKUP_STORAGE_SIZE": str(g("clearance.backup.storageSize", "") or "5Gi"),
        # clearance-pg's sizing (clearance-config postgres.yaml): clearance.postgres.* in cluster.yaml. `parameters` is merged
        # over the defaults key by key; primaryLease is the CNPG instance manager's lease timing (CNPG 1.30 .spec.primaryLease).
        "CLEARANCE_PG_CPU_REQUEST": str(g("clearance.postgres.cpuRequest", "") or "250m"),
        "CLEARANCE_PG_MEMORY_REQUEST": str(g("clearance.postgres.memoryRequest", "") or "512Mi"),
        "CLEARANCE_PG_MEMORY_LIMIT": str(g("clearance.postgres.memoryLimit", "") or "768Mi"),
        "CLEARANCE_PG_PARAMETERS": json.dumps({str(k): str(v) for k, v in {
            "shared_buffers": "128MB", "effective_cache_size": "384MB", "work_mem": "8MB",
            **(g("clearance.postgres.parameters", None) or {})}.items()}),
        "CLEARANCE_PG_PRIMARY_LEASE": json.dumps({k: int(v) for k, v in {
            "leaseDurationSeconds": 60, "renewDeadlineSeconds": 40, "retryPeriodSeconds": 15,
            **(g("clearance.postgres.primaryLease", None) or {})}.items()}),
        # The registered runtime provider: the Autopilot gateway's service account (55-autopilot gateway.yaml).
        "CLEARANCE_PROVIDERS": json.dumps([{"name": "autopilot-gateway", "version": autopilot_provider_version(g),
                                            "principals": ["autopilot-system/autopilot-gateway"],
                                            # it publishes its cluster-pinned definitions (PUT /v1/definitions)
                                            "definitions": True}] + publishers + list(c("extraProviders", []) or [])),
        "CLEARANCE_FOREIGN_SERVICE_ACCOUNTS_LIST": json.dumps(foreign),
        "CLEARANCE_FEED_READERS_LIST": json.dumps(list(c("feedReaders", []) or [])),
        "CLEARANCE_VERIFIERS_LIST": json.dumps(["app-*-cicd/pipeline-runner"] + [f"github:{w}" for w in workflows]
                                               + list(c("verifiers", []) or [])),
        "CLEARANCE_DELEGATES_LIST": json.dumps(([tower_sa] if tower_sa else []) + list(c("delegates", []) or [])),
        "CLEARANCE_NOTIFIERS_LIST": json.dumps(([tower_sa] if tower_sa else []) + list(c("notifiers", []) or [])),
        # Machine pollers that read coverage and observations only (clearance 0.41.1 api.observationReaders): Tower's backend.
        "CLEARANCE_OBSERVATION_READERS_LIST": json.dumps(([tower_sa] if tower_sa else []) + list(c("observationReaders", []) or [])),
        "CLEARANCE_PEOPLE_LIST": json.dumps(list(people)),
        "CLEARANCE_ADMINS_LIST": json.dumps([f"user:{p}" for p in (c("admins", people) or [])]),
        # extraAuditors are principal globs appended verbatim (a service account, not a user:), e.g. the AWS collector's
        # "clearance-system/clearance-observe-aws", which reads clearance-api for outcomes.
        "CLEARANCE_AUDITORS_LIST": json.dumps([f"user:{p}" for p in (c("auditors", people) or [])]
                                              + [str(a) for a in (c("extraAuditors", []) or [])]),
        "CLEARANCE_GITHUB_WORKFLOWS_LIST": json.dumps(list(workflows)),
        "CLEARANCE_RUNTIME_IMAGES_LIST": json.dumps(list(g("autopilot.customImages", None) or [])),
        "CLEARANCE_TRUSTED_REGISTRIES_LIST": json.dumps(list(registries)),
        "CLEARANCE_PROTECTED_ENVIRONMENTS_LIST": json.dumps(list(c("protectedEnvironments", []) or [])),
        "CLEARANCE_GATE_OUTSIDE_GROUPS_LIST": json.dumps(list(c("gateOutsideGroups", ["group:default/admins"]))),
        "CLEARANCE_GATE_RELEASE_STAMPS_LIST": json.dumps(list(c("gateReleaseStamps", ["/metadata/labels/app.kubernetes.io~1version", "/spec/template/metadata/labels/app.kubernetes.io~1version", "/metadata/annotations/hangar.io~1release-id"]))),
        # The web UI's egress to its IdP (clearance.web.enabled): NetworkPolicy has no host names, so the CIDRs the IdP's
        # host (dex.<domain>, through the Gateway) resolves to; default anywhere on 443, like the core's own JWKS egress.
        "CLEARANCE_WEB_IDP_PEERS": json.dumps([{"ipBlock": {"cidr": str(x)}} for x in (c("web", {}) or {}).get("idpCidrs", None) or ["0.0.0.0/0"]]),
        # clearance-api's coverage result cache (clearance chart api.coverageCacheSeconds, 0.51.0+; 0 to 300): off unless
        # clearance.api.coverageCacheSeconds is set above 0; the template renders the key only then (see TOKENS.md).
        "CLEARANCE_API_COVERAGE_CACHE_SECONDS": str(int((c("api", {}) or {}).get("coverageCacheSeconds", 0) or 0)),
        # The Clearance GitHub App's id (public; its key and webhook secret stay in Infisical).
        "CLEARANCE_GITHUB_APP_ID": str(c("githubAppId", "") or ""),
    }


def clearance_tls_tokens(g):
    """The core's and the API's https listener (clearance chart tls.*, I-43; A-19): clearance.tls.enabled, .plainHttp and
    .gatewayBackendTLS. Only used under `#@if clearance.tls.enabled`, except the routes' backend port, which is 8080 unless the
    Gateway re-encrypts (gatewayBackendTLS), so a cluster that sets none of them renders what it did before. apron check holds
    the combinations (hack/check.py)."""
    cluster_ca = bool(g("components.clusterCA", False))
    plain = g("clearance.tls.plainHttp", None)
    return {
        "CLEARANCE_TLS_PLAIN_HTTP": "false" if plain is False else "true",
        # The cluster CA's ClusterIssuer (components.clusterCA) or, without it, the chart's own namespaced CA (an empty name).
        "CLEARANCE_TLS_ISSUER_REF": json.dumps({"name": "hangar-cluster-ca", "kind": "ClusterIssuer"} if cluster_ca
                                               else {"name": "", "kind": "Issuer"}),
        "CLEARANCE_TLS_ISSUER_DESC": ("the cluster CA (ClusterIssuer hangar-cluster-ca, components.clusterCA)" if cluster_ca
                                      else "the chart's own namespaced CA (no components.clusterCA)"),
        "CLEARANCE_BACKEND_PORT": "8443" if (g("clearance.tls.enabled", False) and g("clearance.tls.gatewayBackendTLS", False)) else "8080",
    }


def clearance_slack_tokens(v, g):
    """Clearance's Slack service (clearance chart slack.*, docs/clearance-slack.md): the values of the `clearance.slack` block
    for the chart's slack.*, the people-dex client, the route, the link page's egress to the IdP and the DNS-01 issuer. Every
    token is neutral while clearance.slack.enabled is off (and only used under `#@if clearance.slack.enabled`), so a cluster
    that does not ask for it renders byte for byte what it did before; the values are checked when on."""
    k = lambda key, d="": g(f"clearance.slack.{key}", None) if g(f"clearance.slack.{key}", None) is not None else d  # noqa: E731
    out = {"CLEARANCE_SLACK_PUBLIC_URL": '""', "CLEARANCE_SLACK_HOST": "", "CLEARANCE_SLACK_CLIENT_ID": '""',
           "CLEARANCE_SLACK_TRANSPORT": "socket", "CLEARANCE_SLACK_WEB_URL": '""', "CLEARANCE_SLACK_ROUTES": "{}",
           "CLEARANCE_SLACK_IMAGE_DIGEST": "", "CLEARANCE_SLACK_IDP_PEERS": "[]", "CLEARANCE_SLACK_IDP_PORT": "443", "CLEARANCE_SLACK_HOST_ALIASES": "[]",
           "CLEARANCE_SLACK_ACME_EMAIL": "", "CLEARANCE_SLACK_ACME_SERVER": "", "CLEARANCE_SLACK_DNS01_ZONE_ID": "",
           "CLEARANCE_SLACK_DNS01_REGION": "", "CLEARANCE_SLACK_DNS01_ROLE_ARN": ""}
    if g("clearance.slack.enabled", None) is not True:
        return out
    problems = clearance_slack_problems(v)
    if problems:
        raise ApronError(problems[0])
    scheme = g("gateway.scheme", "") or "http"
    _, host = clearance_slack_url(v)
    domain = g("domain")
    web = k("webUrl", "") or (f"{scheme}://clearance.{domain}/changes/{{id}}" if g("clearance.web.enabled", False) else "")
    routes = k("routes", {}) or {}
    norm = {m: {str(n): str(c) for n, c in (routes.get(m) or {}).items()} for m in ("groups", "apps", "scopes")}
    norm.update({m: str(routes.get(m) or "") for m in ("default", "security", "ops")})
    # The link page reaches people-dex at its public issuer URL (discovery and the token endpoint), through the Gateway: the
    # address dex.<domain> has for the pod (idp.hostAlias, a lab with no DNS for it), else the CIDRs idp.cidrs (default
    # anywhere), on the Gateway's port for the scheme.
    alias = k("idp.hostAlias", "")
    peers = [{"ipBlock": {"cidr": str(__import__("ipaddress").ip_network(str(alias)))}}] if alias else \
        [{"ipBlock": {"cidr": str(c)}} for c in (k("idp.cidrs", None) or ["0.0.0.0/0"])]
    out.update({
        "CLEARANCE_SLACK_PUBLIC_URL": json.dumps(f"https://{host}"),
        "CLEARANCE_SLACK_HOST": host,
        "CLEARANCE_SLACK_CLIENT_ID": json.dumps(str(k("slackClientId"))),
        "CLEARANCE_SLACK_TRANSPORT": str(k("transport", "") or "socket"),
        "CLEARANCE_SLACK_WEB_URL": json.dumps(str(web)),
        "CLEARANCE_SLACK_ROUTES": json.dumps(norm),
        "CLEARANCE_SLACK_IMAGE_DIGEST": str(g("versions.clearance.slackImageDigest")),
        "CLEARANCE_SLACK_IDP_PEERS": json.dumps(peers),
        "CLEARANCE_SLACK_IDP_PORT": "443" if scheme == "https" else "80",
        "CLEARANCE_SLACK_HOST_ALIASES": json.dumps([{"ip": str(alias), "hostnames": [f"dex.{domain}"]}] if alias else []),
    })
    if (k("tls.mode", "") or "gateway-existing") == "dns01-route53":
        d = lambda key, df="": g(f"clearance.slack.tls.dns01.{key}", None) or df  # noqa: E731
        out.update({
            "CLEARANCE_SLACK_ACME_EMAIL": str(d("email")),
            "CLEARANCE_SLACK_ACME_SERVER": str(d("server", "https://acme-v02.api.letsencrypt.org/directory")),
            "CLEARANCE_SLACK_DNS01_ZONE_ID": str(d("hostedZoneID")),
            "CLEARANCE_SLACK_DNS01_REGION": str(d("region", "us-east-1")),
            "CLEARANCE_SLACK_DNS01_ROLE_ARN": str(d("roleARN")),
        })
    return out


def _glob_regex(glob):
    """A `<cluster glob>/<env glob>` entry as an anchored regex with no backslashes (it sits in a Go template string):
    `*` is any run of non-`/` characters, every other punctuation mark a one-character class."""
    out = []
    for ch in glob:
        if ch == "*":
            out.append("[^/]*")
        elif ch.isalnum():
            out.append(ch)
        else:
            out.append(f"[{ch}]")
    return "^" + "".join(out) + "$"


def clearance_gate_tokens(g):
    """The Argo CD gate (clearance docs/gate.md, G-ARGO-4/5): the plugin sidecar on argocd-apps' repo-server and the
    tenant-onboarding ApplicationSet's plugin source. Only used under `#@if clearance.gate.enabled`; the values are
    checked when it is on."""
    on = bool(g("clearance.gate.enabled", False))
    envs = list(g("clearance.protectedEnvironments", None) or [])
    if on:  # a cluster that does not turn the gate on is not held to the gate's reading of the key
        for e in envs:
            if str(e).count("/") != 1:
                raise ApronError(f"clearance.protectedEnvironments: {e!r} is '<cluster glob>/<env glob>'")
    regex = "|".join(_glob_regex(str(e)) for e in envs) if envs and on else "^.*$"
    cmp_image, wait_image = g("versions.clearance.cmpImage", "") or "", g("versions.clearance.waitImage", "") or ""
    if on and not (cmp_image and wait_image):
        raise ApronError("clearance.gate.enabled needs versions.clearance.cmpImage and waitImage (the plugin sidecar and "
                         "the PreSync wait images, by digest, from the clearance release that publishes them)")
    prev_wait = g("versions.clearance.previousWaitImage", "") or ""
    if on and prev_wait:
        if prev_wait == wait_image:
            raise ApronError("versions.clearance.previousWaitImage equals waitImage: remove it (it is for the one release after a wait-image change)")
        if not re.fullmatch(r"[^\s'\"]+@sha256:[0-9a-f]{64}", prev_wait):
            raise ApronError("versions.clearance.previousWaitImage is a digest reference (<repo>@sha256:<64 hex>)")
    ns = g("clearance.namespace", None) or "clearance-system"
    alias = g("clearance.gate.hostAlias", "") or ""
    if alias and "=" not in alias:
        raise ApronError("clearance.gate.hostAlias is 'ip=host[,host]'")
    alias_ip, _, alias_hosts = alias.partition("=")
    hosts = [h for h in alias_hosts.split(",") if h]
    apps = [str(a) for a in (g("clearance.gate.apps", None) or [])]
    if on:
        for a in apps:
            if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", a):
                raise ApronError(f"clearance.gate.apps: {a!r} is not an app name")
    # clearance.gate.canary: a second sidecar (clearance-cmp-canary, plugin `clearance-canary`) from another image, named
    # by the listed apps only (clearance docs/gate.md, "Rolling out a plugin release"). Unset: nothing renders and the
    # plugin name is the literal `clearance`, so the render is what it was.
    canary_image = g("clearance.gate.canary.image", "") or ""
    canary_apps_raw = g("clearance.gate.canary.apps", None) or []
    canary_apps = [str(a) for a in canary_apps_raw] if isinstance(canary_apps_raw, list) else []
    plugin_name = "clearance"
    if on and g("clearance.gate.canary", None):
        if not re.fullmatch(r"[^\s'\"]+@sha256:[0-9a-f]{64}", canary_image):
            raise ApronError("clearance.gate.canary.image is a digest reference (<repo>@sha256:<64 hex>)")
        if not isinstance(canary_apps_raw, list):
            raise ApronError("clearance.gate.canary.apps is a list of app names ([gate-api]), not a string")
        if not canary_apps:
            raise ApronError("clearance.gate.canary.apps lists the apps that use the canary plugin; an image with no app would run an idle sidecar")
        for a in canary_apps:
            if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", a):
                raise ApronError(f"clearance.gate.canary.apps: {a!r} is not an app name")
        if len(set(canary_apps)) != len(canary_apps):
            raise ApronError("clearance.gate.canary.apps lists an app twice")
        if apps and not set(canary_apps) <= set(apps):
            raise ApronError("clearance.gate.canary.apps names an app clearance.gate.apps leaves out: the gate does not cover it, so it would never use the plugin")
        plugin_name = ('{{ if regexMatch "^(' + "|".join(canary_apps) + ')$" .appName }}clearance-canary{{ else }}clearance{{ end }}')
    elif not on:
        canary_image = ""
    agent_api = g("clearance.gate.agent.apiURL", "") or ""
    agent_host = urllib.parse.urlparse(agent_api).hostname or ""
    agent_image = g("versions.clearance.argocdAgentImage", "") or ""
    if on and g("clearance.gate.agent", None):
        if not (agent_api and g("clearance.gate.agent.projects", None) and g("clearance.gate.agent.protectedNamespaces", None)):
            raise ApronError("clearance.gate.agent needs apiURL, projects and protectedNamespaces")
        if "@sha256:" not in agent_image or not g("versions.clearance.argocdAgentChart", ""):
            raise ApronError("clearance.gate.agent needs versions.clearance.argocdAgentImage (by digest) and argocdAgentChart")
    agent_repo, _, agent_digest = agent_image.partition("@")
    agent_chart = g("versions.clearance.argocdAgentChart", "") or ""
    # clearance.gate.tenantPlugin: false keeps the tenant-onboarding ApplicationSet from giving any Application the plugin, so
    # the gate covers only what opts in by annotation (clearance docs/gate.md, "Annotation opt-in"). Unset or true: as before.
    tenant_plugin = g("clearance.gate.tenantPlugin", None)
    if on and tenant_plugin is not None and not isinstance(tenant_plugin, bool):
        raise ApronError("clearance.gate.tenantPlugin is true or false")
    low = g("clearance.gate.lowerZone", None)
    if on and low is not None and not isinstance(low, bool):
        raise ApronError("clearance.gate.lowerZone is true or false")
    # The agent's service account (the policy names it as the only ClearanceGrant writer, and the core's provider entry as a principal): the chart's
    # default, or clearance.gate.agentServiceAccount "<namespace>:<name>", passed to the chart. The Application installs it in clearance-system.
    agent_sa = g("clearance.gate.agentServiceAccount", None)
    agent_sa_name = ""
    if on and agent_sa and g("clearance.gate.agent", None):
        sa_ns, _, agent_sa_name = str(agent_sa).partition(":")
        if sa_ns != "clearance-system" or not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", agent_sa_name):
            raise ApronError("clearance.gate.agentServiceAccount is clearance-system:<name> with gate.agent (the agent runs in clearance-system, as that account)")
    opt_in = g("clearance.gate.agent.optIn", None)
    agent_env = g("clearance.gate.agent.environment", None)
    if on and g("clearance.gate.agent", None):
        if opt_in is not None and not isinstance(opt_in, bool):
            raise ApronError("clearance.gate.agent.optIn is true or false")
        if agent_env is not None and not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", str(agent_env)):
            raise ApronError("clearance.gate.agent.environment is a DNS label (the environment of a protected namespace that carries no clearance.hangar.io/environment label)")
        if opt_in:
            # The opt-in is in the agent chart from clearance 0.49.0 (G-ARGO-10c); an older chart ignores the value and would render an agent that does nothing.
            try:
                chart_v = tuple(int(x) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", agent_chart).groups())
            except AttributeError:
                chart_v = (0, 0, 0)
            if chart_v < (0, 49, 0):
                raise ApronError("clearance.gate.agent.optIn needs versions.clearance.argocdAgentChart 0.49.0 or later (the annotation opt-in, clearance G-ARGO-10c)")
            # The core must let this cluster's agent report protected pairs (its provider entry's `protection`), or every report is a 403
            # and no Application is ever switched. Checked where the core runs here; a core on another cluster is that cluster's file.
            # The principal is the agent's service account as the core knows a caller on its own cluster: <namespace>/<name>. An entry counts when
            # its glob matches that principal, the cluster after the `=` is this one, and the same entry lists a principal that glob covers.
            cluster = g("name", "")
            principal = (g("clearance.gate.agentServiceAccount", None) or "clearance-system:clearance-argocd-agent").replace(":", "/", 1)

            def _grants_protection(entry):
                for x in (entry.get("protection") or []):
                    glob, _, cl = str(x).rpartition("=")
                    if cl == cluster and fnmatch.fnmatchcase(principal, glob) and any(
                            fnmatch.fnmatchcase(principal, str(q)) for q in (entry.get("principals") or [])):
                        return True
                return False
            if g("components.clearance", False) and not any(_grants_protection(p) for p in (g("clearance.extraProviders", None) or []) if isinstance(p, dict)):
                raise ApronError(f"clearance.gate.agent.optIn needs a clearance.extraProviders entry with protection: [\"{principal}={cluster}\"] "
                                 f"and {principal} among its principals (clearance docs/gate.md, \"Turning it on\"): without it the core refuses the agent's reports")
    return {
        "CLEARANCE_GATE_ENV_REGEX": regex,
        # gate.apps limits the plugin to those apps, so a cluster can turn the gate on one app at a time. Empty: every
        # app in a protected environment. No backslash: the regex sits in a Go-template double-quoted string.
        # tenantPlugin: false matches no app (an app name is never empty), so no tenant Application is given the plugin.
        "CLEARANCE_GATE_APP_REGEX": ("^$" if (on and tenant_plugin is False) else (f"^({'|'.join(apps)})$" if apps else "^.*$")),
        "CLEARANCE_AGENT_ENVIRONMENT": str(agent_env or ""),
        "CLEARANCE_AGENT_SERVICE_ACCOUNT": agent_sa_name,
        "CLEARANCE_GATE_HOST_ALIASES": json.dumps([{"ip": alias_ip, "hostnames": hosts}] if alias else []),
        "CLEARANCE_AGENT_CHART_VERSION": agent_chart,
        "CLEARANCE_AGENT_IMAGE_REPOSITORY": agent_repo,
        # The chart builds <repository>:<tag>, so the digest pin goes in the tag.
        "CLEARANCE_AGENT_IMAGE_TAG": f"v{agent_chart}@{agent_digest}" if agent_digest else "",
        "CLEARANCE_AGENT_API_URL": agent_api,
        "CLEARANCE_AGENT_PROJECTS": json.dumps(list(g("clearance.gate.agent.projects", None) or [])),
        "CLEARANCE_AGENT_PROTECTED_NAMESPACES": json.dumps(list(g("clearance.gate.agent.protectedNamespaces", None) or [])),
        "CLEARANCE_AGENT_HOST_ALIASES": json.dumps([{"ip": alias_ip, "hostnames": hosts + ([agent_host] if agent_host and agent_host not in hosts else [])}]
                                                   if alias else []),
        # How the plugin and the wait Job reach the core: in-cluster on the control plane, else a gateway route.
        "CLEARANCE_GATE_URL": g("clearance.gate.url", "") or f"http://clearance-core.{ns}.svc:8080",
        "CLEARANCE_GATE_HOST_ALIAS": alias,
        "CLEARANCE_CMP_IMAGE": cmp_image,
        "CLEARANCE_CMP_CANARY_IMAGE": canary_image,
        "CLEARANCE_PLUGIN_NAME": plugin_name,
        "CLEARANCE_WAIT_IMAGE": wait_image,
    }


def _host_alias(g, key):
    """`ip=host[,host]` -> (ip, [hosts]); ("", []) when unset."""
    alias = g(key, "") or ""
    if not alias:
        return "", []
    ip, sep, hosts = alias.partition("=")
    hs = [h for h in hosts.split(",") if h]
    if not sep or not ip or not hs:
        raise ApronError(f"{key} is 'ip=host[,host]'")
    return ip, hs


def clearance_ledger_tokens(g):
    """The evidence ledger on the cluster that runs the Clearance core (clearance C-3, docs/core.md "The evidence
    ledger"): the chart's ledger.* values. Every token is empty/neutral while clearance.ledger.enabled is off, so a
    cluster that does not ask for it renders byte-for-byte what it did before."""
    on = bool(g("clearance.ledger.enabled", False))
    out = {"CLEARANCE_LEDGER_WITNESS_POLICY": '""', "CLEARANCE_LEDGER_RETIRED_KEYS": '""',
           "CLEARANCE_LEDGER_KEY_SECRET": "", "CLEARANCE_LEDGER_EGRESS": "[]", "CLEARANCE_LEDGER_HOST_ALIASES": "[]", "CLEARANCE_LEDGER_HOST_ALIASES_MORE": "", "CLEARANCE_LEDGER_TOWER_HOSTNAMES_MORE": "",
           "CLEARANCE_LEDGER_CHECKPOINT_INTERVAL": "", "CLEARANCE_LEDGER_STALL_AFTER": "", "CLEARANCE_LEDGER_TIER3_WAIT": "true",
           "CLEARANCE_LEDGER_STORAGE_SIZE": "", "CLEARANCE_LEDGER_STORAGE_CLASS": ""}
    if not on:
        return out
    witnesses = g("clearance.ledger.witnesses", None) or []
    lines, names, ports = [], [], set()
    for w in witnesses:
        wname, vkey, url = (str(w.get(k, "")) for k in ("name", "vkey", "url")) if isinstance(w, dict) else ("", "", "")
        if not (re.fullmatch(r"[a-z0-9][-a-z0-9_]*", wname) and vkey and url):
            raise ApronError("clearance.ledger.witnesses: each witness is {name, vkey, url}")
        if wname in names:
            raise ApronError(f"clearance.ledger.witnesses: {wname!r} is listed twice")
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("http", "https") or not u.hostname or u.path not in ("", "/") or u.query:
            raise ApronError(f"clearance.ledger.witnesses: {wname}: url is http(s)://host[:port], the witness's base "
                             "(the log appends /add-checkpoint)")
        _, ktype = parse_vkey(vkey)
        if ktype != 0x04:
            raise ApronError(f"clearance.ledger.witnesses: {wname}: vkey is not a witness cosignature key (type 0x04): "
                             "list the key `clearance ledger keygen --witness` prints")
        names.append(wname)
        lines.append(f"witness {wname} {vkey} {url.rstrip('/')}")
        ports.add(u.port or (443 if u.scheme == "https" else 80))
    quorum = str(g("clearance.ledger.quorum", "all") or "all")
    if len(names) == 1:
        lines.append(f"quorum {names[0]}")
    elif names:
        if not re.fullmatch(r"all|any|[1-9][0-9]*", quorum) or (quorum.isdigit() and int(quorum) > len(names)):
            raise ApronError("clearance.ledger.quorum is all, any or a number of the listed witnesses")
        lines += [f"group witnesses {quorum} {' '.join(names)}", "quorum witnesses"]
    out["CLEARANCE_LEDGER_KEY_SECRET"] = str(g("clearance.ledger.keySecret", "") or f"hangar-ledger-{g('name')}-key")
    out["CLEARANCE_LEDGER_WITNESS_POLICY"] = json.dumps("\n".join(lines) + "\n")
    retired = [str(k) for k in (g("clearance.ledger.retiredKeys", None) or [])]
    for k in retired:
        parse_vkey(k)
    out["CLEARANCE_LEDGER_RETIRED_KEYS"] = json.dumps("\n".join(retired) + "\n" if retired else "")
    # Egress to the witnesses only: their port(s), and the host alias's address when the core reaches them by one.
    ip, hosts = _host_alias(g, "clearance.ledger.hostAlias")
    peer = [{"to": [{"ipBlock": {"cidr": f"{ip}/32"}}]}] if ip else [{}]
    out["CLEARANCE_LEDGER_EGRESS"] = json.dumps([{**peer[0], "ports": [{"protocol": "TCP", "port": p} for p in sorted(ports)]}])
    if ip:
        out["CLEARANCE_LEDGER_HOST_ALIASES"] = json.dumps([{"ip": ip, "hostnames": hosts}])
        # Kubernetes merges hostAliases by ip, so a second entry for Tower's address would replace the first: join its hostnames.
        if ip == g("tower.hostAliasIP", ""):
            out["CLEARANCE_LEDGER_TOWER_HOSTNAMES_MORE"] = "".join(", " + json.dumps(h) for h in hosts)
        else:
            out["CLEARANCE_LEDGER_HOST_ALIASES_MORE"] = ", " + json.dumps({"ip": ip, "hostnames": hosts})
    for key, tok, pat in (("checkpointInterval", "CHECKPOINT_INTERVAL", r"[0-9]+(ns|us|ms|s|m|h)([0-9]+(ns|us|ms|s|m|h))*"),
                          ("stallAfter", "STALL_AFTER", r"[0-9]+(ns|us|ms|s|m|h)([0-9]+(ns|us|ms|s|m|h))*")):
        val = str(g(f"clearance.ledger.{key}", "") or "")
        if val and not re.fullmatch(pat, val):
            raise ApronError(f"clearance.ledger.{key} is a Go duration (e.g. 1m)")
        out[f"CLEARANCE_LEDGER_{tok}"] = val
    out["CLEARANCE_LEDGER_TIER3_WAIT"] = "false" if g("clearance.ledger.tier3Wait", True) is False else "true"
    out["CLEARANCE_LEDGER_STORAGE_SIZE"] = str(g("clearance.ledger.storage.size", "") or "1Gi")
    out["CLEARANCE_LEDGER_STORAGE_CLASS"] = str(g("clearance.ledger.storage.storageClass", "") or "")
    return out


def clearance_observe_tokens(v, g):
    """Clearance's Kubernetes audit collector (clearance charts/clearance-observe-k8s). The API server's flags and the TLS
    Secret are hack/observe-audit.sh's. Only used where clearance.observe.enabled; the values are checked when it is on."""
    on = bool(g("clearance.observe.enabled", False))
    image, chart = g("versions.clearance.observeK8sImage", "") or "", g("versions.clearance.observeK8sChart", "") or ""
    namespaces = [str(n) for n in (g("clearance.observe.protectedNamespaces", None) or [])]
    kubelet_nodes = [str(n) for n in (g("clearance.observe.kubeletNodes", None) or [])]
    service_ip = str(g("clearance.observe.serviceIP", "") or "")
    if on:
        if "@sha256:" not in image or not chart:
            raise ApronError("clearance.observe.enabled needs versions.clearance.observeK8sImage (by digest) and observeK8sChart")
        if not namespaces:
            raise ApronError("clearance.observe.protectedNamespaces is required: the namespaces the collector watches")
        try:
            ipaddress.ip_address(service_ip)
        except ValueError:
            raise ApronError("clearance.observe.serviceIP is required: the collector's pinned ClusterIP, the one its "
                             "certificate names (hack/observe-audit.sh prepare --service-ip)") from None
    repo, _, digest = image.partition("@")
    # The instance that syncs tenant apps: the same choice as XR_APP_NAMESPACE.
    argocd_ns = str(g("clearance.observe.argocdNamespace", "") or ("argocd" if v["isControlPlane"] else "argocd-apps"))
    # The platform instance (G-ARGO-10a): where a second instance syncs this repository, its application controller's writes
    # are GitOps, attributed to the Application they carry. On the control plane one instance does both, so there is none to name
    # (the chart refuses a platform subject that is also the gated one).
    platform_ns = str(g("clearance.observe.platformGitopsNamespace", "") or ("" if v["isControlPlane"] else "argocd"))
    if platform_ns == argocd_ns:
        platform_ns = ""
    platform_subjects = [f"system:serviceaccount:{platform_ns}:argocd-application-controller"] if platform_ns else []
    return {
        "CLEARANCE_OBSERVE_CHART_VERSION": chart,
        "CLEARANCE_OBSERVE_IMAGE_REPOSITORY": repo,
        # The chart builds <repository>:<tag>, so the digest pin goes in the tag.
        "CLEARANCE_OBSERVE_IMAGE_TAG": f"v{chart}@{digest}" if digest else "",
        "CLEARANCE_OBSERVE_PROTECTED_NAMESPACES": json.dumps(namespaces),
        "CLEARANCE_OBSERVE_KUBELET_NODES": json.dumps(kubelet_nodes),
        "CLEARANCE_OBSERVE_ARGOCD_NAMESPACE": argocd_ns,
        # Both Argo CD instances name this service account the same; only the namespace differs.
        "CLEARANCE_OBSERVE_ARGO_SUBJECT": f"system:serviceaccount:{argocd_ns}:argocd-application-controller",
        "CLEARANCE_OBSERVE_SERVICE_IP": service_ip,
        "CLEARANCE_OBSERVE_PLATFORM_GITOPS_SUBJECTS": json.dumps(platform_subjects),
        "CLEARANCE_OBSERVE_PLATFORM_GITOPS_NAMESPACES": json.dumps([platform_ns] if platform_ns else []),
    }


def clearance_observe_aws_tokens(g):
    """Clearance's AWS collector (clearance charts/clearance-observe-aws), installed into clearance-system so its service
    account is the one the AWS roles trust. Only used where clearance.observeAWS.enabled; the values are checked when on.
    Registering the collector as provider observe-aws and as an auditor is cluster.yaml's (extraProviders, extraAuditors)."""
    k = lambda key, d="": g(f"clearance.observeAWS.{key}", None) if g(f"clearance.observeAWS.{key}", None) is not None else d  # noqa: E731
    on = bool(k("enabled", False))
    image, chart = g("versions.clearance.observeAWSImage", "") or "", g("versions.clearance.observeAWSChart", "") or ""
    account, queue, role = str(k("account") or ""), str(k("queueURL") or ""), str(k("roleARN") or "")
    apply_roles = [str(r) for r in (k("applyRoles", []) or [])]
    if on:
        if "@sha256:" not in image or not chart:
            raise ApronError("clearance.observeAWS.enabled needs versions.clearance.observeAWSImage (by digest) and observeAWSChart")
        for key, val in (("account", account), ("queueURL", queue), ("roleARN", role)):
            if not val:
                raise ApronError(f"clearance.observeAWS.{key} is required")
        if not apply_roles:
            raise ApronError("clearance.observeAWS.applyRoles is required: the role names that apply changes, which the collector matches")
    region = str(k("region", "") or "us-east-1")
    repo, _, digest = image.partition("@")
    jl = lambda key, d=(): json.dumps([str(x) for x in (k(key, list(d)) or [])])  # noqa: E731
    return {
        "CLEARANCE_OBSERVE_AWS_CHART_VERSION": chart,
        "CLEARANCE_OBSERVE_AWS_IMAGE_REPOSITORY": repo,
        "CLEARANCE_OBSERVE_AWS_IMAGE_TAG": f"v{chart}@{digest}" if digest else "",
        "CLEARANCE_OBSERVE_AWS_ACCOUNT": json.dumps(account),
        "CLEARANCE_OBSERVE_AWS_REGION": json.dumps(region),
        "CLEARANCE_OBSERVE_AWS_QUEUE_URL": json.dumps(queue),
        "CLEARANCE_OBSERVE_AWS_ENVIRONMENT": json.dumps(str(k("environment") or "")),
        "CLEARANCE_OBSERVE_AWS_ROLE_ARN": json.dumps(role),
        "CLEARANCE_OBSERVE_AWS_TRAIL_ROLE_ARN": json.dumps(str(k("trailRoleARN") or "")),
        "CLEARANCE_OBSERVE_AWS_TRAIL_NAME": json.dumps(str(g("clearance.observeAWS.trail.name", None) or "organization")),
        "CLEARANCE_OBSERVE_AWS_TRAIL_BUCKET": json.dumps(str(g("clearance.observeAWS.trail.bucket", None) or "")),
        "CLEARANCE_OBSERVE_AWS_TRAIL_PREFIX": json.dumps(str(g("clearance.observeAWS.trail.prefix", None) or "")),
        "CLEARANCE_OBSERVE_AWS_TRAIL_REGION": json.dumps(str(g("clearance.observeAWS.trail.region", None) or "us-east-1")),
        "CLEARANCE_OBSERVE_AWS_TRAIL_REGIONS": json.dumps([str(x) for x in (g("clearance.observeAWS.trail.regions", None) or ["us-east-1"])]),
        "CLEARANCE_OBSERVE_AWS_DATA_BUCKETS": jl("dataBuckets"),
        "CLEARANCE_OBSERVE_AWS_RULES": jl("rules", ("observe-aws-cloudtrail", "observe-aws-config")),
        "CLEARANCE_OBSERVE_AWS_APPLY_ROLES": json.dumps(apply_roles),
        "CLEARANCE_OBSERVE_AWS_SSO_ADMIN_ROLES": jl("ssoAdminRoles"),
        "CLEARANCE_OBSERVE_AWS_GOVERNED_ACCOUNTS": jl("governedAccounts"),
    }


TARGET_KINDS = ("k8s-namespace", "k8s-cluster", "aws-account", "github-environment", "other")
TARGET_ID = re.compile(r"^[a-z0-9][a-z0-9._:/-]{0,126}$")
TARGET_TIER = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
TARGET_SOURCE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
# An application namespace is app-<app>-<env> (Glidepath, airframe): the environment is the last word.
# The -cicd service accounts the Glidepath clearance-gate check may register changes as (W-8 pipeline-trust T4: the old shared
# runner and the new clearance-gate account). Each is a gate instance on the Map; drop "pipeline-runner" at W-8 step 7.
GLIDEPATH_GATE_ACCOUNTS = ("pipeline-runner", "clearance-gate")
APP_NAMESPACE = re.compile(r"^app-(?P<app>[a-z0-9][a-z0-9-]*)-(?P<env>[a-z0-9]+)$")


def targets_namespace(g):
    return str(g("clearance.namespace", None) or "clearance-system")


def targets_publishers(g):
    """Who publishes target sets to the core this cluster runs (docs/clearance-map.md): this cluster's own publisher (when
    clearance.targets.enabled and the core is here) and the remote clusters listed in clearance.targets.publishers. Each is
    {cluster, namespace, remote}; the core registers one provider per cluster, with the right to publish that source only."""
    if not g("components.clearance", False):
        return []
    out = []
    if g("clearance.targets.enabled", False):
        out.append({"cluster": g("name"), "namespace": targets_namespace(g), "remote": False})
    for p in g("clearance.targets.publishers", None) or []:
        out.append({"cluster": str(p.get("cluster", "")), "namespace": str(p.get("namespace") or "clearance-system"), "remote": True})
    return out


def validate_target(t, where):
    """The core's strict validation (clearance internal/targets), offline: a bad declaration stops the render, not the publish."""
    if not TARGET_ID.match(t.get("id", "")):
        raise ApronError(f"{where}: id {t.get('id')!r} is a lower-case name of at most 127 characters")
    if t.get("kind") not in TARGET_KINDS:
        raise ApronError(f"{where}: kind is one of {TARGET_KINDS}")
    for f in ("name", "group"):
        if not t.get(f):
            raise ApronError(f"{where}: {f} is required")
    if t.get("registry") and not TARGET_TIER.match(t["registry"]):
        raise ApronError(f"{where}: registry is a lower-case tier name")
    for gt in t["gates"]:
        if not (gt.get("type") and gt.get("instance")) or gt.get("mode") not in ("enforce", "flag"):
            raise ApronError(f"{where}: a gate is {{type, instance, mode: enforce|flag}}")
    for ob in t["observers"]:
        if not (ob.get("provider") and ob.get("source")):
            raise ApronError(f"{where}: an observer is {{provider, source}}")


def clearance_targets_tokens(v, g):
    """The target registry's publisher (templates/59-clearance-targets, docs/clearance-map.md): the targets this cluster
    declares for the Clearance Map, derived from what the renderer already knows. A namespace Clearance protects (the audit
    collector's, the Argo CD gate agent's) is a k8s-namespace target; an application namespace (app-<app>-<env>) names its
    app and environment, which attributes the deployment gate's records to it. The AWS account the collector watches is an
    aws-account target. Gates and observers are the ones this render wires; the scope is the cluster name (the audit
    collector's) or the account (the AWS collector's). clearance.targets.extra adds hand-declared targets."""
    out = {"CLEARANCE_TARGETS_SOURCE": "", "CLEARANCE_TARGETS_JSON": "", "CLEARANCE_TARGETS_SCHEDULE": "",
           "CLEARANCE_TARGETS_EGRESS": "[]", "CLEARANCE_TARGETS_URL": ""}
    if not g("clearance.targets.enabled", False):
        return out
    cluster = g("name")
    core_here = bool(g("components.clearance", False))
    gate_on = bool(g("clearance.gate.enabled", False))
    ns_of_core = targets_namespace(g)
    url = g("clearance.gate.url", "") or f"http://clearance-core.{ns_of_core}.svc:8080"
    if not TARGET_SOURCE.match(cluster):
        raise ApronError(f"clearance.targets: the cluster name {cluster!r} is not a source name")
    schedule = str(g("clearance.targets.schedule", "") or "3-59/15 * * * *")
    if len(schedule.split()) != 5:
        raise ApronError("clearance.targets.schedule is a five-field cron expression")
    tier = "flight" if (g("zone", "") == "upper" and g("registries.flight.namespace", "")) else "ground"
    tier = str(g("clearance.targets.registry", "") or tier)
    default_owner = str(g("clearance.targets.owner", "") or g("clearance.gateOwnerFallback", "") or "group:default/admins")
    owners = {str(k): str(x) for k, x in (g("clearance.targets.owners", None) or {}).items()}
    argo_instance = str(g("clearance.targets.argoInstance", "") or "argocd-agent")
    protected = [str(e) for e in (g("clearance.protectedEnvironments", None) or [])]
    observe_ns = [str(n) for n in (g("clearance.observe.protectedNamespaces", None) or [])] if g("clearance.observe.enabled", False) else []
    agent_ns = [str(n) for n in (g("clearance.gate.agent.protectedNamespaces", None) or [])] if gate_on and g("clearance.gate.agent", None) else []
    gate_apps = [str(a) for a in (g("clearance.gate.apps", None) or [])]
    targets = []
    for ns in sorted(set(observe_ns) | set(agent_ns)):
        m = APP_NAMESPACE.match(ns)
        app, env = (m.group("app"), m.group("env")) if m else ("", "")
        gates = []
        if app:
            # The Glidepath clearance-gate check registers the change as a service account of the app's -cicd namespace (the
            # core's CLEARANCE_VERIFIERS entries app-*-cicd/pipeline-runner and, from W-8, app-*-cicd/clearance-gate): that principal is what the record's change names
            # (registered_by), so it is the gate's instance. It refuses (enforce) where the environment is protected; elsewhere
            # a change clears at tier 0 and is recorded (flag).
            # An empty clearance.protectedEnvironments protects EVERY environment (the core fails closed), so unset is enforce.
            prot = any(fnmatch.fnmatchcase(f"{cluster}/{env}", e) for e in protected) if protected else True
            # W-8 step 1 (additive): during the split-runner overlap the check may run as either account, so declare both
            # principals (GLIDEPATH_GATE_ACCOUNTS) so neither is undeclared. Until an app has moved, its unused instance
            # shows as silent (info only, clearance internal/api/map.go:705). Step 7 drops pipeline-runner.
            for sa in GLIDEPATH_GATE_ACCOUNTS:
                gates.append({"type": "glidepath", "instance": f"app-{app}-cicd/{sa}", "mode": "enforce" if prot else "flag"})
            if gate_on and (ns in agent_ns if agent_ns else (not gate_apps or app in gate_apps)):
                # The Argo CD gate's agent reports every sync outcome and refused write as provider argocd-agent.
                gates.append({"type": "g-argo", "instance": argo_instance, "mode": "enforce" if g("clearance.gate.enforce", False) else "flag"})
        t = {"id": f"{cluster}.{ns}", "name": ns, "kind": "k8s-namespace", "group": cluster, "registry": tier,
             "scope": cluster, "gates": gates,
             "observers": [{"provider": "observe-k8s", "source": "k8s-audit-webhook"}] if ns in observe_ns else []}
        if app:
            t.update({"env": env, "app": app, "owner": owners.get(app, default_owner)})
        targets.append(t)
    if g("clearance.observeAWS.enabled", False):
        account = str(g("clearance.observeAWS.account", "") or "")
        aenv = str(g("clearance.observeAWS.environment", "") or "")
        agates = [{"type": str(x.get("type", "")), "instance": str(x.get("instance", "")), "mode": str(x.get("mode", ""))}
                  for x in (g("clearance.observeAWS.gates", None) or [])]
        t = {"id": f"aws.{account}", "name": f"aws-{aenv}" if aenv else f"aws-{account}", "kind": "aws-account", "group": account,
             "scope": account, "owner": default_owner, "gates": agates,
             "observers": [{"provider": "observe-aws", "source": "observe-aws"}]}
        if aenv:
            t["env"] = aenv
        targets.append(t)
    for i, x in enumerate(g("clearance.targets.extra", None) or []):
        t = {"gates": [], "observers": [], **{k: x[k] for k in x}}
        validate_target(t, f"clearance.targets.extra[{i}]")
        targets.append(t)
    seen = set()
    for t in targets:
        validate_target(t, f"target {t['id']}")
        if t["id"] in seen:
            raise ApronError(f"clearance.targets: target id {t['id']} is declared twice")
        seen.add(t["id"])
        for k in [k for k, x in t.items() if x in ("", None)]:
            del t[k]
    targets.sort(key=lambda t: t["id"])
    doc = json.dumps({"targets": targets}, indent=2, sort_keys=True)
    egress = []
    if core_here and not g("clearance.gate.url", ""):
        egress = [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": ns_of_core}},
                           "podSelector": {"matchLabels": {"app.kubernetes.io/name": "clearance-core"}}}],
                   "ports": [{"protocol": "TCP", "port": 8080}]}]
    else:
        parsed = urllib.parse.urlparse(url)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        ip, _hosts = _host_alias(g, "clearance.gate.hostAlias")
        if not ip:
            # An egress rule with no `to` allows every destination on that port: never render one.
            raise ApronError("clearance.targets.enabled with a core on another cluster needs clearance.gate.hostAlias "
                             "('ip=host'): the publisher's egress is pinned to that address, and an unpinned rule would allow the port to anywhere")
        egress = [{"to": [{"ipBlock": {"cidr": f"{ip}/32"}}], "ports": [{"protocol": "TCP", "port": port}]}]
    out.update({"CLEARANCE_TARGETS_SOURCE": cluster, "CLEARANCE_TARGETS_SCHEDULE": schedule, "CLEARANCE_TARGETS_URL": url,
                "CLEARANCE_TARGETS_EGRESS": json.dumps(egress),
                "CLEARANCE_TARGETS_JSON": "\n".join("    " + line for line in doc.split("\n"))})
    return out


def clearance_attest_tokens(v, g):
    """What clearance-api verifies stored attestations with (api.attest.*, clearance docs/clearance-api.md): public material
    only. The core signs keyless (clearance.attestation.keyless), so the trust is the cluster's trusted root, signing-pki/
    trusted-root.json, and the identity and issuer the certificate names: the core's service account and this cluster's
    issuer. The ConfigMap clearance-attest-trust holds the root (55-clearance/clearance-config/attest-trust.yaml)."""
    on = bool(g("clearance.attestation.keyless", False)) and bool(g("signing.trustedRoot", False)) and bool(g("components.clearance", False))
    ns = targets_namespace(g)
    # clearance-api refuses a plain-http Rekor URL unless it is loopback or an in-cluster Service name (it is a link people
    # follow), so the public Gateway host is offered only where the Gateway serves https; an http lab shows the index as text.
    public_rekor = (f"https://rekor.{g('domain')}" if g("components.glidepath", False) and g("components.gatewayRoutes", False)
                    and str(g("gateway.scheme", "") or "http") == "https" else "")
    return {
        "CLEARANCE_ATTEST_TRUST_ROOT_JSON": signing_file(v, "trusted-root.json") if on else '""',
        "CLEARANCE_ATTEST_IDENTITY": f"https://kubernetes.io/namespaces/{ns}/serviceaccounts/clearance-core",
        "CLEARANCE_ATTEST_ISSUER": str(g("clearance.attestation.issuer", "") or g("issuer")),
        "CLEARANCE_ATTEST_REKOR_PUBLIC_URL": str(g("clearance.attestation.rekorPublicUrl", "") or public_rekor),
    }


def clearance_witness_tokens(g):
    """The ledger's witness on a protected cluster (clearance charts/clearance-witness, rendered as plain manifests in
    templates/56-clearance-witness: the chart is not published, only the image). Empty while it is off."""
    on = bool(g("clearance.witness.enabled", False))
    image = g("versions.clearance.witnessImage", "") or ""
    domain = g("domain", "") or ""
    out = {"CLEARANCE_WITNESS_NAME": "", "CLEARANCE_WITNESS_KEY_SECRET": "", "CLEARANCE_WITNESS_IMAGE": "", "CLEARANCE_WITNESS_HOST": "", "CLEARANCE_WITNESS_LOGS": '""',
           "CLEARANCE_WITNESS_STORAGE_SIZE": "", "CLEARANCE_WITNESS_STORAGE_CLASS": ""}
    if not on:
        return out
    if "@sha256:" not in image:
        raise ApronError("clearance.witness.enabled needs versions.clearance.witnessImage, by digest (the clearance-witness "
                         "image from the clearance release that publishes it)")
    wname = str(g("clearance.witness.name", "") or "")
    if not re.fullmatch(r"[a-z0-9][-a-z0-9_]*", wname):
        raise ApronError("clearance.witness.name is the witness's name (lowercase letters, digits, - and _): the name the log's "
                         "operator lists it under")
    logs = [str(k) for k in (g("clearance.witness.logsVkeys", None) or [])]
    if not logs:
        raise ApronError("clearance.witness.logsVkeys is required: the public verifier keys of the logs it cosigns for")
    for k in logs:
        if parse_vkey(k)[1] != 0x01:
            raise ApronError(f"clearance.witness.logsVkeys: {k!r} is not a log's verifier key (type 0x01)")
    host = str(g("clearance.witness.host", "") or f"witness.{domain}")
    if not re.fullmatch(r"[a-z0-9]([-a-z0-9.]*[a-z0-9])?", host):
        raise ApronError("clearance.witness.host is a host name")
    out.update({"CLEARANCE_WITNESS_NAME": wname, "CLEARANCE_WITNESS_IMAGE": image, "CLEARANCE_WITNESS_HOST": host,
                "CLEARANCE_WITNESS_KEY_SECRET": str(g("clearance.witness.keySecret", "") or f"hangar-witness-{g('name')}-key"),
                "CLEARANCE_WITNESS_LOGS": json.dumps("\n".join(logs) + "\n"),
                "CLEARANCE_WITNESS_STORAGE_SIZE": str(g("clearance.witness.storage.size", "") or "64Mi"),
                "CLEARANCE_WITNESS_STORAGE_CLASS": str(g("clearance.witness.storage.storageClass", "") or "")})
    return out


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
        # With the Argo CD gate on, the plugin's PreSync wait Job runs in the tenant's namespace from clearance-wait,
        # which is not a Flight image: exactly that digest is allowed, nothing else from its repository.
        "FLIGHT_ALLOWED_PREFIXES": json.dumps(list(g("admission.flight.allowedPrefixes", None) or [])
                                              + ([g("versions.clearance.waitImage")] if g("clearance.gate.enabled", False) and g("versions.clearance.waitImage", "") else [])
                                              + ([g("versions.clearance.previousWaitImage")] if g("clearance.gate.enabled", False) and g("versions.clearance.waitImage", "") and g("versions.clearance.previousWaitImage", "") else [])
                                              + ([g("versions.clearance.witnessImage")] if g("clearance.witness.enabled", False) and g("versions.clearance.witnessImage", "") else [])),
        "REGISTRY_PULL_KEY": ("flight-registry-read-dockerconfigjson" if g("admission.flight.pullFromFlight", False)
                              else "registry-credentials-dockerconfigjson"),
    }


def cron_free_duration(value, key):
    """A Go duration of whole minutes or hours (15m, 1h), as Kyverno's ttl controller parses it."""
    value = str(value)
    if not re.fullmatch(r"[1-9][0-9]*[mh]", value):
        raise ApronError(f"{key} is {value!r}: a duration in whole minutes or hours, such as 15m or 1h")
    return value


def cron_schedule(value, key):
    value = str(value)
    if len(value.split()) != 5:
        raise ApronError(f"{key} is a five-field cron expression")
    return value


def gate_concurrency(g):
    """glidepath.gateConcurrency: a whole number of at least 1 (unset or empty = no limit, returns 0 and the values are left out)."""
    v = g("glidepath.gateConcurrency", None)
    if v in (None, ""):
        return 0
    if isinstance(v, bool) or not isinstance(v, int) or v < 1:
        raise ApronError(f"glidepath.gateConcurrency is {v!r}: a whole number of at least 1, or unset for no limit")
    return v


def gitops_pipeline_provenance(g):
    """glidepath.gitopsRepoProvenance: default_branch or source (unset or empty = the chart's default, the values are left out)."""
    v = g("glidepath.gitopsRepoProvenance", None)
    if v in (None, ""):
        return ""
    if v not in ("default_branch", "source"):
        raise ApronError(f"glidepath.gitopsRepoProvenance is {v!r}: default_branch, source, or unset (Pipelines-as-Code's pipelinerun_provenance)")
    return v


def glidepath_run_tokens(g):
    """glidepath-api's PipelineRun policies (30-policy/kyverno-policies/tower-identity-writes.yaml, pipeline trust T5): the
    per-task accounts of Glidepath's run admission (versions.glidepathRunTasks, checked against the pinned Glidepath by
    hack/glidepath_tasks.py), and glidepath.sourceIsolation, which sets the action of the isolation rule here AND of Glidepath's
    own cicd-run-source-isolation binding (cicdRunAdmission.sourceIsolationActions in the control plane's values), so the two
    creators of a run are held to the same rule at the same time."""
    lists = g("versions.glidepathRunTasks", None) or {}
    mode = str(g("glidepath.sourceIsolation", "") or "deny")
    if mode not in ("deny", "warn"):
        raise ApronError(f"glidepath.sourceIsolation is {mode!r}: deny (default) or warn (only while upgrading to a Glidepath that "
                         "generates the source-runner entries; glidepath docs/admin/security.md, upgrade note)")
    shape = str(g("glidepath.runShape", "") or "deny")
    if shape not in ("deny", "warn"):
        raise ApronError(f"glidepath.runShape is {shape!r}: deny (default) or warn (only while upgrading)")
    rp = g("glidepath.refProtection", None)
    rp = "off" if rp is False else str(rp if rp not in (None, "") else "required")  # a bare YAML off reads as false
    if rp not in ("required", "off"):
        raise ApronError(f"glidepath.refProtection is {rp!r}: required (default) or off")
    classes = g("glidepath.runStorageClasses", None) or []
    if not isinstance(classes, list) or not all(isinstance(c, str) and c for c in classes):
        raise ApronError("glidepath.runStorageClasses must be a list of StorageClass names")
    sources = dict(lists.get("sourceTasks") or {})
    return {
        "GLIDEPATH_SOURCE_TASKS": json.dumps(sources, sort_keys=True),
        "GLIDEPATH_SOURCE_TASK_PIPELINES": json.dumps(sorted(sources)),
        "GLIDEPATH_PUSHER_TASKS": json.dumps(dict(lists.get("pusherTasks") or {}), sort_keys=True),
        "GLIDEPATH_CLOUD_DEPLOYER_TASKS": json.dumps(dict(lists.get("cloudDeployerTasks") or {}), sort_keys=True),
        "GLIDEPATH_RECORD_WRITER_TASKS": json.dumps(dict(lists.get("recordWriterTasks") or {}), sort_keys=True),
        "GLIDEPATH_CLEARANCE_TASKS": json.dumps(dict(lists.get("clearanceTasks") or {}), sort_keys=True),
        "GLIDEPATH_TEST_RUNNER_TASKS": json.dumps(dict(lists.get("testRunnerTasks") or {}), sort_keys=True),
        "GLIDEPATH_RUN_SHAPE_ACTIONS": "[Deny]" if shape == "deny" else "[Warn, Audit]",
        "GLIDEPATH_REF_PROTECTION": json.dumps(rp),
        # Pipelines-as-Code's per-repository concurrency limit for every app's Repository CRs (omitted from the values when unset).
        "GLIDEPATH_GATE_CONCURRENCY": str(gate_concurrency(g)),
        # Where Pipelines-as-Code reads every gitops repository's .tekton files from (omitted from the values when unset).
        "GLIDEPATH_GITOPS_PROVENANCE": gitops_pipeline_provenance(g),
        "GLIDEPATH_API_STORAGE_CLASSES": json.dumps(classes),
        "GLIDEPATH_SOURCE_ISOLATION_ACTIONS": "[Deny]" if mode == "deny" else "[Warn, Audit]",
    }


def _cel_safe_url(key, url):
    """An http(s) URL that can sit in a single-quoted CEL string literal: parsed with urllib (an IPv6 host in brackets is fine),
    with a host, a valid port, no user info, query or fragment, and no quote, backslash, space or control character, the only
    characters that could end the literal or change what it says."""
    bad = ApronError(f"{key} is {url!r}: an http(s) URL (scheme, host, optional port and path) with no quote, backslash or space")
    if any(c in url for c in "'\"\\") or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url):
        raise bad
    try:
        u = urllib.parse.urlsplit(url)
        u.port  # noqa: B018 - raises ValueError for a port that is not a number in range
    except ValueError:
        raise bad from None
    if u.scheme not in ("http", "https") or not u.hostname or u.username is not None or u.password is not None or u.query or u.fragment:
        raise bad


def clearance_admission_tokens(g):
    """The Clearance gate on an upper cluster (clearance G-ARGO-2, templates/56-clearance-gate): Warn until
    clearance.gate.enforce, which flips validationActions and parameterNotFoundAction together (an enforcing binding
    with no active grant refuses every matched write in a protected namespace)."""
    enforce = bool(g("clearance.gate.enforce", False))
    sa = lambda key, d: "system:serviceaccount:" + (g(f"clearance.gate.{key}", None) or d)  # noqa: E731
    # clearance.gate.waitCAConfigMap (I-43, A-17): the ConfigMap (key ca.crt) the wait Job may mount as its CA, the
    # trust-manager Bundle's target in each destination namespace. Unset: the policy renders byte for byte as before and
    # refuses any second volume. Only read under `#@if clearance.gate.waitCAConfigMap`; it is a CEL string literal there, so
    # it must be a ConfigMap name (a DNS subdomain: no quote can reach the expression).
    wait_ca = g("clearance.gate.waitCAConfigMap", None)
    if wait_ca is not None and wait_ca != "" and not (
            isinstance(wait_ca, str) and len(wait_ca) <= 253 and
            re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*", wait_ca)):
        raise ApronError(f"clearance.gate.waitCAConfigMap is {wait_ca!r}: a ConfigMap name (a DNS subdomain), the trust-manager "
                         "Bundle the wait Job mounts its CA from; unset for none")
    gate_ca = g("clearance.gate.caConfigMap", None)
    if gate_ca is not None and gate_ca != "" and not (
            isinstance(gate_ca, str) and len(gate_ca) <= 253 and
            re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*", gate_ca)):
        raise ApronError(f"clearance.gate.caConfigMap is {gate_ca!r}: a ConfigMap name (a DNS subdomain), the cluster CA's "
                         "ConfigMap the plugin and the agent trust; unset for none")
    inject = g("clearance.gate.waitCAInject", None)
    if inject is not None and not isinstance(inject, bool):
        raise ApronError("clearance.gate.waitCAInject is true or false")
    if inject and not wait_ca:
        raise ApronError("clearance.gate.waitCAInject needs clearance.gate.waitCAConfigMap: the plugin would inject a CA volume "
                         "the admission policy refuses (set the policy's key first, plan step 5a)")
    ns = g("clearance.namespace", None) or "clearance-system"
    gate_url = g("clearance.gate.url", "") or f"http://clearance-core.{ns}.svc:8080"
    prev_url = str(g("clearance.gate.previousURL", "") or "")
    if prev_url:
        _cel_safe_url("clearance.gate.previousURL", prev_url)
        if prev_url == gate_url:
            raise ApronError("clearance.gate.previousURL equals clearance.gate.url: remove it (it is for the one release after a url change)")
        _cel_safe_url("clearance.gate.url (with previousURL set)", gate_url)
    return {
        "CLEARANCE_GATE_WAIT_CA_CONFIGMAP": wait_ca or "",
        # clearance.gate.caConfigMap (A-19): the ConfigMap (key ca.crt) the plugin sidecar (argocd-apps) and the agent
        # (clearance-system) trust as extra roots for an https core and API. Only read under `#@if clearance.gate.caConfigMap`.
        "CLEARANCE_GATE_CA_CONFIGMAP": gate_ca or "",
        # The CEL test of the wait Job's CLEARANCE_URL. With clearance.gate.previousURL set (one release only) it is a list of the
        # current and the previous URL, so a wait Job or cached manifest made before a clearance.gate.url change keeps working
        # where the policy enforces. Unset: the single-URL test, byte for byte as before.
        "CLEARANCE_GATE_URL_MATCH": (
            "variables.waitctr.env[0].value in ['%s', '%s']" % (gate_url, prev_url) if prev_url
            else "variables.waitctr.env[0].value == '%s'" % gate_url),
        "CLEARANCE_GATE_ACTIONS": "[Deny, Audit]" if enforce else "[Warn, Audit]",
        "CLEARANCE_GATE_PARAM_NOT_FOUND": "Deny" if enforce else "Allow",
        # <namespace>:<name> of the service accounts the policies name: Argo CD's apps controller on this cluster, and
        # the grant-sync agent (the only writer of a ClearanceGrant).
        "CLEARANCE_GATE_ARGOCD_USER": sa("argocdServiceAccount", "argocd-apps:argocd-application-controller"),
        # The pinned wait image the policy exempts as G-ARGO-4's injected PreSync Job: the same digest reference the
        # plugin injects (versions.clearance.waitImage, required with clearance.gate.enabled); empty = no exemption.
        "CLEARANCE_GATE_WAIT_IMAGE": g("versions.clearance.waitImage", "") or "",
        # The CEL test of the Job's container image. With versions.clearance.previousWaitImage set (one release only) it is a
        # list of the new and the previous digest, so a wait Job or cached manifest naming the old digest keeps working once
        # this policy is deployed. It does not order the roll-out: the policy must update before the sidecar generates the
        # new image (nothing orders them; the policy syncs in seconds, the repo-server takes minutes). Unset: the
        # single-image test, as before.
        "CLEARANCE_GATE_WAIT_IMAGE_MATCH": (
            "variables.waitctr.image in ['%s', '%s']" % (g("versions.clearance.waitImage", ""), g("versions.clearance.previousWaitImage"))
            if g("versions.clearance.waitImage", "") and g("versions.clearance.previousWaitImage", "")
            else "variables.waitctr.image == '%s'" % (g("versions.clearance.waitImage", "") or "")),
        "CLEARANCE_GATE_AGENT_USER": sa("agentServiceAccount", "clearance-system:clearance-argocd-agent"),
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


def tenant_gated_set_flags(g):
    """clearance.gate.agent.gatedSet (W-43): the tenant-onboarding chart renders a second ApplicationSet,
    tenant-onboarding-gated, for the environments whose identity.yaml says `clearanceGate: true` (Airframe
    ApplicationEnvironment spec.clearanceGate), and tenant-onboarding stops generating them. clearance.gate.agent.gatedSetHandover
    opens the handover window (both sets applicationsSync: create-update). Both default off; off, the chart is what it was.
    Returned as the `_tenantGatedSet` / `_tenantGatedHandover` values the templates' #@if lines read."""
    gated, handover = g("clearance.gate.agent.gatedSet", None), g("clearance.gate.agent.gatedSetHandover", None)
    for key, val in (("gatedSet", gated), ("gatedSetHandover", handover)):
        if val is not None and not isinstance(val, bool):
            raise ApronError(f"clearance.gate.agent.{key} is true or false")
    if gated:
        # Only where the agent runs the annotation opt-in: the gated set exists for the agent, and without it the set's
        # Applications would sit annotated with nothing to switch them (and nothing to un-switch them).
        gate_here = g("zone", "") == "upper" or bool(g("clearance.gate.lowerZone", False))
        if not (gate_here and g("clearance.gate.enabled", False) and g("clearance.gate.agent", None) and g("clearance.gate.agent.optIn", False)):
            raise ApronError("clearance.gate.agent.gatedSet needs the gate and its agent on this cluster (clearance.gate.enabled, clearance.gate.agent, "
                             "clearance.gate.agent.optIn: true, and zone: upper or clearance.gate.lowerZone: true)")
        # Not with tenantPlugin (default true): tenant-onboarding would give an environment the static plugin source, and a
        # handover into the gated set keeps that source (its ignore rule preserves /spec/sources), so the agent refuses the
        # Application ("on the plugin and the agent did not put it there") and it stays on a static plugin source the gated set
        # never updates. Which environments are gated is data (identity.yaml), not known here, so the combination is refused.
        if g("clearance.gate.tenantPlugin", None) is not False:
            raise ApronError("clearance.gate.agent.gatedSet needs clearance.gate.tenantPlugin: false: an Application tenant-onboarding put on the "
                             "static plugin keeps that source when it is handed over to tenant-onboarding-gated, and the agent refuses to switch it "
                             "(apron README, \"Gated environments\")")
    if handover and not gated:
        raise ApronError("clearance.gate.agent.gatedSetHandover is the handover window between tenant-onboarding and tenant-onboarding-gated: it needs clearance.gate.agent.gatedSet")
    return {"_tenantGatedSet": bool(gated), "_tenantGatedHandover": bool(handover)}


def render(v, out_dir, root=ROOT):
    tdir = os.path.join(root, "templates")
    rules = manifest(root)
    signing_dir_check(out_dir)
    v = dict(v, _dir=os.path.abspath(out_dir), **tenant_gated_set_flags(lambda k, d=None: get(v, k, d)))
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
        "controlPlane": get(v, "runtime.controlPlane") or {},
        "kiac": get(v, "runtime.kiac") or {},
        "kind": {**(get(v, "runtime.kind") or {}), "config": get(v, "runtime.kind.config")} if rt == "kind" else {},
        "existing": get(v, "runtime.existing") or {},
        "eks": get(v, "runtime.eks") or {},
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
        if get(v, "gateway.fleetRoutes"):
            hosts += ["relay", "pac"]
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
        if not a.no_check and get(v, "components.policy") and get(v, "components.towerAccessHub"):
            from glidepath_tasks import check as check_glidepath_tasks
            check_glidepath_tasks(v)
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
