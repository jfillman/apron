#!/usr/bin/env python3
"""apron new-cluster: print a starter cluster.yaml for one cluster (`apron init` writes it into the cluster repo).

    python3 hack/new_cluster.py --profile dev|prod --name NAME --runtime kiac|kind|existing \
        --repo-url URL --scm-owner OWNER [--registry-owner OWNER] [--tenants-repo NAME] [--domain D] \
        [--fleet-hub NAME] [--tower-cluster NAME] [--set key=value ...] > cluster.yaml

The file records only this cluster's own inputs, plus per-cluster generated passwords (openssl rand -hex 20, like
customize-cluster.sh did): profile, runtime and version defaults stay in Apron and are merged at render time, so
`apron render` after an Apron upgrade picks up new defaults. cluster.yaml is committed in the cluster repo.
"""
import argparse
import os
import secrets
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apronlib import ROOT, ApronError, deep_merge, derive, dumps_yaml, get, layered, parse_set, set_dotted  # noqa: E402

HEADER = """\
# cluster.yaml - this cluster's inputs to Apron (committed: it is what `apron render` re-renders from).
# Defaults come from Apron's profiles/{profile}.yaml, runtimes/{runtime}.yaml and versions.yaml; set a key here to
# override one. One name: {name} is this cluster's kubectl context, fleet record, Infisical stem, issuer path
# (https://<issuerBase>/oidc/{name}) and hostname stem ({domain}).
#
# generated: per-cluster passwords for in-cluster databases (Infisical Postgres/Redis, Rekor MySQL). They protect
# ClusterIP-only services and are committed by design (see the templates' headers); never copy them to another cluster.
"""


def gen():
    return secrets.token_hex(20)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--runtime", required=True, help="kiac, kind or existing (no default: independent of profile)")
    ap.add_argument("--repo-url", default="")
    ap.add_argument("--tenants-repo", default="")
    ap.add_argument("--scm-owner", default="")
    ap.add_argument("--scm-host", default="")
    ap.add_argument("--registry-owner", default="")
    ap.add_argument("--registry-host", default="")
    ap.add_argument("--domain", default="")
    ap.add_argument("--fleet-hub", default="", help="the control-plane cluster's name (consumers)")
    ap.add_argument("--fleet-repo-url", default="", help="the control-plane cluster's repo (consumers)")
    ap.add_argument("--tower-cluster", default="", help="the cluster Tower runs on (the hub trusts its issuer)")
    ap.add_argument("--context", default="", help="runtime existing: the kubeconfig context to adopt")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument("--apron-root", default=ROOT)
    a = ap.parse_args()
    c = {"name": a.name, "profile": a.profile, "runtime": {"type": a.runtime}}
    if a.context:
        c["runtime"]["existing"] = {"context": a.context}
    for key, val in (("repoURL", a.repo_url), ("tenantsRepo", a.tenants_repo), ("domain", a.domain),
                     ("scm.host", a.scm_host), ("scm.owner", a.scm_owner), ("registry.host", a.registry_host),
                     ("registry.owner", a.registry_owner), ("fleet.hub", a.fleet_hub),
                     ("fleet.repoURL", a.fleet_repo_url), ("tower.cluster", a.tower_cluster)):
        if val:
            set_dotted(c, key, val)
    try:
        c = deep_merge(c, parse_set(a.set))
        v = derive(layered(c, a.apron_root))
    except ApronError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    g = {}
    if get(v, "infisical.host"):
        g["infisicalPgPassword"] = gen()
        g["infisicalRedisPassword"] = gen()
    if get(v, "components.glidepath"):
        g["rekorMysqlPassword"] = gen()
        g["rekorMysqlRootPassword"] = gen()
    if g:
        c["generated"] = g
    print(HEADER.format(profile=a.profile, runtime=a.runtime, name=a.name, domain=v["domain"]))
    print(dumps_yaml(c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
