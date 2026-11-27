# tests/cases/24-gate-no-gated-set.sh (see tests/run.sh)
# group: render
# secs: 1
# needs: lab gate-on gate-agent gate-opt
for NOOPT in "${TMP}/gate-opt" "${TMP}/gate-agent" "${TMP}/gate" "${LAB}/prod"; do
  if grep -q 'ignoreApplicationDifferences\|preservedFields\|clearanceGate\|clearance.hangar.io/protect\|__SET_\|_SET_ONLY__\|tenant-onboarding-gated\|applicationsSync' \
      "${NOOPT}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" "${NOOPT}/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml"; then
    bad "no gatedSet (${NOOPT##*/}): the tenant-onboarding chart mentions the gated set"
  else ok "no gatedSet (${NOOPT##*/}): the tenant-onboarding chart is as before (one ApplicationSet, no selector, no ignore rule)"; fi
done
has "${TMP}/gate-opt/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml" '^\{\{- \.Files\.Get "applicationset\.tmpl\.yaml"$' "gatedSet off: render.yaml emits the template once, as before"
