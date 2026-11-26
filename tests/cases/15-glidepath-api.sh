# tests/cases/15-glidepath-api.sh (see tests/run.sh)
# group: render
# secs: 37
# needs: lab glidepath-api-warn
GA="${TMP}/gpapi"
GW=30-policy/kyverno-policies/tower-identity-writes.yaml
CPV=50-glidepath/glidepath-control-plane/values.yaml
# itsm.enabled (glidepath-app, pipeline trust T4 step 3) follows itsm.provider: true with the webhook provider (hangar-dev's mock), absent without.
mkdir -p "${GA}/itsm" "${GA}/noitsm"
{ cat "${LAB}/dev/cluster.yaml"; echo 'itsm: {provider: webhook, webhookUrl: "http://itsm-mock.platform-system.svc.cluster.local:8080/webhook"}'; } >"${GA}/itsm/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'itsm: {provider: null, webhookUrl: null}'; } >"${GA}/noitsm/cluster.yaml"
render_ok "${GA}/itsm" "dev with the webhook ITSM provider"
render_ok "${GA}/noitsm" "dev with no ITSM provider"
for d in itsm noitsm; do [ -f "${GA}/${d}/${CPV}" ] || bad "glidepath control plane: the ${d} render has no ${CPV} to check"; done
if awk '/^itsm:$/{f=1;next} f&&/^  enabled: true$/{ok=1} f&&/^[^ #]/{f=0} END{exit !ok}' "${GA}/itsm/${CPV}"; then ok "glidepath control plane: the webhook ITSM provider renders itsm.enabled: true"; else bad "glidepath control plane: the webhook ITSM provider does not render itsm.enabled: true"; fi
if grep -q '^itsm:' "${GA}/noitsm/${CPV}"; then bad "glidepath control plane: no ITSM provider still renders itsm.enabled"; else ok "glidepath control plane: no ITSM provider leaves itsm.enabled out (false)"; fi
has "${LAB}/dev/${CPV}" '^  concurrencyLimit: 3$' "glidepath control plane: the dev profile queues Pipelines-as-Code runs at 3 per repository"
mkdir -p "${GA}/nogate"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateConcurrency: null, gitopsRepoProvenance: null}'; } >"${GA}/nogate/cluster.yaml"
render_ok "${GA}/nogate" "dev glidepath.gateConcurrency and gitopsRepoProvenance unset"
[ -f "${GA}/nogate/${CPV}" ] || bad "glidepath control plane: the unset render has no ${CPV} to check"
if grep -q 'pipelinesAsCode:' "${GA}/nogate/${CPV}"; then bad "glidepath control plane: glidepath.gateConcurrency and gitopsRepoProvenance unset still render a pipelinesAsCode block"; else ok "glidepath control plane: unset gateConcurrency and gitopsRepoProvenance leave pipelinesAsCode out"; fi
has "${LAB}/dev/${CPV}" '^  gitopsRepoProvenance: default_branch$' "glidepath control plane: the dev profile reads gitops repositories' .tekton from the default branch"
has "${LAB}/dev/${CPV}" '^pipelinesAsCode:$' "glidepath control plane: limit and provenance share one pipelinesAsCode block"
mkdir -p "${GA}/noprov"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: null}'; } >"${GA}/noprov/cluster.yaml"
render_ok "${GA}/noprov" "dev glidepath.gitopsRepoProvenance unset"
[ -f "${GA}/noprov/${CPV}" ] || bad "glidepath control plane: the unset-provenance render has no ${CPV} to check"
has "${GA}/noprov/${CPV}" '^  concurrencyLimit: 3$' "glidepath control plane: unset gitopsRepoProvenance keeps the concurrency limit"
if grep -q 'gitopsRepoProvenance' "${GA}/noprov/${CPV}"; then bad "glidepath control plane: glidepath.gitopsRepoProvenance unset still renders gitopsRepoProvenance"; else ok "glidepath control plane: unset glidepath.gitopsRepoProvenance leaves it out"; fi
has "${GA}/warn/${GW}" '^  validationActions: \[Warn, Audit\]$' "glidepath-api: glidepath.sourceIsolation warn warns"
has "${GA}/warn/${CPV}" '^  sourceIsolationActions: \[Warn, Audit\]$' "glidepath control plane: warn flips Glidepath's own binding too"
has "${GA}/warn/${GW}" "expression: '\[\"fast\"\]'" "glidepath-api: glidepath.runStorageClasses is the volumeClaimTemplate allowlist"
has "${LAB}/dev/${GW}" "expression: '\[\]'" "glidepath-api: no storage class is allowed by default"
# glidepath.runShape: Glidepath's cicd-run-shape and cicd-run-no-taskruns bindings (cicdRunAdmission.shapeActions, noTaskRunsActions).
mkdir -p "${GA}/shape-warn" "${GA}/shape-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {runShape: warn}'; } >"${GA}/shape-warn/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {runShape: maybe}'; } >"${GA}/shape-bad/cluster.yaml"
render_ok "${GA}/shape-warn" "dev glidepath.runShape warn"
has "${LAB}/dev/${CPV}" '^  shapeActions: \[Deny\]$' "glidepath control plane: cicd-run-shape Deny by default"
has "${LAB}/dev/${CPV}" '^  noTaskRunsActions: \[Deny\]$' "glidepath control plane: cicd-run-no-taskruns Deny by default"
has "${GA}/shape-warn/${CPV}" '^  shapeActions: \[Warn, Audit\]$' "glidepath.runShape warn: cicd-run-shape warns"
has "${GA}/shape-warn/${CPV}" '^  noTaskRunsActions: \[Warn, Audit\]$' "glidepath.runShape warn: cicd-run-no-taskruns warns"
has "${GA}/shape-warn/${CPV}" '^  sourceIsolationActions: \[Deny\]$' "glidepath.runShape warn leaves source isolation (its own key) at Deny"
if python3 hack/check.py --cluster "${GA}/shape-bad/cluster.yaml" >/dev/null 2>"${GA}/shape-bad/err"; then
  bad "glidepath.runShape: maybe was accepted"
