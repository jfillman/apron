"""Shared helpers for Apron's render/check/new_cluster (Python stdlib only).

- A small YAML reader/writer for Apron's own config files (cluster.yaml, profiles/, runtimes/, versions.yaml, the
  fleet clusters.yaml): block maps and lists, flow lists/maps on one line, quoted and plain scalars, comments.
  It is not a general YAML parser and refuses what it does not understand (anchors, multi-line scalars, tags).
- Value resolution: versions.yaml < runtimes/<runtime>.yaml < profiles/<profile>.yaml < cluster.yaml, then derived
  values (domain, issuer, repo URLs, ...) that follow from the cluster's one name.
- A tiny condition language for templates/MANIFEST and `#@if` lines.
"""
import datetime
import fnmatch
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ApronError(Exception):
    pass


def parse_vkey(vkey):
    """A C2SP signed-note verifier key, `<name>+<8 hex>+<base64>`, as (name, key type byte), or raises ApronError.
    It checks the key's shape and that the hash is the one the note format derives from the name and the key, so a
    mistyped or truncated key is refused here, not by a witness at runtime. Type 0x01 is a log's Ed25519 key; type
    0x04 is a tlog-cosignature (witness) key, the form a witness policy lists."""
    import base64
    import hashlib
    m = re.fullmatch(r"([^\s+]+)\+([0-9a-f]{8})\+([A-Za-z0-9+/]+={0,2})", str(vkey))
    if not m:
        raise ApronError(f"{vkey!r} is not a verifier key (<name>+<8 hex>+<base64>)")
    name, h, b64 = m.groups()
    try:
        raw = base64.b64decode(b64, validate=True)
    except ValueError:
        raise ApronError(f"{vkey!r}: the key part is not base64")
    if len(raw) != 33:
        raise ApronError(f"{vkey!r}: an Ed25519 verifier key is a type byte and 32 bytes")
    if hashlib.sha256(name.encode() + b"\n" + raw).hexdigest()[:8] != h:
        raise ApronError(f"{vkey!r}: the key hash does not match its name and key")
    return name, raw[0]


# --- YAML subset reader ----------------------------------------------------------------------------------------------

def _strip_comment(line):
    q = None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i].rstrip()
    return line.rstrip()


def _split_flow(s):
    parts, depth, q, cur = [], 0, None, ""
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
            continue
        cur += c
    if cur.strip():
        parts.append(cur.strip())
    return parts


def _split_key(s):
    """'key: value' -> (key, value or None). Returns None if the line is not a mapping entry."""
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
            continue
        if c in "\"'" and i == 0:
            q = c
        elif c == ":" and (i + 1 == len(s) or s[i + 1] == " "):
            key = s[:i].strip()
            if len(key) >= 2 and key[0] == key[-1] and key[0] in "\"'":
                key = key[1:-1]
            rest = s[i + 1:].strip()
            return key, (rest if rest else None)
    return None


def scalar(s):
    s = s.strip()
    if s == "" or s in ("~", "null"):
        return None
    if s[0] == "[" and s[-1] == "]":
        return [scalar(p) for p in _split_flow(s[1:-1])]
    if s[0] == "{" and s[-1] == "}":
        d = {}
        for p in _split_flow(s[1:-1]):
            kv = _split_key(p)
            if kv is None:
                raise ApronError(f"cannot parse flow mapping entry {p!r}")
            d[kv[0]] = scalar(kv[1] or "")
        return d
    if s[0] == '"' and s[-1] == '"':
        return json.loads(s)
    if s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if s in ("true", "True"):
        return True
    if s in ("false", "False"):
        return False
    if re.fullmatch(r"-?[0-9]+", s):
        return int(s)
    if s[0] in "&*!|>":
        raise ApronError(f"unsupported YAML construct {s!r} (Apron's config files use plain YAML only)")
    return s


def load_yaml(path):
    with open(path) as f:
        return loads_yaml(f.read(), path)


