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
import ipaddress
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import ROOT, ApronError, evaluate, get, parse_vkey, resolve  # noqa: E402

TOKEN = re.compile(r"@@([A-Z0-9_]+)@@")
STATE = ".apron-rendered"
# signing-pki/ holds the cluster's public certificates (docs/signing-pki.md): committed by hand, never rendered over.
KEEP = {"cluster.yaml", ".git", STATE, "clusters.yaml", "signing-pki"}
NEVER_RENDER = {"MANIFEST", "TOKENS.md"}
# Tokens that may legitimately render empty (an optional value the chart treats as "not set").
MAY_BE_EMPTY = {"CLEARANCE_LEDGER_TOWER_HOSTNAMES_MORE", "CLEARANCE_GITHUB_APP_ID", "CLEARANCE_GATE_HOST_ALIAS", "GLIDEPATH_PROMOTER_REPO", "FLIGHT_PREFIX", "FLIGHT_PROMOTER_SUBJECT_RE", "TOWER_HOST_ALIAS_IP", "TOWER_BASE_URL", "ITSM_PROVIDER", "ITSM_WEBHOOK_URL", "CLEARANCE_GATE_WAIT_IMAGE", "CLEARANCE_LEDGER_HOST_ALIASES_MORE"}


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
        }),
        "GLIDEPATH_PROMOTER_REPO": g("promotion.promoter.repo", ""),
        # Glidepath's per-app guardrail overrides ({app: {gate: {required: false}}}), a YAML flow map ("{}" when unset);
        # the catalog chart validates it (sast/provenance/image-promotion never advisory).
        "GLIDEPATH_GUARDRAIL_OVERRIDES_BY_APP": json.dumps(g("releaseGuardrailOverridesByApp", None) or {}),
        # Pipelines-as-Code's application-name (the check runs' name prefix), quoted: PaC's ConfigMap and the
        # glidepath-catalog's pipelinesAsCode.applicationName, which must match (glidepath docs/admin/github-app.md).
        "PAC_APPLICATION_NAME": json.dumps(g("pipelinesAsCode.applicationName", None) or "Glidepath"),
        **flight_admission_tokens(g),
        **signing_tokens(v, g),
        **clearance_tokens(g),
        **clearance_gate_tokens(g),
        **clearance_ledger_tokens(g),
        **clearance_witness_tokens(g),
        **clearance_observe_tokens(v, g),
        **clearance_observe_aws_tokens(g),
        **clearance_admission_tokens(g),
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
    flight = g("registries.flight.namespace", "") or ""
    flight_default = [f"{g('registries.flight.host', '') or 'ghcr.io'}/{flight}/"] if flight else []
    registries = c("trustedRegistries", flight_default) or []
    for r in registries:
        if not str(r).endswith("/"):
            raise ApronError(f"clearance.trustedRegistries: {r!r} must end in '/' (the core's check is a prefix test)")
    return {
        "CLEARANCE_CHART_VERSION": g("versions.clearance.chart"),
        "CLEARANCE_IMAGE_DIGEST": g("versions.clearance.imageDigest"),
        # The namespace the chart installs into: clearance-system unless set. hangar-dev keeps autopilot-system,
        # where its evidence database (clearance-pg) has lived since AP-A2.
        "CLEARANCE_NAMESPACE": c("namespace", "clearance-system"),
        # The registered runtime provider: the Autopilot gateway's service account (55-autopilot gateway.yaml).
        "CLEARANCE_PROVIDERS": json.dumps([{"name": "autopilot-gateway", "version": g("versions.autopilot.gateway"),
                                            "principals": ["autopilot-system/clearance"],
                                            # it publishes its cluster-pinned definitions (PUT /v1/definitions)
                                            "definitions": True}] + list(c("extraProviders", []) or [])),
        "CLEARANCE_FOREIGN_SERVICE_ACCOUNTS_LIST": json.dumps(foreign),
        "CLEARANCE_FEED_READERS_LIST": json.dumps(list(c("feedReaders", []) or [])),
        "CLEARANCE_VERIFIERS_LIST": json.dumps(["app-*-cicd/pipeline-runner"] + [f"github:{w}" for w in workflows]
                                               + list(c("verifiers", []) or [])),
        "CLEARANCE_DELEGATES_LIST": json.dumps(([tower_sa] if tower_sa else []) + list(c("delegates", []) or [])),
        "CLEARANCE_NOTIFIERS_LIST": json.dumps(([tower_sa] if tower_sa else []) + list(c("notifiers", []) or [])),
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
        # The Clearance GitHub App's id (public; its key and webhook secret stay in Infisical).
        "CLEARANCE_GITHUB_APP_ID": str(c("githubAppId", "") or ""),
    }


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
    return {
        "CLEARANCE_GATE_ENV_REGEX": regex,
        # gate.apps limits the plugin to those apps, so a cluster can turn the gate on one app at a time. Empty: every
        # app in a protected environment. No backslash: the regex sits in a Go-template double-quoted string.
        "CLEARANCE_GATE_APP_REGEX": f"^({'|'.join(apps)})$" if apps else "^.*$",
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
                                              + ([g("versions.clearance.witnessImage")] if g("clearance.witness.enabled", False) and g("versions.clearance.witnessImage", "") else [])),
        "REGISTRY_PULL_KEY": ("flight-registry-read-dockerconfigjson" if g("admission.flight.pullFromFlight", False)
                              else "registry-credentials-dockerconfigjson"),
    }


def clearance_admission_tokens(g):
    """The Clearance gate on an upper cluster (clearance G-ARGO-2, templates/56-clearance-gate): Warn until
    clearance.gate.enforce, which flips validationActions and parameterNotFoundAction together (an enforcing binding
    with no active grant refuses every matched write in a protected namespace)."""
    enforce = bool(g("clearance.gate.enforce", False))
    sa = lambda key, d: "system:serviceaccount:" + (g(f"clearance.gate.{key}", None) or d)  # noqa: E731
    return {
        "CLEARANCE_GATE_ACTIONS": "[Deny, Audit]" if enforce else "[Warn, Audit]",
        "CLEARANCE_GATE_PARAM_NOT_FOUND": "Deny" if enforce else "Allow",
        # <namespace>:<name> of the service accounts the policies name: Argo CD's apps controller on this cluster, and
        # the grant-sync agent (the only writer of a ClearanceGrant).
        "CLEARANCE_GATE_ARGOCD_USER": sa("argocdServiceAccount", "argocd-apps:argocd-application-controller"),
        # The pinned wait image the policy exempts as G-ARGO-4's injected PreSync Job: the same digest reference the
        # plugin injects (versions.clearance.waitImage, required with clearance.gate.enabled); empty = no exemption.
        "CLEARANCE_GATE_WAIT_IMAGE": g("versions.clearance.waitImage", "") or "",
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


def render(v, out_dir, root=ROOT):
    tdir = os.path.join(root, "templates")
    rules = manifest(root)
    signing_dir_check(out_dir)
    v = dict(v, _dir=os.path.abspath(out_dir))
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