else
  grep -q 'glidepath.runShape' "${GA}/shape-bad/err" && ok "glidepath.runShape: an unknown value is refused by apron check" || bad "runShape refusal: $(cat "${GA}/shape-bad/err")"
fi
# Load reduction (2026-11-15): Kyverno's TTL interval, the platform CronJobs' own minutes, and Argo CD's ignored heartbeat annotation.
KV=30-policy/kyverno/application.yaml
has "${LAB}/dev/${KV}" '^            reconciliationInterval: 5m$' "dev: Kyverno ttlController.reconciliationInterval is 5m"
has "${LAB}/prod/${KV}" '^            reconciliationInterval: 1m$' "prod: Kyverno ttlController.reconciliationInterval stays at the chart's 1m"
has "${LAB}/dev/55-autopilot/agentrun-reaper/reaper.yaml" '^  schedule: "7-59/10 \* \* \* \*"$' "dev: agentrun-reaper runs at minute 7"
has "${LAB}/dev/55-autopilot/agentrun-reaper/reaper.yaml" '^  startingDeadlineSeconds: 300$' "dev: agentrun-reaper has a startingDeadlineSeconds"
has "${LAB}/dev/01-argocd-platform/install.yaml" 'ignoreResourceUpdates.Secret' "dev: Argo CD has an ignoreResourceUpdates rule for Secrets"
# the annotation is ignored on both kinds the observer stamps (ConfigMap heartbeat, Secret canary): one jq path under each rule
BEAT="$(grep -c "^      - '.metadata.annotations.\"observe-k8s.clearance.hangar.io/beat\"'$" "${LAB}/dev/01-argocd-platform/install.yaml")"
[[ "${BEAT}" == 2 ]] && ok "dev: Argo CD ignores the observer's heartbeat annotation on ConfigMaps and Secrets" || bad "heartbeat annotation ignore rules: ${BEAT} (want 2)"
{ cat "${LAB}/dev/cluster.yaml"; echo 'kyverno: {ttlReconciliationInterval: soon}'; } >"${GA}/kv-bad.yaml"
if python3 hack/render.py --cluster "${GA}/kv-bad.yaml" --out "${GA}/kv-bad-out" >/dev/null 2>&1; then
  bad "kyverno.ttlReconciliationInterval: soon was accepted"
else
  ok "kyverno.ttlReconciliationInterval: an unknown duration is refused"
