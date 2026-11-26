# tests/cases/21-gate-sidecar.sh (see tests/run.sh)
# group: render
# secs: 1
# needs: lab gate-on gate-agent
has "${TMP}/gate-agent/56-clearance-gate/agent/application.yaml" 'clearance-api.hangar-dev.local' "gate.agent: the agent's host alias names clearance-api"
has "${TMP}/gate-agent/01-argocd-platform/argocd-apps-install/application.yaml" 'hostAliases: \[\{"ip": "192.0.2.1"' "gate.hostAlias: the repo-server gets it"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'value: "http://clearance.hangar-dev.local"' "gate on: the sidecar reaches the core at clearance.gate.url"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'audience: clearance' "gate on: the clearance token is a projected, audience-bound service-account token"
if grep -n 'clearance-cmp\|name: clearance$' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml" "${TMP}/lab/prod/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" | grep -v '^[^:]*:[0-9]*: *#' | grep -q .; then
  bad "gate off: the plugin leaked into a cluster that did not ask for it"
else
  ok "gate off: no sidecar and no plugin source"
fi
if grep -q 'CLEARANCE_CHART_REPOS' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml"; then bad "gate off: the chart allow list leaked into a cluster that did not ask for it"; else ok "gate off: no chart allow list"; fi
# I-78 (`clearance-cmp doctor`): the token is not world-readable, the pod's fsGroup is the sidecar's group, and the memory limit fits the
# default 4 renders x 512Mi. The canary sidecar carries the same limit (checked with the canary render below).
CMPAPP="${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml"
has "${CMPAPP}" "defaultMode: 0440" "gate: the projected clearance token is mode 0440"
has "${CMPAPP}" "fsGroup: 999" "gate: the pod's fsGroup is 999 (the sidecar's uid/group)"
[ "$(grep -c 'limits: {memory: 2560Mi}' "${CMPAPP}")" = 1 ] && ok "gate: the clearance-cmp limit is 2560Mi (4 renders x 512Mi + 512Mi)" || bad "gate: the clearance-cmp memory limit is not 2560Mi"
if grep -q 'limits: {memory: 512Mi}' "${CMPAPP}"; then bad "gate: a sidecar still has the 512Mi limit"; else ok "gate: no sidecar keeps the 512Mi limit"; fi
if grep -q 'defaultMode: 0440\|fsGroup: 999' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml"; then bad "gate off: the token mode or fsGroup leaked"; else ok "gate off: no token mode or fsGroup"; fi
