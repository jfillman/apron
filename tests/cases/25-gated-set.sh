# tests/cases/25-gated-set.sh (see tests/run.sh)
# group: render
# secs: 7
GS="${TMP}/gate-set"
new "${GS}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" --set clearance.gate.agent.gatedSet=true
render_ok "${GS}" "gate opt-in with the gated set"
GSA="${GS}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; GSR="${GS}/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml"
has "${GSA}" '^  name: __SET_NAME__$' "gatedSet: the ApplicationSet's name is the set's"
has "${GSA}" '^            operator: __SET_SELECTOR_OPERATOR__$' "gatedSet: the generator selects on clearanceGate"
has "${GSA}" '^  __GATED_SET_ONLY__  - jsonPointers: \[/spec/source, /spec/sources\]$' "gatedSet: the source ignore rule is marked gated-set-only"
has "${GSA}" '^  __GATED_SET_ONLY__  annotations: \[clearance.hangar.io/switched\]$' "gatedSet: preservedFields keeps the agent's switched marker (gated set only)"
has "${GSA}" '^      __TENANT_SET_ONLY__  - resources-finalizer.argocd.argoproj.io$' "gatedSet: the resources finalizer is tenant-onboarding's only"
has "${GSA}" '^    \{\{- if and __SET_STATIC_PLUGIN__ \(regexMatch' "gatedSet: the static plugin source is switched per set"
[ "$(grep -c '^        __GATED_SET_ONLY__- repoURL: "{{.gitopsRepoUrl}}"$' "${GSA}")" = 2 ] && [ "$(grep -c '^        __TENANT_SET_ONLY__- repoURL: "{{.gitopsRepoUrl}}"$' "${GSA}")" = 2 ] \
  && ok "gatedSet: the gated set lists the \$appsrc source first (the agent's carrier), tenant-onboarding after the chart (template and templatePatch)" \
  || bad "gatedSet: the \$appsrc source is not ordered per set in both the template and the templatePatch"
[ "$(grep -c '^        __GATED_SET_ONLY__  path: \.$' "${GSA}")" = 2 ] && [ "$(grep -c '^        __TENANT_SET_ONLY__  path:' "${GSA}")" = 0 ] \
  && ok "gatedSet: the gated set's \$appsrc carrier has path . (I-82: the agent copies it into its plugin source), tenant-onboarding's has none" \
  || bad "gatedSet: the gated \$appsrc source lacks path . in the template or the templatePatch, or tenant-onboarding's gained one"
python3 - "${GSA}" <<'PY' && ok "gatedSet: every \$appsrc source with a path keeps directory.exclude \"*\" (it renders nothing)" || bad "gatedSet: an \$appsrc source with a path would render the repository root"
import re, sys
lines = open(sys.argv[1]).read().splitlines()
n = 0
for i, l in enumerate(lines):
    if re.fullmatch(r"\s+__GATED_SET_ONLY__  path: \.", l):
        blk = lines[i - 3:i + 3]
        assert any("ref: appsrc" in b for b in blk) and any("exclude: \"*\"" in b for b in blk), blk
        n += 1
assert n == 2, n
PY
has "${GSR}" '"__SET_NAME__" "tenant-onboarding-gated"' "gatedSet: render.yaml emits tenant-onboarding-gated"
has "${GSR}" '"__SET_SELECTOR_OPERATOR__" "NotIn"' "gatedSet: tenant-onboarding excludes the gated environments"
if grep -q 'applicationsSync' "${GSA}"; then bad "gatedSet without gatedSetHandover: applicationsSync rendered"; else ok "gatedSet without gatedSetHandover: no applicationsSync (both sets delete what they stop generating, as before)"; fi
GSH="${TMP}/gate-set-handover"
new "${GSH}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSet=true --set clearance.gate.agent.gatedSetHandover=true
render_ok "${GSH}" "gate opt-in with the gated set and the handover window"
has "${GSH}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^    applicationsSync: create-update$' "gatedSetHandover: both sets create-update (no deletion)"
# The handover window relies on the controller honouring applicationsSync: no controller-wide policy on argocd-apps' ApplicationSet controller.
if grep -q 'applicationsetcontroller.policy' templates/01-argocd-platform/argocd-apps-install/application.yaml; then bad "argocd-apps-install sets applicationsetcontroller.policy: an ApplicationSet's applicationsSync would be ignored"; else ok "argocd-apps-install sets no controller-wide applicationsetcontroller.policy (applicationsSync is honoured)"; fi
for BADP in "clearance.gate.agent.gatedSet=maybe|agent.gatedSet is true or false" "clearance.gate.agent.gatedSetHandover=yes|gatedSetHandover is true or false" \
            "clearance.gate.agent.optIn=false|gatedSet needs the gate and its agent" "clearance.gate.lowerZone=false|gatedSet needs the gate and its agent" \
            "clearance.gate.tenantPlugin=true|gatedSet needs clearance.gate.tenantPlugin: false"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-set-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
    --set clearance.gate.agent.gatedSet=true --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-set-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "gated set ${BAD}: refused (${WANT})"; else bad "gated set ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
new "${TMP}/gate-set-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSetHandover=true
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-set-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -qF -- "gatedSetHandover is the handover window" <<<"${BADERR}"; then ok "gatedSetHandover without gatedSet: refused"; else bad "gatedSetHandover without gatedSet: rc=${BADRC} ${BADERR}"; fi
