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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import ApronError, get, load_yaml, parse_vkey, resolve  # noqa: E402

DEFAULT_ISSUER = "https://kubernetes.default.svc.cluster.local"
DNS1123 = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
ROLES = ("control-plane", "workloads", "platform-services")
# A managed cluster's own issuer: EKS publishes https://oidc.eks.<region>.amazonaws.com/id/<hex> for every cluster.
EKS_ISSUER = re.compile(r"^https://oidc\.eks\.[a-z0-9-]+\.amazonaws\.com/id/[0-9A-Fa-f]+$")


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
