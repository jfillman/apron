# tests/cases/22-gate-canary.sh (see tests/run.sh)
# group: render
# secs: 4
# needs: gate-on
AS="${TMP}/gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
# clearance.gate.canary: a second sidecar from another image, named by the listed apps only. Unset, nothing differs.
CANARY=ghcr.io/acme/clearance-cmp@sha256:2222222222222222222222222222222222222222222222222222222222222222
CMPAPP="${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml"
if grep -q 'clearance-canary\|clearance-cmp-canary\|cmp-tmp-canary' "${CMPAPP}" "${AS}"; then bad "canary unset: a canary sidecar, volume or plugin name rendered"; else ok "canary unset: no canary sidecar, volume or plugin name (the render is today's)"; fi
new "${TMP}/gate-canary" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-canary" "gate on with a canary plugin"
CA="${TMP}/gate-canary/01-argocd-platform/argocd-apps-install/application.yaml"
CAS="${TMP}/gate-canary/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${CA}" "name: clearance-cmp-canary" "canary: a second sidecar"
[ "$(grep -c 'limits: {memory: 2560Mi}' "${CA}")" = 2 ] && ok "canary: both sidecars carry the 2560Mi limit" || bad "canary: the sidecar limits are not both 2560Mi"
has "${CA}" "image: ${CANARY}" "canary: it runs the canary image"
has "${CA}" "image: ghcr.io/acme/clearance-cmp@sha256:aaaa" "canary: the first sidecar keeps the default image"
has "${CA}" "command: \[/var/run/argocd/argocd-cmp-server, --config-dir-path, /home/argocd/cmp-server/config-canary\]" "canary: it registers the image's canary plugin.yaml"
has "${CA}" "name: cmp-tmp-canary, emptyDir" "canary: its own /tmp volume, not the first sidecar's"
has "${CAS}" 'name: \{\{ if regexMatch "\^\(gate-api\)\$" .appName \}\}clearance-canary\{\{ else \}\}clearance\{\{ end \}\}' "canary: only the listed apps name clearance-canary"
if [ "$(grep -c 'cmp-tmp-canary' "${CA}")" = 2 ] && [ "$(grep -c 'mountPath: /tmp$' "${CA}")" = 0 ]; then ok "canary: cmp-tmp-canary is declared once and mounted once"; else bad "canary: cmp-tmp-canary is not declared and mounted exactly once"; fi
# the second sidecar has the first's settings and security context: the two blocks are equal once the three canary-only lines are dropped
python3 - "${CA}" <<'PY' && ok "canary: same settings and security context as the first sidecar" || bad "canary: the sidecars differ beyond image, command and tmp volume"
import sys, re
lines = open(sys.argv[1]).read().split("\n")
def block(name):
    i = next(n for n, l in enumerate(lines) if l.strip() == "- name: " + name)
    ind = len(lines[i]) - len(lines[i].lstrip())
    out = []
    for l in lines[i + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) <= ind:
            break
        out.append(l)
    return out
def norm(b, tmp):
    return [l.replace(tmp, "cmp-tmp-X") for l in b if not l.lstrip().startswith(("image:", "command:", "#"))]
a, b = norm(block("clearance-cmp"), "cmp-tmp,"), norm(block("clearance-cmp-canary"), "cmp-tmp-canary,")
sys.exit(0 if a == b and any("readOnlyRootFilesystem: true" in l for l in a) and len(a) > 15 else 1)
PY
for BAD in "clearance.gate.canary.image=ghcr.io/acme/clearance-cmp:latest" "clearance.gate.canary.apps=[]" "clearance.gate.canary.apps=[Bad_App]" "clearance.gate.canary.apps=gate-api"; do
  new "${TMP}/gate-canary-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
    --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[gate-api]' --set "${BAD}"
  if python3 hack/render.py --cluster "${TMP}/gate-canary-bad/cluster.yaml" >/dev/null 2>&1; then bad "canary ${BAD}: accepted"; else ok "canary ${BAD}: refused"; fi
done
new "${TMP}/gate-canary-out" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[other-app]' --set 'clearance.gate.apps=[gate-api]'
if python3 hack/render.py --cluster "${TMP}/gate-canary-out/cluster.yaml" >/dev/null 2>&1; then bad "canary app outside clearance.gate.apps: accepted"; else ok "canary app outside clearance.gate.apps: refused (the gate does not cover it)"; fi
