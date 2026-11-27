# tests/cases/30-delete-guard.sh (see tests/run.sh)
# group: render
# secs: 13
# needs: lab gate-opt gated-set
GS="${TMP}/gate-set"
GSH="${TMP}/gate-set-handover"
# W-46 (d) (tenantOnboarding.deleteGuard, default off): off, nothing renders (every cluster's render is as before); on, the
# tenant-onboarding chart renders the ValidatingAdmissionPolicy that refuses the ApplicationSet controller's delete of a
# tenant-onboarding(-gated) Application. It needs no gate. Admission is tested in section 5 (tests/policy/test_tenant_delete_guard.py),
# the controller's behaviour with it in tests/appset (TestDeleteGuard).
DGF=02-argocd-apps/tenant-onboarding/chart/templates/delete-guard.yaml
for NODG in "${LAB}/dev" "${LAB}/prod" "${GS}" "${GSH}" "${TMP}/gate-opt"; do
  [ ! -e "${NODG}/${DGF}" ] && ok "deleteGuard off (${NODG##*/}): no delete guard rendered" || bad "deleteGuard off (${NODG##*/}): ${DGF} rendered"
done
DG="${TMP}/delete-guard"
new "${DG}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tenantOnboarding.deleteGuard.enabled=true
render_ok "${DG}" "deleteGuard on, no gate"
DGP="${DG}/${DGF}"
has "${DGP}" '^  validationActions: \[Audit\]$' "deleteGuard: validationActions defaults to Audit (the first rollout step)"
# The username comparison is the FIRST matchCondition (a CEL error can then only refuse the controller's own deletes), and it
# names the ServiceAccount argocd-apps-install's ApplicationSet controller runs as.
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${DGP}" <<'PY' && ok "deleteGuard: the username condition is first, on argocd-apps' ApplicationSet controller; every field the second reads is has()-guarded" || bad "deleteGuard: matchConditions"
import re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
p = docs[0]["spec"]
c = p["matchConditions"]
assert p["failurePolicy"] == "Fail" and p["matchConstraints"]["resourceRules"][0]["operations"] == ["DELETE"], p
assert c[0]["expression"] == "request.userInfo.username == 'system:serviceaccount:argocd-apps:argocd-applicationset-controller'", c[0]
e = c[1]["expression"]
for field in ("oldObject.metadata.ownerReferences", "r.controller", "r.apiVersion", "r.kind", "r.name"):
    assert f"has({field})" in e, field
    # every read of the field comes after its has() guard
    assert e.index(f"has({field})") < min(m.start() for m in re.finditer(re.escape(field) + r"(?!\))", e)), field
assert docs[1]["spec"]["policyName"] == docs[0]["metadata"]["name"]
PY
fi
# argocd-apps-install leaves the argo-cd chart's ApplicationSet ServiceAccount name (argocd-applicationset-controller) as it is;
# a rename there must come with tenantOnboarding.deleteGuard.controllerServiceAccount, or the guard matches nobody.
if grep -qE '^ +serviceAccount:' templates/01-argocd-platform/argocd-apps-install/application.yaml; then bad "argocd-apps-install sets a serviceAccount: check the delete guard's controllerServiceAccount"; else ok "argocd-apps-install keeps the chart's ApplicationSet ServiceAccount name (the delete guard's default)"; fi
DGD="${TMP}/delete-guard-deny"
new "${DGD}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSet=true --set tenantOnboarding.deleteGuard.enabled=true --set tenantOnboarding.deleteGuard.validationActions=Deny
render_ok "${DGD}" "deleteGuard Deny, with the gated set"
has "${DGD}/${DGF}" '^  validationActions: \[Deny\]$' "deleteGuard: validationActions Deny"
DGS="${TMP}/delete-guard-sa"
mkdir -p "${DGS}"
{ cat "${LAB}/prod/cluster.yaml"; printf 'tenantOnboarding:\n  deleteGuard: {enabled: true, controllerServiceAccount: appset.ctrl}\n'; } >"${DGS}/cluster.yaml"
render_ok "${DGS}" "deleteGuard on prod, another controller ServiceAccount"
has "${DGS}/${DGF}" "username == 'system:serviceaccount:argocd-apps:appset\.ctrl'" "deleteGuard: controllerServiceAccount names the matched user"
# Same cluster.yaml plus the key: only the guard's file is added, the rest of the render is byte for byte what it was.
if diff -r -x cluster.yaml -x .apron-rendered -x delete-guard.yaml "${LAB}/prod" "${DGS}" >/dev/null \
  && [ "$(diff <(sed 1d "${LAB}/prod/.apron-rendered") <(sed 1d "${DGS}/.apron-rendered") | grep -c '^[<>]')" = 1 ]; then
  ok "deleteGuard: turning it on adds only the guard's file"
else bad "deleteGuard: turning it on changes more than the guard's file"; fi
# A trailing newline would end up inside the policy's CEL string literal: refused (fullmatch, not match).
mkdir -p "${TMP}/delete-guard-nl"
{ cat "${LAB}/dev/cluster.yaml"; printf 'tenantOnboarding:\n  deleteGuard: {enabled: true, controllerServiceAccount: "appset-ctrl\\n"}\n'; } >"${TMP}/delete-guard-nl/cluster.yaml"
BADERR="$(python3 hack/render.py --cluster "${TMP}/delete-guard-nl/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -qF -- "controllerServiceAccount is a ServiceAccount name" <<<"${BADERR}"; then ok "delete guard: a controllerServiceAccount with a trailing newline is refused"; else bad "delete guard: trailing newline: rc=${BADRC} ${BADERR}"; fi
for BADP in "tenantOnboarding.deleteGuard.enabled=maybe|deleteGuard.enabled is true or false" \
            "tenantOnboarding.deleteGuard.validationActions=Warn|validationActions is Audit or Deny" \
            "tenantOnboarding.deleteGuard.controllerServiceAccount=x' or true or 'y|controllerServiceAccount is a ServiceAccount name" \
            "tenantOnboarding.deleteGuard.controllerServiceAccount=Appset|controllerServiceAccount is a ServiceAccount name" \
            "tenantOnboarding.deleteGuard=on|tenantOnboarding.deleteGuard is a mapping"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/delete-guard-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/delete-guard-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "delete guard ${BAD}: refused (${WANT})"; else bad "delete guard ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