def loads_yaml(text, name="<string>"):
    lines = []
    for n, raw in enumerate(text.split("\n"), 1):
        if raw.strip() in ("---", "..."):
            continue
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise ApronError(f"{name}:{n}: tab indentation")
        s = _strip_comment(raw)
        if s.strip():
            lines.append((n, len(s) - len(s.lstrip(" ")), s.strip()))
    if not lines:
        return {}
    pos = [0]

    def parse(indent):
        n, ind, s = lines[pos[0]]
        if s.startswith("- ") or s == "-":
            return parse_list(ind)
        return parse_map(ind)

    def parse_map(indent):
        d = {}
        while pos[0] < len(lines):
            n, ind, s = lines[pos[0]]
            if ind < indent:
                break
            if ind > indent:
                raise ApronError(f"{name}:{n}: unexpected indentation")
            if s.startswith("- "):
                break
            kv = _split_key(s)
            if kv is None:
                raise ApronError(f"{name}:{n}: expected 'key: value', got {s!r}")
            k, v = kv
            pos[0] += 1
            if v is None:
                if pos[0] < len(lines) and (lines[pos[0]][1] > indent or
                                            (lines[pos[0]][1] == indent and lines[pos[0]][2].startswith("- "))):
                    d[k] = parse(lines[pos[0]][1])
                else:
                    d[k] = None
            else:
                d[k] = scalar(v)
        return d

    def parse_list(indent):
        out = []
        while pos[0] < len(lines):
            n, ind, s = lines[pos[0]]
            if ind < indent or not (s.startswith("- ") or s == "-"):
                break
            if ind > indent:
                raise ApronError(f"{name}:{n}: unexpected indentation")
            item = s[1:].strip()
            if item == "":
                pos[0] += 1
                out.append(parse(lines[pos[0]][1]) if pos[0] < len(lines) and lines[pos[0]][1] > indent else None)
                continue
            kv = _split_key(item) if not item.startswith(("[", "{", '"', "'")) else None
            if kv is None:
                out.append(scalar(item))
                pos[0] += 1
                continue
            # "- key: value" starts a mapping whose keys sit at indent+2
            lines[pos[0]] = (n, ind + 2, item)
            out.append(parse_map(ind + 2))
        return out

    result = parse(lines[0][1])
    if pos[0] != len(lines):
        n = lines[pos[0]][0]
        raise ApronError(f"{name}:{n}: could not parse from here")
    return result


# --- YAML subset writer ----------------------------------------------------------------------------------------------

_PLAIN = re.compile(r"^[A-Za-z0-9_./][A-Za-z0-9_./:@=+-]*$")


def _scalar_out(v):
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    s = str(v)
    if _PLAIN.match(s) and s not in ("true", "false", "null", "yes", "no", "on", "off") \
            and not re.fullmatch(r"[0-9.eE+-]+", s) and ": " not in s:
        return s
    return json.dumps(s)


def dumps_yaml(obj, indent=0):
    pad = " " * indent
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, dict) and v:
                out.append(f"{pad}{k}:")
                out.append(dumps_yaml(v, indent + 2))
            elif isinstance(v, list) and v and any(isinstance(x, (dict, list)) for x in v):
                out.append(f"{pad}{k}:")
                out.append(dumps_yaml(v, indent + 2))
            elif isinstance(v, list):
                out.append(f"{pad}{k}: [{', '.join(_scalar_out(x) for x in v)}]")
            elif isinstance(v, dict):
                out.append(f"{pad}{k}: {{}}")
            else:
                out.append(f"{pad}{k}: {_scalar_out(v)}")
    elif isinstance(obj, list):
        for v in obj:
            if isinstance(v, dict) and v:
                sub = dumps_yaml(v, indent + 2).split("\n")
                out.append(f"{pad}- {sub[0].lstrip()}")
                out.extend(sub[1:])
            else:
                out.append(f"{pad}- {_scalar_out(v)}")
    return "\n".join(x for x in out if x != "")


# --- values ----------------------------------------------------------------------------------------------------------

def deep_merge(base, over):
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        out[k] = deep_merge(base.get(k), v) if isinstance(v, dict) and isinstance(base.get(k), dict) else v
    return out


def get(d, dotted, default=None):
    cur = d
    for p in dotted.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return default
        cur = cur[p]
    return cur


