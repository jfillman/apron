# tests/cases/23-gate-opt.sh (see tests/run.sh)
# group: render
# secs: 3
# G-ARGO-10c on a lower cluster that runs the core (a rehearsal): the gate stack on a lower zone, no tenant Application on the plugin,
# the agent's annotation opt-in and environment, and the core's NetworkPolicies for the repo-server and the agent. All off by default.
new "${TMP}/gate-opt" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}"
render_ok "${TMP}/gate-opt" "lower cluster, gate with the opt-in"
expect "${TMP}/gate-opt" "gate.lowerZone" 56-clearance-gate/admission.yaml 56-clearance-gate/clearancegrant-crd.yaml 56-clearance-gate/agent/application.yaml
OA="${TMP}/gate-opt/56-clearance-gate/agent/application.yaml"
has "${OA}" '^        optIn:$' "gate.agent.optIn: the agent's chart gets optIn"
has "${OA}" '^          enabled: true$' "gate.agent.optIn: enabled"
has "${OA}" '^        environment: "dev"$' "gate.agent.environment: the agent's default environment"
has "${TMP}/gate-opt/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" 'regexMatch "\^\$" .appName' "gate.tenantPlugin false: no app name matches the plugin regex"
# W-43 (clearance.gate.agent.gatedSet, default off): with it off the tenant-onboarding chart is what it was, even with optIn on;
# with it on the chart renders two ApplicationSets (tenant-onboarding, tenant-onboarding-gated) from one template. What the
# controller does with them is tested against the real Argo CD ApplicationSet controller in tests/appset (section 5).
