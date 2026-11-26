# tests/cases/26-gate-rule.sh (see tests/run.sh)
# group: render
# secs: 25
# needs: gate-opt gate-agent gated-set
GS="${TMP}/gate-set"
# W-42 (clearance.gate.agent.rule, agent chart 0.56.0 gateRule): unset, nothing renders (every agent above is as before); set, it
# is passed through verbatim, and check holds it to the opt-in, the chart, its own shape and the project and namespace ceiling
# (derived from the rule's literal values when unset). ruleOptions is the chart's gateRuleOptions, only the keys set.
for NORULE in "${TMP}/gate-opt" "${TMP}/gate-agent" "${GS}"; do
  if grep -q 'gateRule' "${NORULE}/56-clearance-gate/agent/application.yaml"; then bad "no rule (${NORULE##*/}): gateRule or gateRuleOptions rendered"; else ok "no rule (${NORULE##*/}): no gateRule in the agent (the render is today's)"; fi
done
rule gate-rule --set "${RULE1}"
render_ok "${TMP}/gate-rule" "gate opt-in with the gate rule"
GRA="${TMP}/gate-rule/56-clearance-gate/agent/application.yaml"
has "${GRA}" '^        gateRule: \{"version": 1, "select": \[\{"name": "rehearsal", ' "rule: the agent chart's gateRule is the rule, as one JSON flow mapping"
has "${GRA}" '^          projects: \["rehearsal"\]$' "rule with projects set: the ceiling is clearance.gate.agent.projects"
if grep -q 'gateRuleOptions' "${GRA}"; then bad "rule without ruleOptions: gateRuleOptions rendered"; else ok "rule without ruleOptions: the chart's own bounds (no gateRuleOptions)"; fi
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${GRA}" "${TMP}/gate-rule/cluster.yaml" <<'PY' && ok "rule: the rendered gateRule is exactly cluster.yaml's rule (verbatim), beside optIn" || bad "rule: the rendered gateRule differs from cluster.yaml's"
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["spec"]["source"]["helm"]["valuesObject"]
want = yaml.safe_load(open(sys.argv[2]))["clearance"]["gate"]["agent"]["rule"]
assert v["gateRule"] == want, (v["gateRule"], want)
assert v["optIn"] == {"enabled": True}, v["optIn"]
assert want["select"][1]["labels"] == {"hangar.io/env": "prod"} and want["exempt"][0]["expires"] == "2026-12-19", want
PY
fi
# The ceiling derived from the rule (projects and protectedNamespaces unset): the literal values, in order, once each.
rule gate-rule-derive --set 'clearance.gate.agent.projects=' --set 'clearance.gate.agent.protectedNamespaces=' \
  --set 'clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a, team-b], namespaces: [app-a-dev]}, {name: b, projects: [team-a], namespaces: [app-b-dev, app-a-dev]}]}' \
  --set 'clearance.gate.agent.ownedProject={create: true}'
render_ok "${TMP}/gate-rule-derive" "gate rule with the ceiling derived from it"
GRD="${TMP}/gate-rule-derive/56-clearance-gate/agent"
has "${GRD}/application.yaml" '^          projects: \["team-a", "team-b"\]$' "rule, projects unset: the ceiling is the rule's literal projects"
has "${GRD}/application.yaml" '^        protectedNamespaces: \["app-a-dev", "app-b-dev"\]$' "rule, protectedNamespaces unset: the rule's literal namespaces"
has "${GRD}/owned.yaml" '^  name: "app-b-dev"$' "rule with ownedProject: the derived namespaces are the ones owned"
rule gate-rule-opts --set "${RULE1}" --set 'clearance.gate.agent.ruleOptions={releaseMax: 1, exemptMax: 720h}'
render_ok "${TMP}/gate-rule-opts" "gate rule with ruleOptions"
has "${TMP}/gate-rule-opts/56-clearance-gate/agent/application.yaml" '^        gateRuleOptions: \{"releaseMax": 1, "exemptMax": "720h"\}$' "ruleOptions: the chart's gateRuleOptions, only the keys set"
# globs: a glob project passes only against "*"; a glob namespace against a listed namespace it matches
rule gate-rule-glob --set 'clearance.gate.agent.projects=["*"]' --set 'clearance.gate.agent.protectedNamespaces=[app-a-prod, app-b-prod]' \
  --set 'clearance.gate.agent.rule={version: 1, select: [{name: prod, projects: ["team-*"], namespaces: ["app-*-prod"]}]}'
render_ok "${TMP}/gate-rule-glob" "gate rule with glob projects and namespaces inside an explicit ceiling"
rule gate-rule-empty --set 'clearance.gate.agent.rule={}'
render_ok "${TMP}/gate-rule-empty" "an empty gate rule"
if grep -q 'gateRule' "${TMP}/gate-rule-empty/56-clearance-gate/agent/application.yaml"; then bad "an empty rule: gateRule rendered"; else ok "an empty rule renders as unset (nothing)"; fi
rule gate-rule-noselect --set 'clearance.gate.agent.rule={version: 1}'
render_ok "${TMP}/gate-rule-noselect" "a rule that selects nothing (the first rollout step)"
has "${TMP}/gate-rule-noselect/56-clearance-gate/agent/application.yaml" '^        gateRule: \{"version": 1\}$' "a rule that selects nothing: gateRule {version: 1}"
# The rule and the gated set: the gated set keeps what the agent asks of a ruled ApplicationSet child (the switched marker preserved,
# the sources ignored), unconditionally; the rule does not change the tenant-onboarding chart.
rule gate-rule-set --set "${RULE1}" --set clearance.gate.agent.gatedSet=true
render_ok "${TMP}/gate-rule-set" "gate rule with the gated set"
diff -r "${GS}/02-argocd-apps" "${TMP}/gate-rule-set/02-argocd-apps" >/dev/null && ok "rule with gatedSet: the tenant-onboarding chart is the gated set's, unchanged" || bad "rule with gatedSet: the rule changed the tenant-onboarding chart"
has "${TMP}/gate-rule-set/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^  __GATED_SET_ONLY__  annotations: \[clearance.hangar.io/switched\]$' "rule with gatedSet: preservedFields keeps clearance.hangar.io/switched"
has "${TMP}/gate-rule-set/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^  __GATED_SET_ONLY__  - jsonPointers: \[/spec/source, /spec/sources\]$' "rule with gatedSet: ignoreApplicationDifferences on /spec/source and /spec/sources"
diff -r "${TMP}/gate-opt/02-argocd-apps" "${TMP}/gate-rule/02-argocd-apps" >/dev/null && ok "rule without gatedSet: the tenant-onboarding chart is unchanged" || bad "rule without gatedSet: the tenant-onboarding chart changed"
