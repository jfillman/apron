# tests/cases/54-rollout-order.sh (see tests/run.sh)
# group: render
# secs: 9
# needs: lab gate-on
echo "== 5r. the Clearance rollout order (I-77: argocd-apps-install's PreSync hook, only with the gate and its policies on the cluster)"
ROF=01-argocd-platform/argocd-apps-install/application.yaml
# Off: no hook and no retry, on every cluster without the gate (the lab pair) or without its policies (a lower zone without lowerZone).
for D in "${LAB}/dev" "${LAB}/prod"; do
  if grep -qE 'clearance-rollout-order|extraObjects|^    retry:' "${D}/${ROF}"; then bad "rollout order without the gate: rendered in ${D##*/}"; else ok "rollout order without the gate (${D##*/}): no hook, no retry"; fi
done
new "${TMP}/ro-lower" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${GATE_SET[@]}"
render_ok "${TMP}/ro-lower" "gate on a lower zone without lowerZone"
if grep -qE 'clearance-rollout-order|^    retry:' "${TMP}/ro-lower/${ROF}"; then bad "rollout order on a lower zone without the policies: rendered"; else ok "rollout order on a lower zone without the policies: nothing to order, no hook"; fi
# On without the agent (only the gate policy to wait for), and on with the agent, grant-expiry and Flight admission.
has "${TMP}/gate/${ROF}" '^        extraObjects:$' "rollout order, gate without the agent: the hook renders"
has "${TMP}/gate/${ROF}" '\\"policies\\":\[\{\\"name\\":\\"clearance-protected-writes\\"' "rollout order, gate without the agent: the gate policy is checked"
if grep -E 'name: CHECKS|resourceNames:' "${TMP}/gate/${ROF}" | grep -q 'flight-only-images'; then bad "rollout order without Flight admission: checks flight-only-images"; else ok "rollout order without Flight admission: flight-only-images is not checked"; fi
has "${TMP}/gate/${ROF}" '\\"agent\\":null' "rollout order, gate without the agent: no agent to wait for"
has "${TMP}/gate/${ROF}" '^                resourceNames: \["argocd-apps-repo-server"\]$' "rollout order, gate without the agent: reads only the repo-server Deployment"
i44 ro-full --set clearance.gate.agent.grantExpiry.enabled=true \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true
render_ok "${TMP}/ro-full" "rollout order with the agent, grant-expiry and Flight admission"
has "${TMP}/ro-full/${ROF}" '^    retry:$' "rollout order: argocd-apps-install retries a sync the hook failed"
has "${TMP}/ro-full/${ROF}" '^                resourceNames: \[flight-only-images\]$' "rollout order with Flight admission: may read flight-only-images"
# I-79: the hook's RBAC and ConfigMap go when every sync operation ends, passed or failed, so a revert leaves no ClusterRoleBinding
# (Argo CD never prunes a live hook); the Job goes when it passed, and a failed one is kept for its log no longer than a day.
ro_life="$(awk '/^        extraObjects:$/,/^        controller:$/' "${TMP}/ro-full/${ROF}" | grep -E 'hook-delete-policy:|^            kind: |ttlSecondsAfterFinished:' | sed 's/^ *//' | tr '\n' ' ')"
if [ "${ro_life}" = "kind: ServiceAccount argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded,HookFailed kind: ClusterRole argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded,HookFailed kind: ClusterRoleBinding argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded,HookFailed kind: ConfigMap argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded,HookFailed kind: Job argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded ttlSecondsAfterFinished: 86400 " ]; then
  ok "rollout order lifecycle: RBAC and ConfigMap deleted at the end of every sync, the Job when it passed (a failed one after a day)"
else
  bad "rollout order lifecycle: got ${ro_life}"
fi
# Helm runs the argo-cd chart's extraObjects through tpl: a double opening brace would be read as a template action.
if awk '/^        extraObjects:$/,/^#@end|^        controller:$/' "${TMP}/ro-full/${ROF}" | grep -qF '{{'; then bad "rollout order: extraObjects hold a double opening brace (Helm tpl)"; else ok "rollout order: no double opening brace in extraObjects (Helm tpl)"; fi
i44 ro-off --set clearance.gate.rolloutOrder=false
render_ok "${TMP}/ro-off" "gate with clearance.gate.rolloutOrder: false"
if grep -qE 'clearance-rollout-order|extraObjects|^    retry:' "${TMP}/ro-off/${ROF}"; then bad "rolloutOrder false: the hook rendered"; else ok "rolloutOrder false: no hook, no retry"; fi
i44 ro-bad --set clearance.gate.rolloutOrder=sometimes
i44_refused ro-bad "clearance.gate.rolloutOrder is true or false" "clearance.gate.rolloutOrder that is not a boolean"
if [ "${HAVE_YAML}" != true ]; then
  echo "  skip rollout-order hook script: no PyYAML"
elif out="$(ROLLOUT_ORDER_RENDER="${TMP}/ro-full/${ROF}" python3 tests/rollout/test_rollout_order.py 2>&1)"; then
  ok "rollout-order hook script and its render: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "rollout-order hook script: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi
