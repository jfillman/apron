#!/usr/bin/env python3
"""apron check: validate a cluster's resolved config (and optionally the fleet file) against Apron's invariants.

    python3 hack/check.py --cluster DIR/cluster.yaml [--fleet FLEET/clusters.yaml]

Exit 0 when valid; otherwise one line per violation on stderr and exit 1. Ported from the old
hack/customize-cluster.sh, plus the one-name rule and the fleet-file rules.
"""
import argparse
import os
import re
import sys
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import LAB_ONLY_KEYS, ApronError, clearance_slack_problems, get, lab_networking, load_yaml, parse_vkey, resolve  # noqa: E402

DEFAULT_ISSUER = "https://kubernetes.default.svc.cluster.local"
DNS1123 = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
ROLES = ("control-plane", "workloads", "platform-services")
# A managed cluster's own issuer: EKS publishes https://oidc.eks.<region>.amazonaws.com/id/<hex> for every cluster.
EKS_ISSUER = re.compile(r"^https://oidc\.eks\.[a-z0-9-]+\.amazonaws\.com/id/[0-9A-Fa-f]+$")


HEARTBEAT = re.compile(r"[1-9][0-9]*[smh]")
# The agent chart's alerts.checkedAtStaleAfter (Apron keeps the chart's default): a heartbeat must stay below it.
CHECKED_AT_STALE_AFTER_S = 15 * 60


def _agent_chart(v):
    try:
        return tuple(int(x) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(get(v, "versions.clearance.argocdAgentChart") or "")).groups())
    except AttributeError:
        return (0, 0, 0)


def gate_agent_i44_problems(v):
    """clearance.gate.agent.{grantExpiry, ha, statusHeartbeat, alerts} and the chart's gate.enforce rule (clearance
    docs/gate.md, "The grant-expiry webhook"). Called only with the gate and its agent on this cluster."""
    out = []
    add = out.append
    on = lambda key: get(v, key) is True  # noqa: E731
    ge, ha, hb, al = (get(v, f"clearance.gate.agent.{k}") for k in ("grantExpiry", "ha", "statusHeartbeat", "alerts"))
    for key, val, keys in (("grantExpiry", ge, ("enabled", "mode", "acceptResidualRisk")), ("ha", ha, ("enabled",)), ("alerts", al, ("enabled",))):
        if val is None:
            continue
        if not isinstance(val, dict):
            add(f"clearance.gate.agent.{key} is a mapping ({{{', '.join(keys)}}})")
            continue
        for k in sorted(set(val) - set(keys)):
            add(f"clearance.gate.agent.{key}.{k} is not a setting (only {', '.join(keys)})")
        for k in keys:
            if k != "mode" and val.get(k) is not None and not isinstance(val.get(k), bool):
                add(f"clearance.gate.agent.{key}.{k} is true or false")
    ge = ge if isinstance(ge, dict) else {}
    if ge.get("mode") is not None and ge.get("mode") not in ("audit", "enforce"):
        add(f"clearance.gate.agent.grantExpiry.mode is {ge.get('mode')!r}: audit (allow, warn and record; failurePolicy Ignore) or enforce (refuse; Fail)")
    if hb is not None and not (isinstance(hb, str) and HEARTBEAT.fullmatch(hb)):
        add(f"clearance.gate.agent.statusHeartbeat is {hb!r}: a positive duration of one unit (90s, 5m, 1h)")
    ge_on = ge.get("enabled") is True
    enforce = ge_on and ge.get("mode") == "enforce"
    used = [k for k, val in (("grantExpiry", ge), ("ha", ha), ("statusHeartbeat", hb), ("alerts", al)) if val not in (None, {}, "")]
    if used and _agent_chart(v) < (0, 55, 0):
        add(f"clearance.gate.agent.{', '.join(used)} need versions.clearance.argocdAgentChart 0.55.0 or later (the grant-expiry webhook, "
            "agent HA and the staleness alerts, I-44): an older chart ignores them")
    if ge.get("mode") == "enforce" and not ge_on:
        add("clearance.gate.agent.grantExpiry.mode: enforce needs grantExpiry.enabled: true")
    if ge_on and not on("components.certManager"):
        add("clearance.gate.agent.grantExpiry needs components.certManager: the webhook's serving certificate and its CA are cert-manager's "
            "(the CA injector writes the configuration's caBundle)")
    alerts_on = isinstance(al, dict) and al.get("enabled") is True
    if alerts_on:
        if not ge_on:
            add("clearance.gate.agent.alerts needs grantExpiry.enabled: the grant-expiry pods export the grant times the alerts read")
        if not hb:
            add("clearance.gate.agent.alerts needs statusHeartbeat (e.g. 5m): without it status.checkedAt says nothing about a stalled agent")
        elif isinstance(hb, str) and HEARTBEAT.fullmatch(hb) and int(hb[:-1]) * {"s": 1, "m": 60, "h": 3600}[hb[-1]] >= CHECKED_AT_STALE_AFTER_S:
            add(f"clearance.gate.agent.statusHeartbeat {hb} must be below 15m with alerts (the chart's alerts.checkedAtStaleAfter)")
        if not on("components.observability"):
            add("clearance.gate.agent.alerts needs components.observability: kube-prometheus-stack (40-observability) provides the "
                "PrometheusRule and PodMonitor CRDs and the Prometheus that reads them")
    # The chart's rule, refused here first so a render never leaves the agent's Application failing in Argo CD: the policy may deny
    # only with the webhook enabled and enforcing (turn it to enforce first, the policy to Deny after; leave in reverse order).
    if on("clearance.gate.enforce") and not enforce and ge.get("acceptResidualRisk") is not True and _agent_chart(v) >= (0, 55, 0):
        add("clearance.gate.enforce needs clearance.gate.agent.grantExpiry {enabled: true, mode: enforce} (agent chart 0.55.0+ refuses it otherwise): "
            "the admission policy has no clock, so without an enforcing grant-expiry webhook an expired grant admits writes while the agent is "
            "stalled (I-44). Turn the webhook to enforce first and the policy to Deny in a later change; leave in reverse order. The only "
            "override is grantExpiry.acceptResidualRisk: true")
    return out


def violations(v, fleet=None):
    out = []
    add = out.append
    name = v.get("name") or ""
    on = lambda key: get(v, key) is True  # noqa: E731

    # identity: one name for everything
    if not name:
        add("name is required")
    elif not DNS1123.match(name):
        add(f"name '{name}' must be a DNS-1123 label: lowercase letters, digits and '-', start and end alphanumeric, "
            "at most 63 characters (it is the kubectl context, registry name, Infisical stem and issuer path)")
    if v.get("profile") not in ("dev", "prod", "platform"):
        add(f"profile must be dev, prod or platform (got {v.get('profile')!r})")
    eks = get(v, "runtime.type") == "eks"
    if get(v, "runtime.type") not in ("kiac", "kind", "existing", "eks"):
        add(f"runtime must be kiac, kind, existing or eks (got {get(v, 'runtime.type')!r})")
    for key in ("scm.owner", "registry.owner"):
        if not get(v, key):
            add(f"{key} is required (no default owner): pass --scm-owner (and --registry-owner if it differs)")
    for key in ("scm.host", "registry.host"):
        if not get(v, key):
            add(f"{key} is required")
    repo = v.get("repoURL") or ""
    if not repo:
        add("repoURL is required: this cluster's own GitOps repo, e.g. https://github.com/<owner>/gitops-cluster-<name>")
    elif not re.match(r"^https://[^/]+/[^/]+/[^/]+$", repo):
        add(f"repoURL must be https://<host>/<owner>/<repo> (got {repo!r})")
    if not v.get("tenantsRepoURL"):
        add("tenantsRepo is required (defaults to <repo name>-tenants once repoURL is set)")
    issuer = v.get("issuer") or ""
    if not issuer.startswith("https://"):
        add(f"issuer must be an https URL (got {issuer!r})")
    elif issuer == DEFAULT_ISSUER:
        add("issuer must be unique to this cluster, not the Kubernetes default - two clusters with the same issuer "
            "cannot trust each other (docs/cluster-identity.md)")
    elif eks:
        if not EKS_ISSUER.match(issuer):
            add(f"runtime eks: issuer must be the cluster's EKS OIDC issuer, https://oidc.eks.<region>.amazonaws.com/id/<id> "
                f"(terraform output oidc_issuer in hangar-infra; got {issuer})")
    elif name and not issuer.rstrip("/").endswith("/" + name):
        add(f"issuer must end in /{name} (one-name rule: https://<issuerBase>/oidc/<name>; got {issuer})")
    # a pod CIDR that contains a LAN address the pods must reach routes that traffic inside the cluster instead
    subnet, hub = get(v, "runtime.kind.podSubnet"), get(v, "fleet.hubAddress")
    if get(v, "runtime.type") == "kind" and subnet and hub:
        import ipaddress
        try:
            if ipaddress.ip_address(hub) in ipaddress.ip_network(subnet, strict=False):
                add(f"fleet.hubAddress {hub} is inside runtime.kind.podSubnet {subnet}: pods would route it inside the "
                    "cluster and never reach the hub. Pick a pod subnet that doesn't overlap your LAN")
        except ValueError:
            pass
    # lab-only networking (docs/lab-networking.md): hostAliases, LAN addresses and *.local names exist because of the lab
    # (kiac, kind); a runtime without runtime.labNetworking (eks, existing, ...) has real DNS and routable endpoints.
    if not lab_networking(v):
        rt = get(v, "runtime.type")
        for key in LAB_ONLY_KEYS:
            if get(v, key):
                add(f"{key} is lab-only networking (a hostAlias or LAN address) and runtime {rt} is not a lab: use real DNS and "
                    "a routable endpoint. Only kiac and kind set runtime.labNetworking (docs/lab-networking.md)")
        if not get(v, "domain"):
            add(f"domain is required on runtime {rt} (real DNS: <service>.<domain>); only a lab (kiac, kind) defaults to <name>.local")
        if get(v, "tower.cluster") and not get(v, "tower.domain"):
            add(f"tower.cluster is set without tower.domain on runtime {rt}: Tower's real DNS domain is required (only a lab "
                "defaults to <tower cluster>.local)")
        for key in ("domain", "fleet.hubDomain", "tower.domain", "tower.baseUrl", "fleet.relayUrl", "infisical.url", "autopilot.gateway.go.brokerUrl"):
            val = str(get(v, key) or "")
            host = (urlparse(val).hostname if "://" in val else val.split("/")[0].split(":")[0]) or ""
            if host == "local" or host.endswith(".local"):
                add(f"{key} {val!r} is a .local name, which is not in real DNS: runtime {rt} is not a lab, so set it to a "
                    "real DNS name (docs/lab-networking.md)")
    ctx = get(v, "runtime.existing.context")
    if get(v, "runtime.type") == "existing" and ctx and ctx != name and not on("runtime.existing.renameContext"):
        add(f"runtime.existing.context '{ctx}' is not the cluster name '{name}': a cluster's kubectl context IS its "
            "name (one-name rule). Rename the context, or run `apron up --rename-context`")

    if eks and not get(v, "runtime.eks.region"):
        add("runtime eks needs runtime.eks.region")
    if get(v, "tower.cluster") and get(v, "tower.trust") == "eks-oidc" and not EKS_ISSUER.match(str(get(v, "tower.issuer") or "")):
        add("tower.trust eks-oidc needs tower.issuer: the EKS OIDC issuer of the cluster Tower runs on (its EKS OIDC "
            "identity provider config on this cluster trusts that issuer)")
    if get(v, "traefik.loadBalancer.certificateArn") and get(v, "traefik.serviceType") != "LoadBalancer":
        add("traefik.loadBalancer.certificateArn needs traefik.serviceType: LoadBalancer")

    # zone and roles
    zone, roles = v.get("zone"), v.get("roles") or []
    if zone not in ("lower", "upper"):
        add(f"zone must be lower or upper (got {zone!r})")
    if not roles:
        add("roles is required (control-plane, workloads, platform-services)")
    for r in roles:
        if r not in ROLES:
            add(f"unknown role '{r}' (choose from {', '.join(ROLES)})")
    cp = "control-plane" in roles
    if cp and zone != "lower":
        add("a control-plane cluster must be zone: lower (its pipelines deploy to it directly)")

    # control-plane-only components (service-catalog-design.md §0)
    if not cp:
        if on("components.crossplane.providerGithub"):
            add("components.crossplane.providerGithub needs the control-plane role: Bootstrap-tier XRDs stay on the "
                "fleet's one control plane")
        if on("components.glidepath"):
            add("components.glidepath needs the control-plane role: the CI/CD control plane runs on one cluster")
        if on("components.autopilot"):
            add("components.autopilot needs the control-plane role: Autopilot runs exist on the dev cluster only")
        if get(v, "components.serviceCatalog.scope") == "full":
            add("components.serviceCatalog.scope: full needs the control-plane role (it includes Bootstrap-tier "
                "XRDs); use attached-tier-only")
    if get(v, "components.serviceCatalog.scope") not in ("full", "attached-tier-only"):
        add("components.serviceCatalog.scope must be full or attached-tier-only")
    if on("components.autopilot") and not on("components.clearance"):
        add("components.autopilot needs components.clearance: the gateway asks the Clearance core for every decision")
    hr = get(v, "autopilot.hardenedRuntime")
    if hr not in (None, "", "gvisor"):
        add(f"autopilot.hardenedRuntime must be gvisor or unset (got {hr!r}): it names the RuntimeClass Apron renders")
    elif hr and not on("components.autopilot"):
        add("autopilot.hardenedRuntime needs components.autopilot: it is the runtime class of Autopilot's hardened runs")
    elif hr and get(v, "runtime.type") in ("kind", "kiac"):
        add(f"autopilot.hardenedRuntime: {get(v, 'runtime.type')} nodes have no gVisor; leave it unset so hardened runs are "
            "Rejected, not scheduled onto nodes without runsc")
    # The Go gateway (autopilot A-9; docs/clusters-file.md "autopilot.gateway"): off unless implementation is go. Its settings may be
    # prepared while the Python gateway still runs, so they are checked only when the switch is on.
    impl = get(v, "autopilot.gateway.implementation") or "python"
    # The migrate Job (go.migrateJob) is the cutover's step 4 and runs beside the Python gateway: it needs the image, not the switch.
    if get(v, "autopilot.gateway.go.migrateJob") is not None and not isinstance(get(v, "autopilot.gateway.go.migrateJob"), bool):
        add("autopilot.gateway.go.migrateJob must be true or false")
    elif get(v, "autopilot.gateway.go.migrateJob") and impl == "python":
        mg = "autopilot.gateway.go"
        if not on("components.autopilot"):
            add("autopilot.gateway.go.migrateJob needs components.autopilot")
        if not re.fullmatch(r"gateway-go-v\d+\.\d+\.\d+", str(get(v, f"{mg}.tag") or "")):
            add(f"{mg}.tag must be the Go image's release tag, gateway-go-vMAJOR.MINOR.PATCH: migrateJob runs that image")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(get(v, f"{mg}.digest") or "")):
            add(f"{mg}.digest must be the image's sha256 digest: migrateJob pins tag and digest")
    if impl not in ("python", "go"):
        add(f"autopilot.gateway.implementation must be python or go (got {impl!r}); unset means python")
    elif impl == "go":
        go = "autopilot.gateway.go"
        if not on("components.autopilot"):
            add("autopilot.gateway.implementation: go needs components.autopilot")
        if not re.fullmatch(r"gateway-go-v\d+\.\d+\.\d+", str(get(v, f"{go}.tag") or "")):
            add(f"{go}.tag must be the Go image's release tag, gateway-go-vMAJOR.MINOR.PATCH (it is also the version the Clearance "
                "core registers for the gateway)")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(get(v, f"{go}.digest") or "")):
            add(f"{go}.digest must be the image's sha256 digest (from the release run's summary): the deployment pins tag and digest")
        for key, why in (("brokerUrl", "the installation-token broker the repository tools mint a token from (no default: Python's names a lab Service)"),
                         ("githubOwners", "the GitHub owners the pull requests go to"),
                         ("airframeUpperClusters", "the clusters an Airframe flight environment may land on (no default)"),
                         ("agentXRs.namespaces", "the namespaces whose Agent XRs may define agents (the loader reads no other)")):
            if not get(v, f"{go}.{key}"):
                add(f"{go}.{key} is required with implementation: go: {why}")
        rv = get(v, f"{go}.registeredVersion")
        if rv is not None and not (isinstance(rv, str) and 1 <= len(rv) <= 64):
            add(f"{go}.registeredVersion must be a string of 1 to 64 characters (the provider version the Clearance core registers; unset: go.tag)")
        owners = get(v, f"{go}.githubOwners") or []
        ao = get(v, f"{go}.airframeOwner")
        if ao and ao not in owners:
            add(f"{go}.airframeOwner {ao!r} must be one of {go}.githubOwners")
        if not ao and len(owners) != 1:
            add(f"{go}.airframeOwner is required unless {go}.githubOwners names exactly one owner")
        if get(v, f"{go}.egress.enabled") is not False and not get(v, f"{go}.egress.apiServerCIDRs"):
            add(f"{go}.egress.apiServerCIDRs is required: the egress policy admits the API server by address, which is the cluster's "
                f"to say (or set {go}.egress.enabled: false to render no egress policy)")
        for k in (get(v, f"{go}.plainHttp") or {}):
            if k not in ("glidepath", "broker", "logs", "catalog", "jwks", "clearanceApi"):
                add(f"{go}.plainHttp.{k} is not a plain-http switch (glidepath, broker, logs, catalog, jwks, clearanceApi)")
        # Every http link the templates render needs its switch (plain-http options are off by default, so a render that would start a
        # gateway that refuses its own URLs is refused here, naming the switch).
        ph = lambda k: bool(get(v, f"{go}.plainHttp.{k}"))  # noqa: E731
        if not ph("glidepath"):
            add(f"{go}.plainHttp.glidepath must be true: glidepath-api is an in-cluster http Service, and the Go gateway refuses a plain http URL it was not told to allow")
        if not ph("clearanceApi"):
            add(f"{go}.plainHttp.clearanceApi must be true: CLEARANCE_API_URL is the in-cluster clearance-api http Service, and the Go gateway refuses to start with a plain http URL it was not told to allow")
        if on("components.observability") and on("observability.full") and not ph("logs"):
            add(f"{go}.plainHttp.logs must be true: the log collector's OTLP endpoint is an in-cluster http Service")
        if (get(v, "autopilot.people") and on("components.gatewayRoutes")) and not ph("jwks") and not get(v, "autopilot.peopleTls"):
            add(f"{go}.plainHttp.jwks must be true: people-dex's key set is an in-cluster http Service (or set autopilot.peopleTls: true, which serves it over https)")
        if get(v, "tower.cluster") and str(get(v, "tower.baseUrl") or "").startswith("http://") and not ph("catalog"):
            add(f"{go}.plainHttp.catalog must be true: tower.baseUrl is plain http")
        if str(get(v, f"{go}.brokerUrl") or "").startswith("http://") and not ph("broker"):
            add(f"{go}.plainHttp.broker must be true: {go}.brokerUrl is plain http")
        if get(v, f"{go}.plainHttp.broker") and str(get(v, f"{go}.brokerUrl") or "").startswith("https://"):
            add(f"{go}.plainHttp.broker is on and {go}.brokerUrl is https: turn the switch off")
    if get(v, "autopilot.peopleTls"):
        # people-dex's in-cluster https (templates/55-identity/people-dex/tls.yaml, I-28)
        if not (get(v, "autopilot.people") and on("components.gatewayRoutes")):
            add("autopilot.peopleTls needs autopilot.people and components.gatewayRoutes (people-dex is rendered with them)")
        if not on("components.certManager"):
            add("autopilot.peopleTls needs components.certManager: the serving certificate and its CA are cert-manager's")
        if (get(v, "autopilot.gateway.implementation") or "python") != "go":
            add("autopilot.peopleTls needs autopilot.gateway.implementation: go: only the Go gateway can trust the CA (AUTOPILOT_JWKS_CA_FILE); the Python gateway keeps the http listener")
    # people-dex on the cluster CA (A-19, plan step P6)
    if get(v, "autopilot.peopleTlsClusterCA") is not None and not isinstance(get(v, "autopilot.peopleTlsClusterCA"), bool):
        add("autopilot.peopleTlsClusterCA is true or false")
    if on("autopilot.peopleTlsClusterCA"):
        if not get(v, "autopilot.peopleTls"):
            add("autopilot.peopleTlsClusterCA needs autopilot.peopleTls: it changes who signs people-dex's https certificate")
        if not on("components.clusterCA"):
            add("autopilot.peopleTlsClusterCA needs components.clusterCA: the ClusterIssuer hangar-cluster-ca and its Bundle ConfigMap")
    # trust-manager and the cluster CA (A-19, 10-crds-operators/trust-manager and cluster-ca)
    if on("components.trustManager"):
        if not on("components.certManager"):
            add("components.trustManager needs components.certManager: its webhook's certificate is cert-manager's")
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", str(get(v, "versions.trustManager.chart") or "")):
            add("components.trustManager needs versions.trustManager.chart, a chart version (vX.Y.Z)")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(get(v, "versions.trustManager.imageDigest") or "")):
            add("components.trustManager needs versions.trustManager.imageDigest, the image index's digest (sha256:<64 hex>)")
    if on("components.clusterCA") and not (on("components.certManager") and on("components.trustManager")):
        add("components.clusterCA needs components.certManager (it makes the CA) and components.trustManager (its Bundle publishes it)")
    # clearance.gate.agent.ownedProject renders the agent's Namespaces and AppProjects: only with the gate and its agent (else it would silently do nothing).
    if get(v, "clearance.gate.agent.ownedProject.create") and not (on("clearance.gate.enabled") and get(v, "clearance.gate.agent")):
        add("clearance.gate.agent.ownedProject.create needs clearance.gate.enabled and clearance.gate.agent: the namespaces and projects it makes are the agent's")
    # The gate's clients' CA (A-19, plan steps 4 and 5b): the agent chart's tls.caConfigMap and waitJob.caConfigMap are 0.54.0's.
    if on("clearance.gate.enabled") and get(v, "clearance.gate.agent") and (get(v, "clearance.gate.caConfigMap") or on("clearance.gate.waitCAInject")):
        try:
            agent_v = tuple(int(x) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(get(v, "versions.clearance.argocdAgentChart") or "")).groups())
        except AttributeError:
            agent_v = (0, 0, 0)
        if agent_v < (0, 54, 0):
            add("clearance.gate.caConfigMap and clearance.gate.waitCAInject need versions.clearance.argocdAgentChart 0.54.0 or later "
                "(the agent chart's tls.caConfigMap and waitJob.caConfigMap): an older chart ignores them")
    # The previous wait image (I-59, clearance#218): render passes versions.clearance.previousWaitImage to the agent chart as
    # waitJob.previousImage, which the agent chart has from 0.56.0. An older agent accepts only waitImage, so during the rollover
    # it reports every held wait Job still on the previous image as an out-of-band exception, a false record.
    if (on("clearance.gate.enabled") and get(v, "clearance.gate.agent") and get(v, "versions.clearance.waitImage")
            and get(v, "versions.clearance.previousWaitImage") and _agent_chart(v) < (0, 56, 0)):
        add("versions.clearance.previousWaitImage with clearance.gate.agent needs versions.clearance.argocdAgentChart 0.56.0 or later "
            "(the agent chart's waitJob.previousImage, I-59): an older agent reports a held wait Job on the previous image as out-of-band")
    # The grant-expiry webhook, agent HA, the status heartbeat and the staleness alerts (I-44; agent chart 0.55.0). Unset: nothing renders.
    if on("clearance.gate.enabled") and get(v, "clearance.gate.agent"):
        out.extend(gate_agent_i44_problems(v))
    # The Clearance core's and API's https (clearance.tls; A-19, clearance chart tls.*)
    if get(v, "clearance.gate.fsSandbox") is not None and get(v, "clearance.gate.fsSandbox") not in ("try", "require", "off"):
        add(f"clearance.gate.fsSandbox is {get(v, 'clearance.gate.fsSandbox')!r}: try, require or off (the plugin's CLEARANCE_CMP_FS_SANDBOX); unset for the plugin's default")
    # The audit collector and the target registry publisher call clearance.gate.url and have no CA setting (their charts in
    # clearance 0.54.0): an https URL to the in-cluster core is signed by a private CA they cannot trust (CodeRabbit on #270).
    gate_host = (urlparse(str(get(v, "clearance.gate.url") or "")).hostname or "") if str(get(v, "clearance.gate.url") or "").startswith("https://") else ""
    if gate_host.endswith((".svc", ".svc.cluster.local")):
        for key, who in (("clearance.observe.enabled", "the audit collector"), ("clearance.targets.enabled", "the target registry publisher")):
            if on(key):
                add(f"clearance.gate.url is https to the in-cluster core ({gate_host}), whose certificate a private CA signs, and {who} "
                    f"({key}) has no CA setting to trust it: keep clearance.gate.url on http until it has one")
    for k in ("enabled", "plainHttp", "gatewayBackendTLS"):
        if get(v, f"clearance.tls.{k}") is not None and not isinstance(get(v, f"clearance.tls.{k}"), bool):
            add(f"clearance.tls.{k} is true or false")
    if on("clearance.tls.enabled"):
        if not on("components.clearance"):
            add("clearance.tls.enabled needs components.clearance: it is the core's and the API's own listener")
        if not on("components.certManager"):
            add("clearance.tls.enabled needs components.certManager: the chart's certificates are cert-manager's")
        try:
            chart_v = tuple(int(x) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(get(v, "versions.clearance.chart") or "")).groups())
        except AttributeError:
            chart_v = (0, 0, 0)
        if chart_v < (0, 54, 0):
            add("clearance.tls.enabled needs versions.clearance.chart 0.54.0 or later (the chart's tls.*, clearance I-43)")
    if on("clearance.tls.gatewayBackendTLS"):
        if not on("clearance.tls.enabled"):
            add("clearance.tls.gatewayBackendTLS needs clearance.tls.enabled: the routes move to the https port it opens")
        if not on("components.clusterCA"):
            add("clearance.tls.gatewayBackendTLS needs components.clusterCA: the Gateway verifies the core against the Bundle's ConfigMap hangar-cluster-ca")
        if not on("components.gatewayRoutes"):
            add("clearance.tls.gatewayBackendTLS needs components.gatewayRoutes: there is no route to re-encrypt")
    if get(v, "clearance.tls.plainHttp") is False:
        if not on("clearance.tls.enabled"):
            add("clearance.tls.plainHttp false needs clearance.tls.enabled (the https listener is then the only one)")
        # Every caller Apron renders that still calls the core or the API on plain 8080 (step 7 of hangar
        # specs/plans/a17-clearance-tls-rollout.md: verify, then turn plain http off).
        still = []
        if on("components.gatewayRoutes") and not on("clearance.tls.gatewayBackendTLS"):
            still.append("the Gateway's routes (set clearance.tls.gatewayBackendTLS)")
        for key, who in (("clearance.web.enabled", "the web UI"), ("clearance.slack.enabled", "clearance-slack"),
                         ("components.autopilot", "the Autopilot gateway and read API"),
                         # its apiURL is the in-cluster http clearance-api (58-clearance-observe-aws)
                         ("clearance.observeAWS.enabled", "the AWS collector")):
            if on(key):
                still.append(who)
        if on("components.glidepath") and on("components.clearance"):
            still.append("Glidepath's agent gates and deployment gate (the glidepath-catalog's clearanceUrl is plain http)")
        # The plugin, the wait Job, the audit collector and the target registry publisher all call clearance.gate.url.
        gate_url_plain = not str(get(v, "clearance.gate.url") or "").startswith("https://")
        for key, who in (("clearance.gate.enabled", "the gate's plugin and wait Job"), ("clearance.observe.enabled", "the audit collector"),
                         ("clearance.targets.enabled", "the target registry publisher")):
            if on(key) and gate_url_plain:
                still.append(f"{who} (clearance.gate.url is plain http)")
        if on("clearance.gate.enabled") and get(v, "clearance.gate.agent") and not str(get(v, "clearance.gate.agent.apiURL") or "").startswith("https://"):
            still.append("the gate's agent (clearance.gate.agent.apiURL is plain http)")
        if still:
            add("clearance.tls.plainHttp false would cut off callers that still use plain http: " + ", ".join(still))
    if on("components.autopilot") and not (on("components.serviceCatalog.enabled")
                                            and get(v, "components.serviceCatalog.scope") == "full"):
        add("components.autopilot needs components.serviceCatalog.enabled with scope: full (the AgentRun XRD)")
    if on("components.policy") and on("components.glidepath") is False and False:
        pass

    # signing PKI (C-2a, docs/signing-pki.md): Fulcio and Rekor run with the Glidepath control plane
    for key in ("signing.managedKeys", "signing.trustedRoot", "clearance.attestation.keyless"):
        if on(key) and not on("components.glidepath"):
            add(f"{key} needs components.glidepath: Fulcio and Rekor run with the CI/CD control plane, and only the "
                "cluster that runs it has them")
    if on("clearance.attestation.keyless") and not on("components.clearance"):
        add("clearance.attestation.keyless needs components.clearance: the core signs the attestations")
    for key in ("signing.managedKeys", "signing.trustedRoot", "clearance.attestation.keyless"):
        if get(v, key) is not None and not isinstance(get(v, key), bool):
            add(f"{key} must be true or false")

    ttl = get(v, "clearance.api.coverageCacheSeconds")
    if ttl is not None and (isinstance(ttl, bool) or not isinstance(ttl, int) or not 0 <= ttl <= 300):
        add("clearance.api.coverageCacheSeconds is whole seconds, 0 to 300 (0 is off): clearance-api refuses anything else at start")
    sus = get(v, "clearance.core.startupSeconds")
    if sus is not None and (isinstance(sus, bool) or not isinstance(sus, int) or not 1 <= sus <= 3600):
        add("clearance.core.startupSeconds is whole seconds, 1 to 3600 (unset is the chart's 300)")
    # the standalone web UI (clearance web, clearance chart web.enabled): signs people in at people-dex, so it needs the same
    if get(v, "clearance.web.enabled") is not None and not isinstance(get(v, "clearance.web.enabled"), bool):
        add("clearance.web.enabled must be true or false")
    if on("clearance.web.enabled"):
        if not on("components.clearance"):
            add("clearance.web.enabled needs components.clearance: the UI runs beside the core and clearance-api")
        if not (get(v, "clearance.people") or get(v, "autopilot.people")):
            add("clearance.web.enabled needs clearance.people: people sign in at people-dex, where the web UI's client is registered")
        if not on("components.gatewayRoutes"):
            add("clearance.web.enabled needs components.gatewayRoutes: people-dex and clearance.<domain> are reached through the Gateway")
        if get(v, "gateway.scheme") != "https":
            add("clearance.web.enabled needs gateway.scheme: https: the web server refuses an http public URL or issuer (its "
                "cookies are Secure, __Host-)")
    cidrs = get(v, "clearance.web.idpCidrs") or []
    def cidr_ok(x):
        try:
            __import__("ipaddress").ip_network(x, strict=True)
            return isinstance(x, str)
        except ValueError:
            return False
    if cidrs and not (isinstance(cidrs, list) and all(cidr_ok(x) for x in cidrs)):
        add("clearance.web.idpCidrs is a list of CIDRs, e.g. [203.0.113.10/32]")
    # the Slack service (clearance chart slack.*; docs/clearance-slack.md)
    for msg in clearance_slack_problems(v):
        add(msg)
    # the target registry publisher (clearance Map; docs/clearance-map.md)
    if get(v, "clearance.targets.enabled") is not None and not isinstance(get(v, "clearance.targets.enabled"), bool):
        add("clearance.targets.enabled must be true or false")
    if on("clearance.targets.enabled") and not (on("components.clearance") or get(v, "clearance.gate.url")):
        add("clearance.targets.enabled needs the core: components.clearance here, or clearance.gate.url (the core on another "
            "cluster, as the gate reaches it)")
    pubs = get(v, "clearance.targets.publishers") or []
    if pubs and not on("components.clearance"):
        add("clearance.targets.publishers needs components.clearance: it registers other clusters' publishers with the core this cluster runs")
    for p in pubs:
        if not isinstance(p, dict) or not p.get("cluster"):
            add("clearance.targets.publishers: each is {cluster[, namespace]}")
        elif p["cluster"] != get(v, "tower.cluster"):
            add(f"clearance.targets.publishers: {p['cluster']}: the core trusts another cluster's service-account tokens only for "
                "tower.cluster (clearance.foreignCluster), so a remote publisher is Tower's cluster")

    # the evidence ledger (clearance C-3): the log on the cluster that runs the core, a witness on a protected cluster
    for key in ("clearance.ledger.enabled", "clearance.witness.enabled"):
        if get(v, key) is not None and not isinstance(get(v, key), bool):
            add(f"{key} must be true or false")
    if on("clearance.ledger.enabled"):
        if not on("components.clearance"):
            add("clearance.ledger.enabled needs components.clearance: the core keeps the log")
        if not (get(v, "clearance.ledger.witnesses") or []):
            add("clearance.ledger.enabled needs clearance.ledger.witnesses: a log nobody countersigns is not a ledger "
                "(each is {name, vkey, url}; vkey is the cosignature key `clearance ledger keygen --witness` prints)")
        if get(v, "clearance.ledger.hostAlias") and "=" not in str(get(v, "clearance.ledger.hostAlias")):
            add("clearance.ledger.hostAlias is 'ip=host[,host]'")
    if on("clearance.witness.enabled"):
        if v.get("zone") != "upper":
            add("clearance.witness.enabled needs zone: upper: a witness is worth something only on a cluster the log's "
                "operator does not control")
        if on("clearance.ledger.enabled"):
            add("clearance.witness.enabled and clearance.ledger.enabled on one cluster: the witness would cosign for its own "
                "log's operator; run the witness on a protected cluster")
        if not on("components.gatewayRoutes"):
            add("clearance.witness.enabled needs components.gatewayRoutes: the log reaches the witness through this cluster's gateway")
    def vkey_ok(label, vkey, want):
        try:
            if parse_vkey(vkey)[1] != want:
                add(f"{label}: wrong kind of key ({'a witness cosignature key, type 0x04' if want == 4 else 'a log verifier key, type 0x01'} "
                    "is expected)")
        except ApronError as e:
            add(f"{label}: {e}")
    if on("clearance.ledger.enabled"):
        for w in get(v, "clearance.ledger.witnesses") or []:
            vkey_ok(f"clearance.ledger.witnesses[{w.get('name') if isinstance(w, dict) else w}].vkey", w.get("vkey", "") if isinstance(w, dict) else "", 4)
    if on("clearance.witness.enabled"):
        for k in get(v, "clearance.witness.logsVkeys") or []:
            vkey_ok("clearance.witness.logsVkeys", k, 1)
    for key in ("clearance.ledger.keySecret", "clearance.witness.keySecret"):
        if get(v, key) is not None and not re.fullmatch(r"[A-Za-z0-9._-]+", str(get(v, key))):
            add(f"{key} is the name of an Infisical secret (letters, digits, . _ -)")

    # secrets: host vs consumer
    host = on("infisical.host")
    if on("components.externalSecrets") and not host and not on("components.serviceCatalog.enabled"):
        add("components.externalSecrets on a cluster that does not host Infisical needs components.serviceCatalog."
            "enabled: the platform Infisical project is a SecretStore XR (needs the SecretStore XRD)")
    if host and not cp:
        add("infisical.host should be the control-plane cluster (its Kubernetes Auth and the bootstrap identity live "
            "there)")
    if not host and on("components.externalSecrets") and not get(v, "infisical.url"):
        add("infisical.url is required on an Infisical consumer: set fleet.hub (the control-plane cluster's name) "
            "or infisical.url")
    if host:
        for k in ("infisicalPgPassword", "infisicalRedisPassword"):
            if not get(v, f"generated.{k}"):
                add(f"generated.{k} is missing: `apron init` generates it (openssl rand -hex 20)")
    if on("components.glidepath"):
        for k in ("rekorMysqlPassword", "rekorMysqlRootPassword"):
            if not get(v, f"generated.{k}"):
                add(f"generated.{k} is missing: `apron init` generates it (openssl rand -hex 20)")

    # fleet wiring
    if not cp and on("components.serviceCatalog.enabled") and not get(v, "fleet.repoURL"):
        add("fleet.repoURL is required off the control plane: the hub's repo, whose clusters.yaml the "
            "cluster-registry Application reads")
    if not cp and not get(v, "fleet.hub"):
        add("fleet.hub is required off the control plane: the control-plane cluster's name")
    if on("components.towerAccessHub") and not get(v, "tower.cluster"):
        add("components.towerAccessHub needs tower.cluster: the name of the cluster Tower runs on (its issuer is "
            "trusted, its users get RBAC here)")
    if get(v, "tower.cluster") and not DNS1123.match(str(get(v, "tower.cluster"))):
        add("tower.cluster must be a cluster name (DNS-1123 label)")
    if on("components.cloudTargets") and not re.fullmatch(r"[0-9]{12}", str(get(v, "aws.accountId") or "")):
        add("components.cloudTargets needs aws.accountId (12 digits, quoted)")
    if on("components.backstage") and on("components.towerAccess"):
        add("components.backstage (the old in-repo Deployment) and components.towerAccess (Tower as an Airframe app) "
            "both grant Tower's ServiceAccount: pick one")

    # gateway / runtime
    rp = get(v, "glidepath.refProtection", None)
    if rp is not None and rp is not False and rp not in ("required", "off"):
        add(f"glidepath.refProtection is {rp!r}: required (default) or off (off only for a git host plan without rulesets; "
            "glidepath docs/admin/security.md, Ref protection)")
    glw = get(v, "promotion.gateLedger.writer", None)
    if glw not in (None, "", "direct", "api"):
        add(f"promotion.gateLedger.writer is {glw!r}: direct (the catalog's default) or api (glidepath-api writes the gate "
            "ledger; glidepath docs/admin/api.md, Gate verdicts)")
    grt = get(v, "glidepath.gateReports.transport", None)
    if grt not in (None, "", "configmap", "log"):
        add(f"glidepath.gateReports.transport is {grt!r}: configmap (the catalog's default) or log (api-compat and policy-validation "
            "hand their report over in the gate's own step log; glidepath docs/admin/security.md)")
    rs = get(v, "glidepath.runShape", None)
    if rs is not None and rs not in ("deny", "warn"):
        add(f"glidepath.runShape is {rs!r}: deny (default) or warn (only while upgrading)")
    si = get(v, "glidepath.sourceIsolation", None)
    if si is not None and si not in ("deny", "warn"):
        add(f"glidepath.sourceIsolation is {si!r}: deny (default) or warn (only while upgrading)")
    gro = get(v, "releaseGuardrailOverrides", None)
    if gro not in (None, {}):
        if not isinstance(gro, dict):
            add(f"releaseGuardrailOverrides is {gro!r}: a map of <gate>: {{required: true|false}}")
        else:
            for gate, o in gro.items():
                if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(gate)):
                    add(f"releaseGuardrailOverrides.{gate}: not a gate name (lowercase letters, digits and dashes)")
                if not (isinstance(o, dict) and set(o) == {"required"} and isinstance(o["required"], bool)):
                    add(f"releaseGuardrailOverrides.{gate} is {o!r}: only {{required: true|false}} is read")
    gc = get(v, "glidepath.gateConcurrency", None)
    if gc not in (None, "") and (isinstance(gc, bool) or not isinstance(gc, int) or gc < 1):
        add(f"glidepath.gateConcurrency is {gc!r}: a whole number of at least 1, or unset for no limit")
    gp = get(v, "glidepath.gitopsRepoProvenance", None)
    if gp not in (None, "") and gp not in ("default_branch", "source"):
        add(f"glidepath.gitopsRepoProvenance is {gp!r}: default_branch, source, or unset")
    if get(v, "traefik.serviceType") not in ("NodePort", "LoadBalancer", "ClusterIP"):
        add("traefik.serviceType must be NodePort, LoadBalancer or ClusterIP")
    if get(v, "runtime.type") == "kind" and get(v, "traefik.serviceType") != "NodePort":
        add("runtime kind needs traefik.serviceType: NodePort (host ports map to Traefik's NodePorts)")
    if get(v, "runtime.type") == "kiac" and get(v, "runtime.kiac.gateway"):
        add("runtime.kiac.gateway must stay off: Traefik in 10-crds-operators/traefik is the cluster's one gateway")

    if fleet is not None:
        out.extend(fleet_violations(fleet, v))
    return out


