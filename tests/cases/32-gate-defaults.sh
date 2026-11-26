# tests/cases/32-gate-defaults.sh (see tests/run.sh)
# group: render
# secs: 16
# needs: lab gate-agent gate-opt
# default off: the agent of an ordinary gate render has no opt-in and no environment, a cluster without the gate has no agent rule
if grep -q 'optIn:\|environment:' "${TMP}/gate-agent/56-clearance-gate/agent/application.yaml"; then bad "gate.agent without optIn: optIn or environment rendered"; else ok "gate.agent without optIn: no optIn and no environment (the render is today's)"; fi
if grep -q 'regexMatch "\^\$"' "${TMP}/gate-agent/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then bad "tenantPlugin unset: the plugin regex matches no app"; else ok "tenantPlugin unset: the plugin regex is as before"; fi
if grep -q 'argocd-repo-server\|clearance-argocd-agent' "${LAB}/dev/55-clearance/clearance/application.yaml"; then bad "gate off: the core's NetworkPolicy names the repo-server or the agent"; else ok "gate off: the core's NetworkPolicy is as before"; fi
new "${TMP}/gate-lower-off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${OPT_SET[@]}" --set clearance.gate.lowerZone=false
render_ok "${TMP}/gate-lower-off" "lower cluster, gate with lowerZone false"
expect "${TMP}/gate-lower-off" "gate.lowerZone false" '!56-clearance-gate/admission.yaml' '!56-clearance-gate/agent/application.yaml'
for BADP in "clearance.gate.agent.optIn=maybe|agent.optIn is true or false" "clearance.gate.agent.environment=Bad_Env|agent.environment is a DNS label" \
            "clearance.gate.tenantPlugin=maybe|tenantPlugin is true or false" "clearance.gate.lowerZone=maybe|lowerZone is true or false" \
            "versions.clearance.argocdAgentChart=0.48.0|needs versions.clearance.argocdAgentChart 0.49.0" "clearance.extraProviders=[]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: argocd-agent-dev, version: '1', principals: [a/b], protection: ['a/b=hangar-prod']}]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: other, version: '1', principals: [other/sa], protection: ['other/sa=hangar-dev']}]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: other, version: '1', principals: [other/sa], protection: ['clearance-system/clearance-argocd-agent=hangar-dev']}]|needs a clearance.extraProviders entry with protection"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-opt-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-opt-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "gate opt-in ${BAD}: refused (${WANT})"; else bad "gate opt-in ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
# a glob entry that covers the agent's principal is accepted; so is a renamed agent account, when the entry names it
new "${TMP}/gate-opt-glob" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: ["clearance-system/*"], protection: ["clearance-system/*=hangar-dev"]}]'
render_ok "${TMP}/gate-opt-glob" "gate opt-in: a protection glob that covers the agent's principal"
new "${TMP}/gate-opt-sa" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agentServiceAccount=clearance-system:the-agent \
  --set 'clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: ["clearance-system/the-agent"], protection: ["clearance-system/the-agent=hangar-dev"]}]'
render_ok "${TMP}/gate-opt-sa" "gate opt-in: a renamed agent account named by its entry"
has "${TMP}/gate-opt-sa/56-clearance-gate/agent/application.yaml" '^          name: "the-agent"$' "gate opt-in: the renamed account is the agent chart's serviceAccount.name"
has "${TMP}/gate-opt-sa/56-clearance-gate/admission.yaml" "== 'system:serviceaccount:clearance-system:the-agent'" "gate opt-in: the policy names the same account as the only grant writer"
if grep -q 'serviceAccount:' "${TMP}/gate-opt/56-clearance-gate/agent/application.yaml"; then bad "agentServiceAccount unset: the agent chart's serviceAccount is set"; else ok "agentServiceAccount unset: the agent chart's own account name (the render is today's)"; fi
new "${TMP}/gate-opt-sa-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agentServiceAccount=other-ns:the-agent
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-opt-sa-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "agentServiceAccount is clearance-system:<name>" <<<"${BADERR}"; then ok "gate.agentServiceAccount outside clearance-system with the agent is refused"; else bad "gate.agentServiceAccount other-ns: rc=${BADRC} ${BADERR}"; fi
new "${TMP}/gate-off" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set 'clearance.protectedEnvironments=[no-slash]'
render_ok "${TMP}/gate-off" "gate off with a protectedEnvironments entry the gate would refuse"
new "${TMP}/gate-noimg" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set clearance.gate.enabled=true \
  --set 'versions.clearance.cmpImage=' --set 'versions.clearance.waitImage='
if python3 hack/render.py --cluster "${TMP}/gate-noimg/cluster.yaml" >/dev/null 2>&1; then
  bad "gate on without the images rendered"
else
  ok "gate on without versions.clearance.cmpImage and waitImage is refused"
fi
