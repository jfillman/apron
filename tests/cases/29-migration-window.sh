# tests/cases/29-migration-window.sh (see tests/run.sh)
# group: render
# secs: 9
# The window: the static plugin on for */prod with clearance.gate.apps [shop, pay], the gated set, and the window for shop.
WIN_SET=("${OPT_SET[@]}" --set clearance.gate.tenantPlugin=true --set 'clearance.protectedEnvironments=["*/prod"]' --set 'clearance.gate.apps=[shop, pay]'
  --set 'clearance.gate.agent.projects=[shop, pay]' --set 'clearance.gate.agent.protectedNamespaces=[app-shop-prod, app-pay-prod]' --set clearance.gate.agent.gatedSet=true)
win() { # win NAME [more --set flags]: the window's base cluster (WIN_SET) with more settings
  local d="${TMP}/$1"; shift
  new "${d}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${WIN_SET[@]}" "$@"
}
# Also the render tests/appset runs (TestMigrationWindow): shop/dev, shop/prod, shop/qa and pay/prod paused.
win gate-window --set 'clearance.gate.migration={window: true, apps: [shop]}' --set 'tenantOnboarding.syncPaused={shop: [dev, prod, qa], pay: [prod]}'
render_ok "${TMP}/gate-window" "the migration window with the static plugin and the gated set"
GWA="${TMP}/gate-window/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
[ "$(grep -c '^            values: \["pay"\]$' "${GWA}")" = 1 ] && has "${GWA}" '^          - key: appName$' "window: both sets' main generator leaves out the held app (appName NotIn [pay])" \
  || bad "window: the main generator's appName NotIn [pay] is not in both sets"
if grep -A12 '__TENANT_SET_ONLY__- git:' "${GWA}" | grep -q 'clearanceGate'; then bad "window: the held-app generator reads clearanceGate"
else ok "window: the held-app generator selects on the app name alone"; fi
has "${GWA}" '^    __TENANT_SET_ONLY__- git:$' "window: tenant-onboarding has a second generator for the held apps"
has "${GWA}" '^    __TENANT_SET_ONLY__        values: \["pay"\]$' "window: tenant-onboarding's second generator takes exactly the held apps"
has "${GWA}" 'regexMatch "\^\(shop\|pay\)\$" \.appName' "window: the static plugin's app regex is still clearance.gate.apps"
out="$(python3 hack/check.py --cluster "${TMP}/gate-window/cluster.yaml" 2>&1)"
grep -qF "warning: clearance.gate.migration.window is open for shop (pay held in tenant-onboarding)" <<<"${out}" && ok "window: apron check warns while it is open" || bad "window: no warning: ${out}"
win gate-window-all --set 'clearance.gate.migration={window: true, apps: [shop, pay]}'
render_ok "${TMP}/gate-window-all" "the migration window for every app of clearance.gate.apps"
if grep -q 'key: appName\|__TENANT_SET_ONLY__- git:' "${TMP}/gate-window-all/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then
  bad "window for every app: a held-app selector rendered"
else ok "window for every app: nothing is held (no appName selector, one generator per set)"; fi
for BADP in \
    "clearance.gate.migration={window: true}|window is open with no apps|a window left open with no apps" \
    "clearance.gate.migration={window: true, apps: []}|window is open with no apps|a window with an empty list" \
    "clearance.gate.migration={window: false, apps: [shop]}|names apps but the window is closed|apps listed with the window closed" \
    "clearance.gate.migration={window: true, apps: [other]}|names other, which clearance.gate.apps leaves out|a window app not in clearance.gate.apps" \
    "clearance.gate.migration={window: yes, apps: [shop]}|migration.window is true or false|window: yes" \
    "clearance.gate.migration={window: true, apps: [shop], app: [pay]}|clearance.gate.migration.app is not a setting|an unknown clearance.gate.migration key"; do
  BAD="${BADP%%|*}"; REST="${BADP#*|}"; WANT="${REST%%|*}"; LABEL="${REST#*|}"
  if [ -n "${BAD}" ]; then win gate-window-bad --set "${BAD}"; else win gate-window-bad; fi
  rule_refused gate-window-bad "${WANT}" "${LABEL}"
done
# Outside the window the refusal is render's, as before (apron check never held gatedSet to tenantPlugin).
win gate-window-bad
out="$(python3 hack/render.py --cluster "${TMP}/gate-window-bad/cluster.yaml" 2>&1)" && bad "gatedSet with the static plugin and no window: rendered" \
  || { grep -qF "gatedSet needs clearance.gate.tenantPlugin: false" <<<"${out}" && ok "gatedSet with the static plugin and no window is refused, as before" \
       || bad "gatedSet with the static plugin and no window: ${out}"; }
for BADP in \
    "clearance.gate.agent.projects=[pay]|leave out its project shop|a window app outside the agent's projects" \
    "clearance.gate.agent.protectedNamespaces=[app-pay-prod]|no namespace of the agent's protectedNamespaces is one of its environments|a window app with no protected namespace" \
    "clearance.gate.apps=[]|window needs clearance.gate.apps|a window with clearance.gate.apps empty (every app on the plugin)" \
    "clearance.gate.agent.gatedSet=false|window needs the gate, its agent and clearance.gate.agent.gatedSet|a window without the gated set" \
    "clearance.gate.tenantPlugin=false|window is for a cluster on the static plugin|a window with tenantPlugin: false"; do
  BAD="${BADP%%|*}"; REST="${BADP#*|}"; WANT="${REST%%|*}"; LABEL="${REST#*|}"
  win gate-window-bad --set 'clearance.gate.migration={window: true, apps: [shop]}' --set "${BAD}"
  rule_refused gate-window-bad "${WANT}" "${LABEL}"
done