def fleet_violations(fleet, v=None):
    out = []
    add = out.append
    if not isinstance(fleet, dict):
        return ["fleet file is not a mapping"]
    if not get(fleet, "scm.owner"):
        add("fleet file: a top-level scm: {owner: <owner>} block is required (Airframe's cluster-registry chart "
            "copies it into every record)")
    recs = fleet.get("clusters") or []
    names = [r.get("name") for r in recs if isinstance(r, dict)]
    for n in sorted({n for n in names if names.count(n) > 1}):
        add(f"fleet file: cluster '{n}' is listed more than once")
    cps = [r.get("name") for r in recs if "control-plane" in (r.get("roles") or [])]
    if len(cps) > 1:
        add(f"fleet file: exactly one control-plane cluster allowed (got {', '.join(cps)})")
    hosts = [r.get("name") for r in recs if get(r, "airframe.infisicalHost") is True]
    if len(hosts) > 1:
        add(f"fleet file: exactly one airframe.infisicalHost cluster allowed (got {', '.join(hosts)})")
    for r in recs:
        n = r.get("name") or "?"
        if not DNS1123.match(str(n)):
            add(f"fleet file: cluster name '{n}' is not a DNS-1123 label")
        if r.get("zone") not in ("lower", "upper"):
            add(f"fleet file: {n}: zone must be lower or upper")
        if "control-plane" not in (r.get("roles") or []) and not get(r, "glidepath.relaySecretName"):
            add(f"fleet file: {n}: glidepath.relaySecretName is required on every record except the control plane's")
        if get(r, "airframe.autopilotReady") and "control-plane" not in (r.get("roles") or []):
            add(f"fleet file: {n}: airframe.autopilotReady is only allowed on the control-plane cluster")
        iss = r.get("serviceAccountIssuer")
        if iss and not EKS_ISSUER.match(str(iss)) and not (str(iss).startswith("https://")
                                                            and str(iss).rstrip("/").endswith("/" + str(n))):
            add(f"fleet file: {n}: serviceAccountIssuer must be https://<issuerBase>/oidc/{n} (or the cluster's EKS issuer)")
    inf = fleet.get("infisical")
    if isinstance(inf, dict):
        for k in ("orgId", "url", "inClusterUrl"):
            if not inf.get(k):
                add(f"fleet file: infisical.{k} is empty: set all three or leave the block commented out")
    if v is not None:
        me = next((r for r in recs if r.get("name") == v.get("name")), None)
        if me:
            if me.get("zone") != v.get("zone") or sorted(me.get("roles") or []) != sorted(v.get("roles") or []):
                add(f"fleet file: {v['name']}'s record (zone/roles) disagrees with its cluster.yaml: run apron fleet add")
            if get(v, "infisical.host") and get(me, "airframe.infisicalHost") is False:
                add(f"fleet file: {v['name']} hosts Infisical but its record says airframe.infisicalHost: false")
        if get(v, "infisical.host"):
            others = [h for h in hosts if h != v.get("name")]
            if others:
                add(f"infisical.host: true, but the fleet's Infisical host is already {others[0]} (one per fleet)")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cluster", required=True)
    ap.add_argument("--fleet")
    ap.add_argument("--apron-root")
    a = ap.parse_args()
    try:
        kw = {"root": a.apron_root} if a.apron_root else {}
        v = resolve(a.cluster, **kw)
        fleet = load_yaml(a.fleet) if a.fleet else None
    except (ApronError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    bad = violations(v, fleet)
    for b in bad:
        print(f"error: {b}", file=sys.stderr)
    if not bad:
        print(f"ok: {v.get('name')} ({v.get('profile')} on {get(v, 'runtime.type')}) passes every check")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
