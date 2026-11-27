# tests/cases/28-sync-paused.sh (see tests/run.sh)
# group: render
# secs: 9
# needs: lab gate-on gate-opt gated-set
GS="${TMP}/gate-set"
# The migration off the static plugin (apron README "Migrating off the static plugin"): tenantOnboarding.syncPaused, a
# per-environment pause of automated sync, and clearance.gate.migration, the window that lets gatedSet sit beside the static
# plugin for the apps it names. Both default off; unset (or empty) the tenant-onboarding chart is byte for byte what it was.
for NOPAUSE in "${TMP}/gate-opt" "${TMP}/gate" "${GS}" "${LAB}/dev" "${LAB}/prod"; do
  if grep -q 'syncPaused\|automated: null\|key: appName\|TENANT_SYNC\|TENANT_WINDOW' "${NOPAUSE}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then
    bad "no syncPaused or window (${NOPAUSE##*/}): the tenant-onboarding chart mentions them"
  else ok "no syncPaused or window (${NOPAUSE##*/}): the tenant-onboarding chart is as before"; fi
done
new "${TMP}/pause-empty" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'tenantOnboarding.syncPaused={}' --set 'clearance.gate.migration={window: false}'
render_ok "${TMP}/pause-empty" "an empty syncPaused and a closed window"
diff -r "${TMP}/gate/02-argocd-apps" "${TMP}/pause-empty/02-argocd-apps" >/dev/null && ok "an empty syncPaused and a closed window: the render is byte for byte the one without them" \
  || bad "an empty syncPaused or a closed window changed the render"
new "${TMP}/pause-nogate" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set 'tenantOnboarding.syncPaused={shop: [dev, qa]}'
render_ok "${TMP}/pause-nogate" "syncPaused without the gate"
PNA="${TMP}/pause-nogate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${PNA}" '^    \{\{- \$syncPaused := regexMatch "\^\(shop/dev\|shop/qa\)\$" \(printf "%s/%s" \.appName \.env\) \}\}$' "syncPaused: one regex over <appName>/<env>"
[ "$(grep -c '^ *automated: null$' "${PNA}")" = 3 ] && ok "syncPaused without the gate: automated: null in the configMapGenerator branch and both {} branches" \
  || bad "syncPaused without the gate: $(grep -c '^ *automated: null$' "${PNA}") automated: null lines, want 3"
out="$(python3 hack/check.py --cluster "${TMP}/pause-nogate/cluster.yaml" 2>&1)"
grep -qF "warning: tenantOnboarding.syncPaused: automated sync is off for shop/dev, shop/qa" <<<"${out}" \
  && ok "syncPaused: apron check warns while it is set" || bad "syncPaused: no warning from apron check: ${out}"
new "${TMP}/pause-gate" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'tenantOnboarding.syncPaused={gate-api: [prod]}'
render_ok "${TMP}/pause-gate" "syncPaused with the static plugin"
[ "$(grep -c '^ *automated: null$' "${TMP}/pause-gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml")" = 4 ] \
  && ok "syncPaused with the static plugin: the plugin branch is paused too" || bad "syncPaused with the static plugin: the plugin branch has no pause"
# Removing the pause lines gives back the render without it: the pause adds lines and changes none.
python3 - "${TMP}/gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" "${TMP}/pause-gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" <<'PY' \
  && ok "syncPaused only adds lines (removing them gives the render without it)" || bad "syncPaused changes lines of the render beyond its own"
import re, sys
a, b = open(sys.argv[1]).read(), open(sys.argv[2]).read()
b = re.sub(r"    \{\{- /\* tenantOnboarding\.syncPaused.*?\*/\}\}\n    \{\{- \$syncPaused := [^\n]*\n", "", b, flags=re.S)
b = b.replace("      {{- if $syncPaused }}\n      syncPolicy:\n        automated: null\n      {{- end }}\n", "")
b = b.replace("    {{- if $syncPaused }}\n    spec:\n      syncPolicy:\n        automated: null\n    {{- else }}\n    {}\n    {{- end }}\n", "    {}\n")
sys.exit(0 if a == b else 1)
PY
for BADP in "tenantOnboarding.syncPaused=[shop]|syncPaused is a mapping" "tenantOnboarding.syncPaused={Shop: [prod]}|'Shop' is not an app name" \
            "tenantOnboarding.syncPaused={shop: []}|syncPaused.shop is a non-empty list" "tenantOnboarding.syncPaused={shop: [prod, prod]}|syncPaused.shop is a non-empty list" \
            "tenantOnboarding.syncPaused={shop: prod}|syncPaused.shop is a non-empty list"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/pause-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set "${BAD}"
  out="$(python3 hack/check.py --cluster "${TMP}/pause-bad/cluster.yaml" 2>&1)" && { bad "${BAD}: check accepted it"; continue; }
  grep -qF -- "${WANT}" <<<"${out}" && ok "${BAD}: refused (${WANT})" || bad "${BAD}: ${out}"
done
