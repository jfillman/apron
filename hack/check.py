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
from apronlib import ApronError, get, load_yaml, resolve  # noqa: E402

DEFAULT_ISSUER = "https://kubernetes.default.svc.cluster.local"
DNS1123 = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
ROLES = ("control-plane", "workloads", "platform-services")


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
    if v.get("profile") not in ("dev", "prod"):
        add(f"profile must be dev or prod (got {v.get('profile')!r})")
    if get(v, "runtime.type") not in ("kiac", "kind", "existing"):
        add(f"runtime must be kiac, kind or existing (got {get(v, 'runtime.type')!r})")
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
    elif name and not issuer.rstrip("/").endswith("/" + name):
        add(f"issuer must end in /{name} (one-name rule: https://<issuerBase>/oidc/<name>; got {issuer})")
    ctx = get(v, "runtime.existing.context")
    if get(v, "runtime.type") == "existing" and ctx and ctx != name and not on("runtime.existing.renameContext"):
        add(f"runtime.existing.context '{ctx}' is not the cluster name '{name}': a cluster's kubectl context IS its "
            "name (one-name rule). Rename the context, or run `apron up --rename-context`")

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
    if on("components.autopilot") and not (on("components.serviceCatalog.enabled")
                                            and get(v, "components.serviceCatalog.scope") == "full"):
        add("components.autopilot needs components.serviceCatalog.enabled with scope: full (the AgentRun XRD)")
    if on("components.policy") and on("components.glidepath") is False and False:
        pass

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
        if iss and not (str(iss).startswith("https://") and str(iss).rstrip("/").endswith("/" + str(n))):
            add(f"fleet file: {n}: serviceAccountIssuer must be https://<issuerBase>/oidc/{n}")
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
