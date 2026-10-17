#!/usr/bin/env python3
"""Edit the fleet's clusters.yaml for `apron fleet` (docs/clusters-file.md).

Uses ruamel.yaml when installed, which keeps comments; otherwise PyYAML, which drops them (a warning says so).
  add           --fleet FILE --values-json JSON   add or update one cluster record; ensure scm: {owner}
  set-infisical --fleet FILE --org-id X --url U [--in-cluster-url U]
"""
import argparse
import json
import os
import sys

try:
    from ruamel.yaml import YAML
    _yaml = YAML()
    _yaml.preserve_quotes = True
    _yaml.indent(mapping=2, sequence=4, offset=2)

    def load(path):
        with open(path) as f:
            return _yaml.load(f) or {}

    def dump(doc, path):
        with open(path, "w") as f:
            _yaml.dump(doc, f)
except ImportError:
    import yaml

    def load(path):
        with open(path) as f:
            return yaml.safe_load(f) or {}

    def dump(doc, path):
        print(f"note: ruamel.yaml is not installed, so comments in {path} were not preserved "
              "(pip install ruamel.yaml, or restore them from git)", file=sys.stderr)
        with open(path, "w") as f:
            yaml.safe_dump(doc, f, sort_keys=False, width=120)


def read_fleet(path):
    return load(path) if os.path.exists(path) else {}


def record_for(v):
    name = v["name"]
    rec = {"name": name, "zone": v.get("zone"), "roles": list(v.get("roles") or [])}
    tenants = v.get("tenantsRepo") or ""
    tenants = tenants.rstrip("/").split("/")[-1]
    if tenants.endswith(".git"):
        tenants = tenants[:-4]
    if tenants:
        rec["tenantsRepo"] = tenants
    issuer = v.get("serviceAccountIssuer")
    if not issuer and v.get("issuerBase") and v.get("runtime") != "existing":
        issuer = "https://" + v["issuerBase"].removeprefix("https://").rstrip("/") + "/oidc/" + name
    if issuer:
        rec["serviceAccountIssuer"] = issuer
    flags = {"cicdReady": False, "crossplaneReady": False}
    if (v.get("infisical") or {}).get("host"):
        flags["infisicalHost"] = True
    rec["airframe"] = flags
    return {k: x for k, x in rec.items() if x is not None}


def cmd_add(a):
    v = json.loads(a.values_json)
    doc = read_fleet(a.fleet)
    owner = (v.get("scm") or {}).get("owner")
    if not owner:
        sys.exit("resolved values have no scm.owner")
    scm = doc.get("scm")
    if scm is None:
        doc["scm"] = {"owner": owner}
    elif scm.get("owner") != owner:
        sys.exit(f"{a.fleet} has scm.owner {scm.get('owner')!r}, this cluster has {owner!r}: one owner per fleet")
    clusters = doc.setdefault("clusters", [])
    new = record_for(v)
    for rec in clusters:
        if rec.get("name") == new["name"]:
            # Update the shared fields; keep readiness flags a person already attested, and anything else.
            flags = rec.get("airframe") or {}
            for k, x in new.items():
                if k == "airframe":
                    for fk, fx in x.items():
                        flags.setdefault(fk, fx)
                    rec["airframe"] = flags
                else:
                    rec[k] = x
            print(f"updated {new['name']} in {a.fleet}")
            break
    else:
        clusters.append(new)
        print(f"added {new['name']} to {a.fleet}")
    dump(doc, a.fleet)


def cmd_set_infisical(a):
    doc = read_fleet(a.fleet)
    inf = doc.get("infisical") or {}
    inf["orgId"] = a.org_id
    inf["url"] = a.url
    if a.in_cluster_url:
        inf["inClusterUrl"] = a.in_cluster_url
    if not inf.get("inClusterUrl"):
        sys.exit("infisical.inClusterUrl is required too (--in-cluster-url): the chart refuses a block with an empty field")
    doc["infisical"] = inf
    dump(doc, a.fleet)
    print(f"set infisical in {a.fleet}")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("add")
    s.add_argument("--fleet", required=True)
    s.add_argument("--values-json", required=True)
    s = sub.add_parser("set-infisical")
    s.add_argument("--fleet", required=True)
    s.add_argument("--org-id", required=True)
    s.add_argument("--url", required=True)
    s.add_argument("--in-cluster-url")
    a = p.parse_args()
    {"add": cmd_add, "set-infisical": cmd_set_infisical}[a.cmd](a)


if __name__ == "__main__":
    main()
