# tests/cases/27-gate-rule-refusals.sh (see tests/run.sh)
# group: render
# secs: 11
for BADP in \
    "clearance.gate.agent.optIn=false|rule needs clearance.gate.agent.optIn: true" \
    "versions.clearance.argocdAgentChart=0.55.0|rule needs versions.clearance.argocdAgentChart 0.56.0 or later" \
    "clearance.gate.lowerZone=false|rule and ruleOptions need the gate and its agent on this cluster" \
    "clearance.gate.agent.rule=nope|clearance.gate.agent.rule is a mapping" \
    "clearance.gate.agent.rule={version: 2}|rule.version is 2: it must be 1" \
    "clearance.gate.agent.rule={version: 1, selects: []}|rule.selects is not a setting" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a}]}|names none of projects, namespaces and labels" \
    "clearance.gate.agent.rule={version: 1, select: [{name: Bad_Name, projects: [rehearsal]}]}|needs a name, a DNS label" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal]}, {name: a, projects: [rehearsal]}]}|the name a is used twice" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, project: [rehearsal]}]}|select[0] (a).project is not a setting" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: rehearsal}]}|projects is a non-empty list of globs" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], labels: {tier: 1}}]}|labels is a non-empty mapping of label key to exact value" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [other]}]}|project other is not in clearance.gate.agent.projects" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [\"team-*\"]}]}|is a glob, and clearance.gate.agent.projects does not hold" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], namespaces: [other]}]}|namespace other is not in clearance.gate.agent.protectedNamespaces" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], namespaces: [\"app-*\"]}]}|matches none of clearance.gate.agent.protectedNamespaces" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: short, expires: \"2026-12-19\"}]}|reason is 10 to 500 characters" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"next week\"}]}|expires is 'next week'" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"2026-02-30\"}]}|expires is '2026-02-30'" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd/web, reason: \"a long enough reason\", expires: \"2026-12-19\"}]}|can never match: the agent reads Applications in argocd-apps" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: web, reason: \"a long enough reason\", expires: \"2026-12-19\"}]}|a glob on <namespace>/<name>" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"2026-12-19\", approvedBy: me}]}|exempt[0].approvedBy is not a setting" \
    "clearance.gate.agent.ruleOptions={releaseMax: 2}|ruleOptions needs clearance.gate.agent.rule" \
    "${RULE1}|clearance.gate.agent.ruleOptions={releaseMax: 0}|releaseMax is 0" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptMax: 2400h}|is over 2160h" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 30s}|exemptionRecheckTimeout must be below exemptionRecheck" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 5 minutes}|exemptionRecheck is '5 minutes'" \
    "${RULE1}|clearance.gate.agent.ruleOptions={releasemax: 1}|ruleOptions.releasemax is not a setting" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 3000000h}|exemptionRecheck is '3000000h'" \
    "${RULE1}|clearance.gate.agent.projects=[\"team-*\"]|the agent compares its projects exactly" \
    "${RULE1}|clearance.gate.agent.protectedNamespaces=[\"app-*\"]|the agent's RBAC is one Role per listed namespace"; do
  WANT="${BADP##*|}"; SETS="${BADP%|*}"
  ARGS=()
  while [ -n "${SETS}" ]; do
    case "${SETS}" in *'|'*) ARGS+=(--set "${SETS%%|*}"); SETS="${SETS#*|}" ;; *) ARGS+=(--set "${SETS}"); SETS="" ;; esac
  done
  case "${BADP}" in clearance.gate.agent.rule=*|clearance.gate.agent.ruleOptions=*|"${RULE1}|"*) ;; *) ARGS=(--set "${RULE1}" "${ARGS[@]}") ;; esac
  rule gate-rule-bad "${ARGS[@]}"
  LBL="${BADP#"${RULE1}|"}"
  rule_refused gate-rule-bad "${WANT}" "gate rule: ${LBL#clearance.gate.agent.}"
done
# Durations at the edge of Go's int64 nanoseconds: 2562047h is in range (accepted), 2562048h is not (above, refused).
rule gate-rule-maxdur --set "${RULE1}" --set 'clearance.gate.agent.ruleOptions={exemptionRecheck: 2562047h, exemptionRecheckTimeout: 30s}'
python3 hack/check.py --cluster "${TMP}/gate-rule-maxdur/cluster.yaml" >/dev/null 2>&1 && ok "ruleOptions: 2562047h, the largest whole-hour Go duration, is accepted" || bad "ruleOptions: 2562047h refused"
# An empty rule with the gate off is unset (nothing to check); a rule that is not a mapping still needs the gate.
new "${TMP}/gate-rule-off-empty" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.rule={}'
render_ok "${TMP}/gate-rule-off-empty" "gate off with an empty rule"
new "${TMP}/gate-rule-off-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.rule=nope'
rule_refused gate-rule-off-bad "rule and ruleOptions need the gate and its agent on this cluster" "gate off with a rule that is not a mapping"
new "${TMP}/gate-rule-off-opts" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.ruleOptions={releaseMax: 2}'
rule_refused gate-rule-off-opts "rule and ruleOptions need the gate and its agent on this cluster" "gate off with ruleOptions and no rule"
# Derivation refusals: with the ceiling unset, an entry that names no project, a glob project, no namespace or a glob namespace
for BADP in \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, namespaces: [app-a-dev]}]}|names no project, so the project ceiling cannot be derived" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [\"team-*\"], namespaces: [app-a-dev]}]}|which the ceiling cannot be derived from" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a]}]}|names no namespace" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a], namespaces: [\"app-*-dev\"]}]}|namespace 'app-*-dev' is a glob: list its namespaces" \
    "clearance.gate.agent.rule={version: 1}|clearance.gate.agent needs projects"; do
  rule gate-rule-bad --set 'clearance.gate.agent.projects=' --set 'clearance.gate.agent.protectedNamespaces=' --set "${BADP%%|*}"
  rule_refused gate-rule-bad "${BADP#*|}" "gate rule, ceiling unset: ${BADP%%|*}"
done
