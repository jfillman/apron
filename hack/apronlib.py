"""Shared helpers for Apron's render/check/new_cluster (Python stdlib only).

- A small YAML reader/writer for Apron's own config files (cluster.yaml, profiles/, runtimes/, versions.yaml, the
  fleet clusters.yaml): block maps and lists, flow lists/maps on one line, quoted and plain scalars, comments.
  It is not a general YAML parser and refuses what it does not understand (anchors, multi-line scalars, tags).
- Value resolution: versions.yaml < runtimes/<runtime>.yaml < profiles/<profile>.yaml < cluster.yaml, then derived
  values (domain, issuer, repo URLs, ...) that follow from the cluster's one name.
- A tiny condition language for templates/MANIFEST and `#@if` lines.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ApronError(Exception):
    pass


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
            raise ApronError(f"cluster.yaml: '{k}' is required" + (" (runtime.type: kiac, kind or existing)"
                                                                   if k == "runtime" else " (dev or prod)"))
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

    default("domain", f"{name}.local")
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
    default("fleet.hubDomain", f"{get(v, 'fleet.hub')}.local" if get(v, "fleet.hub") else "")
    default("fleet.hubAddress", "")
    # Infisical: the host runs it; consumers reach the host's NodePort.
    if get(v, "infisical.host"):
        default("infisical.url", f"http://{v['domain']}:{get(v, 'infisical.nodePort')}/api")
    elif get(v, "fleet.hubDomain"):
        default("infisical.url", f"http://{get(v, 'fleet.hubDomain')}:{get(v, 'infisical.nodePort')}/api")
    # Tower (Backstage) runs as an Airframe app on some cluster; the hub trusts that cluster's issuer.
    if get(v, "tower.cluster"):
        default("tower.issuer", f"https://{v['issuerBase']}/oidc/{get(v, 'tower.cluster')}")
        default("tower.domain", f"{get(v, 'tower.cluster')}.local")
    default("tower.namespace", f"app-backstage-{get(v, 'tower.env') or 'prod'}")
    if get(v, "tower.domain"):
        default("tower.baseUrl", f"http://backstage.{get(v, 'tower.domain')}")
    return v


def resolve(cluster_path, root=ROOT):
    return derive(layered(load_yaml(cluster_path), root))


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
