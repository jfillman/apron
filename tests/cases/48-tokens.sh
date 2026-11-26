# tests/cases/48-tokens.sh (see tests/run.sh)
# group: render
# secs: 1
# needs: lab
echo "== 4. tokens"
missing="$(DEVCFG="${LAB}/dev/cluster.yaml" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, "hack")
from render import tokens
from apronlib import resolve
doc = set(re.findall(r"@@([A-Z0-9_]+)@@", open("templates/TOKENS.md").read())) - {"TOKEN"}
used = set()
for d, _, fs in os.walk("templates"):
    for f in fs:
        if f != "TOKENS.md":
            used |= set(re.findall(r"@@([A-Z0-9_]+)@@", open(os.path.join(d, f)).read()))
known = set(tokens(resolve(sys.argv[1] if len(sys.argv) > 1 else os.environ["DEVCFG"])).keys())
out = []
if used - doc: out.append("undocumented: " + " ".join(sorted(used - doc)))
if doc - used: out.append("documented but unused: " + " ".join(sorted(doc - used)))
if used - known: out.append("unknown to render.py: " + " ".join(sorted(used - known)))
print("; ".join(out))
PY
)" 2>&1
[ -z "${missing}" ] && ok "TOKENS.md, templates and render.py agree" || bad "tokens: ${missing}"