fi
# glidepath.refProtection: the catalog's refProtection.mode (T3's verify-ref-protection task); required unless the cluster says off.
CATV=50-glidepath/glidepath-catalog/application.yaml
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {refProtection: off}'; } >"${GA}/rp-off.yaml"
mkdir -p "${GA}/rp-off" "${GA}/rp-bad"
cp "${GA}/rp-off.yaml" "${GA}/rp-off/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {refProtection: sometimes}'; } >"${GA}/rp-bad/cluster.yaml"
render_ok "${GA}/rp-off" "dev glidepath.refProtection off"
has "${LAB}/dev/${CATV}" '^            mode: "required"$' "glidepath catalog: refProtection.mode is required by default"
has "${GA}/rp-off/${CATV}" '^            mode: "off"$' "glidepath catalog: glidepath.refProtection off renders mode off"
if python3 hack/check.py --cluster "${GA}/rp-bad/cluster.yaml" >/dev/null 2>"${GA}/rp-bad/err"; then
  bad "glidepath.refProtection: sometimes was accepted"
else
  grep -q 'glidepath.refProtection' "${GA}/rp-bad/err" && ok "glidepath.refProtection: an unknown value is refused by apron check" || bad "refProtection refusal: $(cat "${GA}/rp-bad/err")"
fi
# promotion.gateLedger.writer (W-8): who writes the gate ledger. Unset renders no gateLedger key (the catalog's direct stands); api renders it.
mkdir -p "${GA}/glw-api" "${GA}/glw-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'promotion: {gateLedger: {writer: api}}'; } >"${GA}/glw-api/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'promotion: {gateLedger: {writer: pipeline}}'; } >"${GA}/glw-bad/cluster.yaml"
render_ok "${GA}/glw-api" "dev promotion.gateLedger.writer api"
has "${GA}/glw-api/${CATV}" '^          promotion: \{.*"gateLedger": \{"writer": "api"\}' "glidepath catalog: promotion.gateLedger.writer api reaches the catalog values"
if grep -q 'gateLedger' "${LAB}/dev/${CATV}"; then bad "promotion.gateLedger.writer unset: dev still renders a gateLedger key"; else ok "promotion.gateLedger.writer unset: dev renders no gateLedger key (unchanged)"; fi
if python3 hack/check.py --cluster "${GA}/glw-bad/cluster.yaml" >/dev/null 2>"${GA}/glw-bad/err"; then
  bad "promotion.gateLedger.writer: pipeline was accepted"
else
  grep -q 'promotion.gateLedger.writer' "${GA}/glw-bad/err" && ok "promotion.gateLedger.writer: an unknown value is refused by apron check" || bad "gateLedger.writer refusal: $(cat "${GA}/glw-bad/err")"
fi
# glidepath.gateReports.transport (W-8): how api-compat and policy-validation hand over their report. Unset renders no gateReports key
# (the catalog's configmap stands); log renders it as one line; an unknown value is refused by both render and check.
mkdir -p "${GA}/grt-log" "${GA}/grt-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateReports: {transport: log}}'; } >"${GA}/grt-log/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateReports: {transport: pod}}'; } >"${GA}/grt-bad/cluster.yaml"
render_ok "${GA}/grt-log" "dev glidepath.gateReports.transport log"
has "${GA}/grt-log/${CATV}" '^          gateReports: \{"transport": "log"\}' "glidepath catalog: glidepath.gateReports.transport log reaches the catalog values"
if grep -q 'gateReports' "${LAB}/dev/${CATV}"; then bad "glidepath.gateReports.transport unset: dev still renders a gateReports key"; else ok "glidepath.gateReports.transport unset: dev renders no gateReports key (unchanged)"; fi
if [ "$(diff "${LAB}/dev/${CATV}" "${GA}/grt-log/${CATV}" | grep -c '^[<>]')" = 1 ]; then ok "glidepath.gateReports.transport log: the catalog Application differs from unset by one line"; else bad "gateReports log diff: $(diff "${LAB}/dev/${CATV}" "${GA}/grt-log/${CATV}")"; fi
if python3 hack/check.py --cluster "${GA}/grt-bad/cluster.yaml" >/dev/null 2>"${GA}/grt-bad/err"; then
  bad "glidepath.gateReports.transport: pod was accepted by apron check"
else
  grep -q 'glidepath.gateReports.transport' "${GA}/grt-bad/err" && ok "glidepath.gateReports.transport: an unknown value is refused by apron check" || bad "gateReports.transport check refusal: $(cat "${GA}/grt-bad/err")"