def set_dotted(d, dotted, value):
    parts = dotted.split(".")
    cur = d
    for p in parts[:-1]:
        if not isinstance(cur.get(p), dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = value


def parse_set(items):
    """--set k=v pairs -> dict (values parsed as YAML scalars, so true/false/ints/[a, b] work)."""
    d = {}
    for it in items or []:
        if "=" not in it:
            raise ApronError(f"--set expects key=value, got {it!r}")
        k, v = it.split("=", 1)
        set_dotted(d, k.strip(), scalar(v))
    return d


# Lab-only networking: name/IP plumbing that exists because a lab (kiac on Apple `container`, kind on podman, LAN relays and
# ssh forwards, *.local names that are not in DNS) cannot resolve or route what a real network does. runtimes/kiac.yaml and
# kind.yaml set runtime.labNetworking: true; every other runtime (eks, existing, ...) is not a lab, and none of these keys
# may be set on it (hack/check.py refuses) nor rendered (hack/render.py blanks them; templates also test the flag).
LAB_ONLY_KEYS = ("tower.hostAliasIP", "fleet.hubAddress", "clearance.gate.hostAlias", "clearance.ledger.hostAlias",
                "clearance.slack.idp.hostAlias")


def lab_networking(v):
    return get(v, "runtime.labNetworking") is True


def runtime_name(cluster):
    r = cluster.get("runtime")
    return r.get("type") if isinstance(r, dict) else r


def layered(cluster, root=ROOT):
    """Merge Apron's defaults under cluster.yaml (cluster.yaml wins).

    cluster.yaml names its runtime as `runtime: {type: kind, ...overrides}` (a bare `runtime: kind` also works)."""
    cluster = dict(cluster)
    if isinstance(cluster.get("runtime"), str):
        cluster["runtime"] = {"type": cluster["runtime"]}
    names = {"profile": cluster.get("profile"), "runtime": runtime_name(cluster)}
    for k, n in names.items():
        if not n:
            raise ApronError(f"cluster.yaml: '{k}' is required" + (" (runtime.type: kiac, kind, existing or eks)"
                                                                   if k == "runtime" else " (dev, prod or platform)"))
    prof = os.path.join(root, "profiles", f"{names['profile']}.yaml")
    rt = os.path.join(root, "runtimes", f"{names['runtime']}.yaml")
    for p, what in ((prof, "profile"), (rt, "runtime")):
        if not os.path.exists(p):
            choices = sorted(f[:-5] for f in os.listdir(os.path.dirname(p)) if f.endswith(".yaml"))
            raise ApronError(f"unknown {what} '{names[what]}' (choose one of: {', '.join(choices)})")
    v = load_yaml(os.path.join(root, "versions.yaml"))
    v = deep_merge(v, load_yaml(rt))
    v = deep_merge(v, load_yaml(prof))
    return deep_merge(v, cluster)


def derive(v):
    """Fill every value that follows from the name plus the explicit inputs. Never overrides an explicit value."""
    v = json.loads(json.dumps(v))
    name = v.get("name") or ""

    def default(key, value):
        if get(v, key) in (None, ""):
            set_dotted(v, key, value)

    # `.local` names are lab-only (they are in no DNS): only a lab runtime gets them by default. Any other runtime must be
    # given real names (domain, fleet.hubDomain, tower.domain: hack/check.py says which are missing).
    lab = lab_networking(v)
    default("domain", f"{name}.local" if lab else "")
    default("issuerBase", "hangarplatform.dev")
    default("issuer", f"https://{v['issuerBase']}/oidc/{name}")
    default("scm.host", "github.com")
    default("registry.host", "ghcr.io")
    default("registry.owner", get(v, "scm.owner"))
    scm = f"https://{get(v, 'scm.host')}/{get(v, 'scm.owner')}"
    repo = v.get("repoURL") or ""
    if not v.get("tenantsRepo") and repo:
        base = repo[:-4] if repo.endswith(".git") else repo
        v["tenantsRepo"] = base.rsplit("/", 1)[-1] + "-tenants"
    tenants = v.get("tenantsRepo") or ""
    if tenants and not tenants.startswith("https://"):
        tenants = f"{scm}/{tenants}"
    if tenants and not tenants.endswith(".git"):
        tenants += ".git"
    v["tenantsRepoURL"] = tenants
    v["tenantsRepoName"] = tenants.rsplit("/", 1)[-1][:-4] if tenants else ""
    roles = v.get("roles") or []
    v["isControlPlane"] = "control-plane" in roles
    # The fleet's hub: the control-plane cluster, whose repo carries clusters.yaml.
    if v["isControlPlane"]:
        default("fleet.hub", name)
        default("fleet.repoURL", repo)
    default("fleet.hubDomain", f"{get(v, 'fleet.hub')}.local" if lab and get(v, "fleet.hub") else "")
    default("fleet.hubAddress", "")
    # Infisical: the host runs it; consumers reach the host's NodePort.
    if get(v, "infisical.host") and v["domain"]:
        default("infisical.url", f"http://{v['domain']}:{get(v, 'infisical.nodePort')}/api")
    elif get(v, "fleet.hubDomain"):
        default("infisical.url", f"http://{get(v, 'fleet.hubDomain')}:{get(v, 'infisical.nodePort')}/api")
    # Tower (Backstage) runs as an Airframe app on some cluster; the hub trusts that cluster's issuer.
    if get(v, "tower.cluster"):
        default("tower.issuer", f"https://{v['issuerBase']}/oidc/{get(v, 'tower.cluster')}")
        if lab:
            default("tower.domain", f"{get(v, 'tower.cluster')}.local")
    default("tower.namespace", f"app-backstage-{get(v, 'tower.env') or 'prod'}")
    if get(v, "tower.domain"):
        default("tower.baseUrl", f"http://backstage.{get(v, 'tower.domain')}")
    return v


OLD_PROVENANCE_KEY = "gitopsPipelineProvenance"   # the name glidepath.gitopsRepoProvenance had in its first release
NEW_PROVENANCE_KEY = "gitopsRepoProvenance"


def fold_legacy_provenance(raw, v):
    """cluster.yaml may still set glidepath.gitopsPipelineProvenance: alone it is used (with a warning on stderr), next to
    glidepath.gitopsRepoProvenance with a different value it is an error. Only cluster.yaml counts, not Apron's defaults."""
    rg = raw.get("glidepath") if isinstance(raw, dict) else None
    if not isinstance(rg, dict) or OLD_PROVENANCE_KEY not in rg:
        return v
    old = rg[OLD_PROVENANCE_KEY]
    if NEW_PROVENANCE_KEY in rg:
        new = rg[NEW_PROVENANCE_KEY]
        if (old or None) != (new or None):
            raise ApronError(f"glidepath.{OLD_PROVENANCE_KEY} is {old!r} but glidepath.{NEW_PROVENANCE_KEY} is {new!r}: "
                             f"they are the same setting, so set only glidepath.{NEW_PROVENANCE_KEY}")
    else:
        print(f"warning: glidepath.{OLD_PROVENANCE_KEY} is deprecated, rename it to glidepath.{NEW_PROVENANCE_KEY} "
              "(the old name is still read)", file=sys.stderr)
    g = v.setdefault("glidepath", {})
    g.pop(OLD_PROVENANCE_KEY, None)
    g[NEW_PROVENANCE_KEY] = old if NEW_PROVENANCE_KEY not in rg else rg[NEW_PROVENANCE_KEY]
    return v


def resolve(cluster_path, root=ROOT):
    raw = load_yaml(cluster_path)
    return fold_legacy_provenance(raw, derive(layered(raw, root)))


# --- conditions ------------------------------------------------------------------------------------------------------

_EXPR_TOKEN = re.compile(r"\s*(==|!=|\(|\)|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*|[0-9]+)")


def evaluate(expr, values):
    """`a.b`, `not x`, `a and b`, `a or b`, `x == 'y'`, `x != 'y'`, parentheses. Missing keys are falsy/None."""
    toks, pos = [], 0
    while pos < len(expr):
        m = _EXPR_TOKEN.match(expr, pos)
        if not m:
            raise ApronError(f"bad condition {expr!r}")
        toks.append(m.group(1))
        pos = m.end()
        while pos < len(expr) and expr[pos] == " ":
            pos += 1
    out = []
    for t in toks:
        if t in ("and", "or", "not", "(", ")", "==", "!="):
            out.append(t)
        elif t.startswith("'"):
            out.append(repr(t[1:-1]))
        elif t in ("true", "false"):
            out.append("True" if t == "true" else "False")
        elif t.isdigit():
            out.append(t)
        else:
            out.append(repr(get(values, t)))
    try:
        return bool(eval(" ".join(out), {"__builtins__": {}}, {}))
    except Exception as e:
        raise ApronError(f"bad condition {expr!r}: {e}")


def die(msg, code=1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# ---- Clearance Slack (clearance.slack.*; README "Clearance Slack", docs/clearance-slack.md) ----
SLACK_MIN_CHART = (0, 47, 1)   # the first clearance chart with slack.* (clearance v0.47.1)
_SLACK_CHANNEL = re.compile(r"^[CG][A-Z0-9]{8,}$")
_SLACK_ROUTE_MAPS = ("groups", "apps", "scopes")
_SLACK_ROUTE_ONES = ("default", "security", "ops")


def clearance_slack_url(v):
    """(scheme, host) of clearance.slack.publicUrl, or ("", "") when it is not an https origin."""
    import urllib.parse
    raw = get(v, "clearance.slack.publicUrl", "") or ""
    try:
        u = urllib.parse.urlparse(str(raw))
        bad = u.scheme != "https" or not u.hostname or "." not in u.hostname or u.path not in ("", "/") or u.query or u.fragment \
            or u.username or u.port
    except ValueError:  # a non-numeric or out-of-range port
        return "", ""
    if bad:
        return "", ""
    return u.scheme, u.hostname


def clearance_slack_problems(v):
    """Everything wrong with clearance.slack.* in the resolved values `v`, as messages ([] when off or fine). Used by
    `apron check` and by the renderer, so a cluster that does not pass never renders half a Slack service."""
    out = []
    add = out.append
    s = get(v, "clearance.slack")
    if s is None:
        return out
    if not isinstance(s, dict):
        return ["clearance.slack must be a map (enabled, publicUrl, slackClientId, routes, ...)"]
    en = s.get("enabled")
    if en is not None and not isinstance(en, bool):
        add("clearance.slack.enabled must be true or false")
    if en is not True:
        return out
    k = "clearance.slack"
    if get(v, "components.clearance") is not True:
        add(f"{k}.enabled needs components.clearance: the service runs beside the core and clearance-api")
    if not (get(v, "clearance.people") or get(v, "autopilot.people")):
        add(f"{k}.enabled needs clearance.people: the link page signs people in at people-dex and the core's allowlist names who may link")
    if get(v, "components.gatewayRoutes") is not True:
        add(f"{k}.enabled needs components.gatewayRoutes: people-dex and the link pages are reached through the Gateway")
    chart = str(get(v, "versions.clearance.chart", "") or "")
    try:
        have = tuple(int(x) for x in chart.split("."))
    except ValueError:
        have = ()
    if have < SLACK_MIN_CHART:
        add(f"{k}.enabled needs versions.clearance.chart {'.'.join(map(str, SLACK_MIN_CHART))} or later (first chart with slack.*; "
            f"this cluster pins {chart or 'nothing'}): bump it together with versions.clearance.imageDigest")
    digest = str(get(v, "versions.clearance.slackImageDigest", "") or "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        add(f"{k}.enabled needs versions.clearance.slackImageDigest (ghcr.io/<owner>/clearance-slack, sha256:<64 hex>)")
    if not clearance_slack_url(v)[1]:
        add(f"{k}.publicUrl is required: an https origin with a host name, no path, e.g. https://slack.clearance.example.com "
            "(Slack accepts no other redirect for Sign in with Slack)")
    cid = s.get("slackClientId")
    if not isinstance(cid, str) or not re.fullmatch(r"[0-9]+\.[0-9]+", cid):
        add(f"{k}.slackClientId is required: the Slack app's Client ID (Basic Information), two numbers with a dot, as a quoted string")
    transport = s.get("transport")
    if transport is not None and transport not in ("socket", "events"):
        add(f"{k}.transport must be socket or events (got {transport!r})")
    web = s.get("webUrl")
    if web not in (None, ""):
        if not isinstance(web, str) or not re.match(r"^https?://[^/]+/.*\{id\}", web):
            add(f"{k}.webUrl must be a URL containing {{id}} (the change), e.g. https://clearance.example.com/changes/{{id}}; "
                "leave it unset to send tier 3 to the CLI")
    routes = s.get("routes")
    if routes is not None:
        if not isinstance(routes, dict):
            add(f"{k}.routes must be a map: groups, apps, scopes (name -> channel id) and default, security, ops (a channel id)")
        else:
            for key, val in routes.items():
                if key in _SLACK_ROUTE_MAPS:
                    if not isinstance(val, dict):
                        add(f"{k}.routes.{key} must be a map of name -> channel id")
                        continue
                    for name, ch in val.items():
                        if not (isinstance(ch, str) and _SLACK_CHANNEL.match(ch)):
                            add(f"{k}.routes.{key}[{name}] must be a Slack channel id (C... or G..., not a name; got {ch!r})")
                elif key in _SLACK_ROUTE_ONES:
                    if val not in ("", None) and not (isinstance(val, str) and _SLACK_CHANNEL.match(val)):
                        add(f"{k}.routes.{key} must be a Slack channel id (C... or G..., not a name; got {val!r})")
                else:
                    add(f"{k}.routes.{key} is not a route (groups, apps, scopes, default, security, ops): the service refuses a misspelled key at start")
    mode = get(v, f"{k}.tls.mode", "gateway-existing") or "gateway-existing"
    scheme = get(v, "gateway.scheme") or "http"
    if mode not in ("dns01-route53", "gateway-existing"):
        add(f"{k}.tls.mode must be dns01-route53 or gateway-existing (got {mode!r})")
    elif mode == "gateway-existing":
        if scheme != "https":
            add(f"{k}.tls.mode gateway-existing means TLS already ends in front of the Gateway (gateway.scheme: https, e.g. the "
                "cloud load balancer's certificate); this cluster's Gateway is plain http: use tls.mode: dns01-route53")
    else:
        if not lab_networking(v):
            add(f"{k}.tls.mode dns01-route53 is the lab path (the Gateway serves the certificate, the host resolves to a LAN address); "
                f"runtime {get(v, 'runtime.type')} is not a lab: use tls.mode: gateway-existing (TLS at the load balancer)")
        if scheme == "https":
            add(f"{k}.tls.mode dns01-route53 serves the certificate from the Gateway itself; gateway.scheme: https means TLS ends at a "
                "load balancer in front of it (the https listener would be unreachable): use tls.mode: gateway-existing")
        if get(v, "components.certManager") is not True:
            add(f"{k}.tls.mode dns01-route53 needs components.certManager (cert-manager issues the certificate)")
        d = f"{k}.tls.dns01"
        if not re.fullmatch(r"Z[A-Z0-9]{5,}", str(get(v, f"{d}.hostedZoneID", "") or "")):
            add(f"{d}.hostedZoneID is required: the Route 53 hosted zone of the public URL's domain (Z...)")
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", str(get(v, f"{d}.email", "") or "")):
            add(f"{d}.email is required: the address Let's Encrypt contacts about the certificate")
        region = get(v, f"{d}.region")
        if region not in (None, "") and not re.fullmatch(r"[a-z]{2}(-[a-z]+)+-\d", str(region)):
            add(f"{d}.region must be an AWS region, e.g. us-east-1")
        server = get(v, f"{d}.server")
        if server not in (None, "") and not str(server).startswith("https://"):
            add(f"{d}.server must be the ACME directory URL (https://...); unset is Let's Encrypt production")
        auth = get(v, f"{d}.auth", "serviceAccount") or "serviceAccount"
        if auth not in ("serviceAccount", "static"):
            add(f"{d}.auth must be serviceAccount (no stored key: the cluster's service-account token is exchanged for the role) or static (an IAM user's key pair in Infisical)")
        elif auth == "serviceAccount" and not re.fullmatch(r"arn:aws[a-z-]*:iam::\d{12}:role/\S+", str(get(v, f"{d}.roleARN", "") or "")):
            add(f"{d}.roleARN is required with auth: serviceAccount: the IAM role cert-manager assumes (arn:aws:iam::<account>:role/<name>); "
                "or set auth: static")
    alias = get(v, f"{k}.idp.hostAlias")
    if alias not in (None, ""):
        import ipaddress
        try:
            ipaddress.ip_address(str(alias))
        except ValueError:
            add(f"{k}.idp.hostAlias must be an IP address (where dex.<domain> answers for the pod)")
    cidrs = get(v, f"{k}.idp.cidrs") or []
    if cidrs:
        import ipaddress
        try:
            ok = isinstance(cidrs, list) and all(isinstance(c, str) and ipaddress.ip_network(c, strict=True) for c in cidrs)
        except ValueError:
            ok = False
        if not ok:
            add(f"{k}.idp.cidrs is a list of CIDRs, e.g. [203.0.113.10/32]")
    return out


# --- Clearance's gate rule (W-42; clearance docs/gate.md, "The gate rule") ---------------------------------------------
# clearance.gate.agent.rule is passed through verbatim to the agent chart's gateRule (0.56.0+). The agent compares its
# project ceiling (argocd.projects) exactly ("*": every project) and holds RBAC only in the literal protectedNamespaces, so
# Apron derives both from the rule's literal values when they are unset, and checks them against the rule when they are set.

GATE_RULE_MIN_CHART = (0, 56, 0)
GATE_RULE_KEYS = ("version", "select", "exempt")
GATE_RULE_SELECT_KEYS = ("name", "projects", "namespaces", "labels")
GATE_RULE_EXEMPT_KEYS = ("application", "reason", "expires", "ref")
GATE_RULE_OPTION_KEYS = ("exemptMax", "releaseMax", "exemptionRecheck", "exemptionRecheckTimeout")


def is_glob(s):
    """The agent's matcher reads `*` and `?` (the deny list's globs); `[` is never part of a Kubernetes name, so it counts too."""
    return any(c in str(s) for c in "*?[")


def gate_rule(g):
    """The rule as cluster.yaml sets it, or None when unset or empty (an empty mapping renders nothing, as unset). `g` is a
    getter, g(dotted_key, default)."""
    r = g("clearance.gate.agent.rule", None)
    return r if r not in (None, {}) else None


def _rule_entries(rule):
    sel = rule.get("select") if isinstance(rule, dict) else None
    return [e for e in sel if isinstance(e, dict)] if isinstance(sel, list) else []


def _uniq(xs):
    out = []
    for x in xs:
        if x not in out:
            out.append(x)
    return out


def gate_agent_ceiling(g):
    """(projects, protectedNamespaces) the agent gets: clearance.gate.agent.projects / protectedNamespaces when set (even
    with a rule; `apron check` holds them against it), else, with a rule, the rule's literal projects and namespaces (glob
    values and entries that name none give nothing: check refuses that). Without a rule, what is set (or [])."""
    projs, nss = g("clearance.gate.agent.projects", None), g("clearance.gate.agent.protectedNamespaces", None)
    rule = gate_rule(g)
    if rule is not None:
        ents = _rule_entries(rule)
        if projs is None:
            projs = _uniq(p for e in ents for p in (e.get("projects") or []) if isinstance(p, str) and p and not is_glob(p))
        if nss is None:
            nss = _uniq(n for e in ents for n in (e.get("namespaces") or []) if isinstance(n, str) and n and not is_glob(n))
    return list(projs or []), list(nss or [])


def _go_duration_s(s):
    """A Go time.Duration string (5m, 1h30m, 2160h, 500ms) in seconds, or None when it is not one."""
    if not isinstance(s, str) or not re.fullmatch(r"([0-9]+(\.[0-9]+)?(ns|us|µs|ms|s|m|h))+", s):
        return None
    unit = {"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}
    return sum(float(n) * unit[u] for n, _, u in re.findall(r"([0-9]+(\.[0-9]+)?)(ns|us|µs|ms|s|m|h)", s))


def gate_rule_problems(v):
    """clearance.gate.agent.rule and ruleOptions, checked as the agent chart and the agent read them (unknown keys refused:
    the agent decodes the file with KnownFields), plus what only Apron knows: the opt-in, the chart version, the project
    ceiling and the namespaces the agent holds RBAC for. Called only with the gate and its agent on this cluster."""
    out = []
    add = out.append
    g = lambda k, d=None: get(v, k, d)  # noqa: E731
    raw = g("clearance.gate.agent.rule")
    opts = g("clearance.gate.agent.ruleOptions")
    rule = gate_rule(g)
    if raw is not None and not isinstance(raw, dict):
        return [f"clearance.gate.agent.rule is a mapping ({{version: 1, select: [...], exempt: [...]}}), got {raw!r}"]
    if opts is not None and rule is None:
        add("clearance.gate.agent.ruleOptions needs clearance.gate.agent.rule: the options tune the rule's exemptions and releases")
    if opts is not None and not isinstance(opts, dict):
        add(f"clearance.gate.agent.ruleOptions is a mapping ({{{', '.join(GATE_RULE_OPTION_KEYS)}}})")
    elif isinstance(opts, dict):
        for k in sorted(set(opts) - set(GATE_RULE_OPTION_KEYS)):
            add(f"clearance.gate.agent.ruleOptions.{k} is not a setting (only {', '.join(GATE_RULE_OPTION_KEYS)})")
        for k in ("exemptMax", "exemptionRecheck", "exemptionRecheckTimeout"):
            if opts.get(k) is not None and not _go_duration_s(opts.get(k)):
                add(f"clearance.gate.agent.ruleOptions.{k} is {opts.get(k)!r}: a positive Go duration (90s, 5m, 2160h)")
        em = _go_duration_s(opts.get("exemptMax"))
        if em and em > 2160 * 3600:
            add(f"clearance.gate.agent.ruleOptions.exemptMax {opts.get('exemptMax')} is over 2160h: the core bounds an exemption at 90 days, and the agent refuses to start")
        rm = opts.get("releaseMax")
        if rm is not None and (isinstance(rm, bool) or not isinstance(rm, int) or rm < 1):
            add(f"clearance.gate.agent.ruleOptions.releaseMax is {rm!r}: a whole number of at least 1 (rule-caused releases an hour)")
        rc = _go_duration_s(opts.get("exemptionRecheck", "5m")) or 0
        rt = _go_duration_s(opts.get("exemptionRecheckTimeout", "30s")) or 0
        if rc and rt and rt >= rc:
            add("clearance.gate.agent.ruleOptions.exemptionRecheckTimeout must be below exemptionRecheck (chart defaults 30s and 5m): the agent refuses to start otherwise")
    if rule is None:
        return out
    if get(v, "clearance.gate.agent.optIn") is not True:
        add("clearance.gate.agent.rule needs clearance.gate.agent.optIn: true: the rule switches Applications as the opt-in does (the agent chart refuses gateRule without optIn.enabled)")
    try:
        chart_v = tuple(int(x) for x in re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(get(v, "versions.clearance.argocdAgentChart") or "")).groups())
    except AttributeError:
        chart_v = (0, 0, 0)
    if chart_v < GATE_RULE_MIN_CHART:
        add("clearance.gate.agent.rule needs versions.clearance.argocdAgentChart 0.56.0 or later (the agent chart's gateRule, W-42): an older chart ignores it")
    for k in sorted(set(rule) - set(GATE_RULE_KEYS)):
        add(f"clearance.gate.agent.rule.{k} is not a setting (only {', '.join(GATE_RULE_KEYS)})")
    ver = rule.get("version")
    if isinstance(ver, bool) or ver != 1:
        add(f"clearance.gate.agent.rule.version is {ver!r}: it must be 1")
    sel, exempt = rule.get("select"), rule.get("exempt")
    if sel is not None and not (isinstance(sel, list) and all(isinstance(e, dict) for e in sel)):
        add("clearance.gate.agent.rule.select is a list of entries ({name, projects, namespaces, labels})")
        sel = []
    if exempt is not None and not (isinstance(exempt, list) and all(isinstance(e, dict) for e in exempt)):
        add("clearance.gate.agent.rule.exempt is a list of entries ({application, reason, expires, ref})")
        exempt = []
    dns = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
    names = []
    for i, e in enumerate(sel or []):
        nm = e.get("name")
        where = f"clearance.gate.agent.rule.select[{i}]" + (f" ({nm})" if isinstance(nm, str) else "")
        for k in sorted(set(e) - set(GATE_RULE_SELECT_KEYS)):
            add(f"{where}.{k} is not a setting (only {', '.join(GATE_RULE_SELECT_KEYS)})")
        if not (isinstance(nm, str) and dns.fullmatch(nm)):
            add(f"{where} needs a name, a DNS label (it names the entry in the agent's status and records)")
        elif nm in names:
            add(f"{where}: the name {nm} is used twice")
        names.append(nm)
        for k in ("projects", "namespaces"):
            vals = e.get(k)
            if vals is not None and not (isinstance(vals, list) and vals and all(isinstance(x, str) and x.strip() and len(x) <= 253 for x in vals)):
                add(f"{where}.{k} is a non-empty list of globs (strings of 1 to 253 characters)")
        labels = e.get("labels")
        if labels is not None and not (isinstance(labels, dict) and labels and all(
                isinstance(k, str) and k.strip() and len(k) <= 317 and isinstance(x, str) and len(x) <= 63 for k, x in labels.items())):
            add(f"{where}.labels is a non-empty mapping of label key to exact value (quote a value such as \"true\" or \"1\")")
        if not (e.get("projects") or e.get("namespaces") or e.get("labels")):
            add(f"{where} names none of projects, namespaces and labels: it would match everything (write projects: [\"*\"] to mean that)")
    for i, e in enumerate(exempt or []):
        where = f"clearance.gate.agent.rule.exempt[{i}]"
        for k in sorted(set(e) - set(GATE_RULE_EXEMPT_KEYS)):
            add(f"{where}.{k} is not a setting (only {', '.join(GATE_RULE_EXEMPT_KEYS)})")
        app = e.get("application")
        ns_glob, _, name_glob = str(app or "").partition("/")
        if not (isinstance(app, str) and app.count("/") == 1 and ns_glob and name_glob):
            add(f"{where}.application is {app!r}: a glob on <namespace>/<name> of the Application (argocd-apps/<name>)")
        elif not fnmatch.fnmatchcase("argocd-apps", ns_glob):
            add(f"{where}.application {app} can never match: the agent reads Applications in argocd-apps (write argocd-apps/<name>)")
        reason = e.get("reason")
        if not (isinstance(reason, str) and 10 <= len(reason) <= 500):
            add(f"{where}.reason is 10 to 500 characters (it goes into the record)")
        exp = e.get("expires")
        if not (isinstance(exp, str) and (_iso_date(exp) or _rfc3339(exp))):
            add(f"{where}.expires is {exp!r}: a date (2026-12-19, read as 00:00 UTC) or an RFC 3339 time, as a string")
        if e.get("ref") is not None and not isinstance(e.get("ref"), str):
            add(f"{where}.ref is a string (a strip, ticket or pull request)")
    out.extend(_gate_rule_ceiling_problems(v, rule))
    return out


def _iso_date(s):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        return False
    try:
        datetime.date.fromisoformat(s)
        return True
    except ValueError:
        return False


def _rfc3339(s):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})", s):
        return False
    try:
        datetime.datetime.fromisoformat(s.replace("z", "Z").replace("Z", "+00:00").replace("t", "T"))
        return True
    except ValueError:
        return False


def _gate_rule_ceiling_problems(v, rule):
    """The rule never widens what the agent may touch: an Application outside the project ceiling is not seen at all, and
    one outside protectedNamespaces is blocked (reported, never switched). So the render fails when the rule names what
    the ceiling leaves out, or when the ceiling cannot be derived."""
    out = []
    add = out.append
    ents = _rule_entries(rule)
    projs_set, nss_set = get(v, "clearance.gate.agent.projects"), get(v, "clearance.gate.agent.protectedNamespaces")
    projs, nss = gate_agent_ceiling(lambda k, d=None: get(v, k, d))
    for key, val in (("projects", projs_set), ("protectedNamespaces", nss_set)):
        if val is not None and not (isinstance(val, list) and all(isinstance(x, str) and x for x in val)):
            add(f"clearance.gate.agent.{key} is a list of names")
            return out
    for p in projs:
        if p != "*" and is_glob(p):
            add(f"clearance.gate.agent.projects: {p!r} is a glob; the agent compares its projects exactly (\"*\" alone means every project)")
    for n in nss:
        if is_glob(n):
            add(f"clearance.gate.agent.protectedNamespaces: {n!r} is a glob; the agent's RBAC is one Role per listed namespace, so list each one")
    for e in ents:
        nm = e.get("name") or "?"
        ep = [p for p in (e.get("projects") or []) if isinstance(p, str)]
        en = [n for n in (e.get("namespaces") or []) if isinstance(n, str)]
        # projects
        if projs_set is None:
            if not ep:
                add(f"clearance.gate.agent.rule entry {nm} names no project, so the project ceiling cannot be derived from it: "
                    "list clearance.gate.agent.projects (the agent reads only Applications in those projects)")
            for p in ep:
                if is_glob(p):
                    add(f"clearance.gate.agent.rule entry {nm}: project {p!r} is a glob, which the ceiling cannot be derived from: "
                        "list clearance.gate.agent.projects with \"*\" (the agent compares projects exactly)")
        else:
            for p in ep:
                if "*" in projs:
                    continue
                if is_glob(p):
                    add(f"clearance.gate.agent.rule entry {nm}: project {p!r} is a glob, and clearance.gate.agent.projects does not hold \"*\": "
                        "the agent compares projects exactly, so the Applications it matches outside the list are never seen")
                elif p not in projs:
                    add(f"clearance.gate.agent.rule entry {nm}: project {p} is not in clearance.gate.agent.projects: the agent never sees its Applications")
        # namespaces
        if nss_set is None:
            if not en:
                add(f"clearance.gate.agent.rule entry {nm} names no namespace (it matches every namespace of its projects): list "
                    "clearance.gate.agent.protectedNamespaces, or a matched Application outside them is blocked, never switched")
            for n in en:
                if is_glob(n):
                    add(f"clearance.gate.agent.rule entry {nm}: namespace {n!r} is a glob: list its namespaces in "
                        "clearance.gate.agent.protectedNamespaces (the agent holds RBAC only in the namespaces listed there)")
        else:
            for n in en:
                if is_glob(n):
                    if not any(fnmatch.fnmatchcase(x, n) for x in nss):
                        add(f"clearance.gate.agent.rule entry {nm}: namespace {n!r} matches none of clearance.gate.agent.protectedNamespaces: "
                            "every Application it selects would be blocked")
                elif n not in nss:
                    add(f"clearance.gate.agent.rule entry {nm}: namespace {n} is not in clearance.gate.agent.protectedNamespaces: "
                        "its Applications would be blocked (reported, never switched)")
    if not projs:
        add("clearance.gate.agent needs projects: list clearance.gate.agent.projects, or name literal projects in the rule")
    if not nss:
        add("clearance.gate.agent needs protectedNamespaces: list clearance.gate.agent.protectedNamespaces, or name literal namespaces in the rule")
    return out