fi
if python3 hack/render.py --cluster "${GA}/grt-bad/cluster.yaml" --out "${GA}/grt-bad" >/dev/null 2>"${GA}/grt-bad/rerr"; then
  bad "glidepath.gateReports.transport: pod was rendered"
else
  grep -q 'glidepath.gateReports.transport' "${GA}/grt-bad/rerr" && ok "glidepath.gateReports.transport: an unknown value is refused by apron render" || bad "gateReports.transport render refusal: $(cat "${GA}/grt-bad/rerr")"
fi
# releaseGuardrailOverrides: the catalog's per-cluster `required` of a release gate (glidepath release-guardrails.md "Who sets it"), e.g.
# clearance-gate required on one cluster (docs/admin/clearance-gate.md, G-ARGO-8). Unset renders no key at all, so every other cluster is byte-identical.
mkdir -p "${GA}/gro-on" "${GA}/gro-bad" "${GA}/gro-bad2"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: true}}'; } >"${GA}/gro-on/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: "yes"}}'; } >"${GA}/gro-bad/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: [clearance-gate]'; } >"${GA}/gro-bad2/cluster.yaml"
render_ok "${GA}/gro-on" "dev releaseGuardrailOverrides clearance-gate required"
has "${GA}/gro-on/${CATV}" '^          releaseGuardrailOverrides: \{"clearance-gate": \{"required": true\}\}$' "glidepath catalog: releaseGuardrailOverrides carries clearance-gate required: true"
has "${GA}/gro-on/${CATV}" '^          releaseGuardrailOverridesByApp: ' "glidepath catalog: the by-app map is still rendered beside it"
[ -f "${LAB}/dev/${CATV}" ] || bad "releaseGuardrailOverrides: the dev render has no ${CATV} to check"
if grep -q '^          releaseGuardrailOverrides:' "${LAB}/dev/${CATV}"; then bad "releaseGuardrailOverrides unset: dev still renders the key"; else ok "releaseGuardrailOverrides unset: dev renders no key (unchanged)"; fi
# hangar-prod: the key set in its cluster.yaml (a mistake, or a copy of the dev file) reaches nothing, because a prod-profile cluster runs no
# glidepath-catalog Application (components.glidepath is off in profiles/prod.yaml); its unset render is proven byte-identical in the PR's diff.
mkdir -p "${GA}/gro-prod"
{ cat "${LAB}/prod/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: true}}'; } >"${GA}/gro-prod/cluster.yaml"
render_ok "${GA}/gro-prod" "prod releaseGuardrailOverrides set"
[ ! -f "${LAB}/prod/${CATV}" ] || bad "releaseGuardrailOverrides: prod renders a glidepath-catalog Application (this assertion needs updating)"
if grep -rq 'releaseGuardrailOverrides' "${GA}/gro-prod"/[0-9][0-9]-*; then bad "releaseGuardrailOverrides: the prod render carries the key"; else ok "releaseGuardrailOverrides: the prod render carries no override (no catalog Application there)"; fi
for b in gro-bad gro-bad2; do
  if python3 hack/check.py --cluster "${GA}/${b}/cluster.yaml" >/dev/null 2>"${GA}/${b}/err"; then
    bad "releaseGuardrailOverrides: ${b} was accepted"
  else
    grep -q 'releaseGuardrailOverrides' "${GA}/${b}/err" && ok "releaseGuardrailOverrides: ${b} is refused by apron check" || bad "releaseGuardrailOverrides ${b} refusal: $(cat "${GA}/${b}/err")"
  fi
done
# versions.glidepath: cluster.yaml overrides versions.yaml (the resolution order), so a cluster can pin its own Glidepath revision.
mkdir -p "${GA}/rev"
{ cat "${LAB}/dev/cluster.yaml"; echo 'versions: {glidepath: v9.9.9}'; } >"${GA}/rev/cluster.yaml"
APRON_GLIDEPATH_CHECK=off python3 hack/render.py --cluster "${GA}/rev/cluster.yaml" >/dev/null 2>&1
has "${GA}/rev/50-glidepath/glidepath-control-plane/application.yaml" 'targetRevision: v9.9.9' "versions.glidepath in cluster.yaml overrides the pin"
