# tests/cases/19-gate-agent.sh (see tests/run.sh)
# group: render
# secs: 18
new "${TMP}/gate-agent" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true
render_ok "${TMP}/gate-agent" "gate on with the agent, one app"
has "${TMP}/gate-agent/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" 'regexMatch "\^\(gate-api\)\$" .appName' "gate.apps: only that app gets the plugin"
has "${TMP}/gate-agent/30-policy/kyverno-policies/flight-images.yaml" 'ghcr.io/acme/clearance-wait@sha256:bbbb' "gate on: Flight admission allows exactly the wait image"
has "${TMP}/gate-agent/56-clearance-gate/admission.yaml" "variables.waitctr.image == 'ghcr.io/acme/clearance-wait@sha256:bbbb' &&" "gate on, no previousWaitImage: the exemption is the single-image test as before"
if grep -q "waitctr.image in" "${TMP}/gate-agent/56-clearance-gate/admission.yaml"; then bad "no previousWaitImage: the exemption renders a list"; else ok "no previousWaitImage: no list in the exemption"; fi
PREV=ghcr.io/acme/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111
new "${TMP}/gate-prev" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true \
  --set "versions.clearance.previousWaitImage=${PREV}"
render_ok "${TMP}/gate-prev" "gate on with versions.clearance.previousWaitImage"
has "${TMP}/gate-prev/56-clearance-gate/admission.yaml" "variables.waitctr.image in \\['ghcr.io/acme/clearance-wait@sha256:bbbb', '${PREV}'\\] &&" "previousWaitImage: the gate exemption admits the new and the previous wait image"
has "${TMP}/gate-prev/30-policy/kyverno-policies/flight-images.yaml" "clearance-wait@sha256:bbbb\", \"${PREV}\"" "previousWaitImage: Flight admission's allow-list has both digests"
has "${TMP}/gate-prev/56-clearance-gate/agent/application.yaml" 'image: "ghcr.io/acme/clearance-wait@sha256:bbbb"' "previousWaitImage: the agent's waitJob.image stays the new digest"
new "${TMP}/gate-prev-same" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true \
  --set "versions.clearance.previousWaitImage=ghcr.io/acme/clearance-wait@sha256:bbbb"
if python3 hack/render.py --cluster "${TMP}/gate-prev-same/cluster.yaml" >/dev/null 2>&1; then bad "previousWaitImage equal to waitImage was accepted"; else ok "previousWaitImage equal to waitImage is refused"; fi
# The agent's previous wait-image pin (I-59, clearance#218; agent chart 0.56.0): previousWaitImage is passed as waitJob.previousImage.
PWJ=(--fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]'
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc)
new "${TMP}/gate-pwj" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.56.0 --set "versions.clearance.previousWaitImage=${PREV}"
render_ok "${TMP}/gate-pwj" "agent chart 0.56.0 with previousWaitImage"
PWA="${TMP}/gate-pwj/56-clearance-gate/agent/application.yaml"
has "${PWA}" "^          previousImage: \"${PREV}\"$" "agent chart 0.56.0: waitJob.previousImage is previousWaitImage"
has "${PWA}" '^          image: "ghcr.io/acme/clearance-wait@sha256:bbbb"$' "agent chart 0.56.0: waitJob.image stays the new digest"
grep -B1 '^          previousImage:' "${PWA}" | head -1 | grep -q '^          #' && ok "agent chart 0.56.0: previousImage sits in waitJob, after its comment" || bad "agent chart 0.56.0: previousImage is not where waitJob.image is"
new "${TMP}/gate-pwj-none" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.56.0
render_ok "${TMP}/gate-pwj-none" "agent chart 0.56.0 without previousWaitImage"
if grep -q 'previousImage' "${TMP}/gate-pwj-none/56-clearance-gate/agent/application.yaml"; then bad "no previousWaitImage: waitJob.previousImage rendered"; else ok "no previousWaitImage: no waitJob.previousImage"; fi
new "${TMP}/gate-pwj-old" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.55.0 --set "versions.clearance.previousWaitImage=${PREV}"
out="$(python3 hack/check.py --cluster "${TMP}/gate-pwj-old/cluster.yaml" 2>&1)" && bad "previousWaitImage on an agent chart before 0.56.0 passed check" \
  || { grep -q 'argocdAgentChart 0.56.0 or later' <<<"${out}" && ok "previousWaitImage on an agent chart before 0.56.0 is refused by check" || bad "previousWaitImage, old agent chart: ${out}"; }
if python3 hack/render.py --cluster "${TMP}/gate-pwj-old/cluster.yaml" >/dev/null 2>&1; then bad "previousWaitImage on an agent chart before 0.56.0 rendered"; else ok "previousWaitImage on an agent chart before 0.56.0 does not render"; fi
python3 hack/render.py --no-check --cluster "${TMP}/gate-pwj-old/cluster.yaml" >/dev/null 2>&1 || bad "previousWaitImage, old agent chart, --no-check: render failed"
if grep -q 'previousImage' "${TMP}/gate-pwj-old/56-clearance-gate/agent/application.yaml"; then bad "agent chart 0.55.0: waitJob.previousImage rendered"; else ok "agent chart 0.55.0 (--no-check): no waitJob.previousImage, the chart has none"; fi
has "${TMP}/gate-pwj-old/56-clearance-gate/admission.yaml" "variables.waitctr.image in \\['ghcr.io/acme/clearance-wait@sha256:bbbb', '${PREV}'\\] &&" "agent chart 0.55.0 (--no-check): the exemption still admits both wait images"
# The gate's clients' CA (A-19, plan steps 4 and 5b): off, no CA in the sidecars or the agent; on, each names the ConfigMap.
AGA="${TMP}/gate-agent/56-clearance-gate/agent/application.yaml"
RSA="${TMP}/gate-agent/01-argocd-platform/argocd-apps-install/application.yaml"
if grep -q 'clearance-ca\|CLEARANCE_CA_FILE\|CLEARANCE_WAIT_CA_CONFIGMAP' "${RSA}" || grep -q 'caConfigMap' "${AGA}"; then
  bad "gate CA off: a CA setting rendered"; else ok "gate CA off: no CA in the sidecar or the agent"; fi
new "${TMP}/gate-ca" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=https://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=https://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.54.0 \
  --set clearance.gate.caConfigMap=hangar-cluster-ca --set clearance.gate.waitCAConfigMap=hangar-cluster-ca --set clearance.gate.waitCAInject=true \
  --set clearance.gate.canary.image=ghcr.io/acme/clearance-cmp@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-ca" "gate on with the clients' CA"
RSC="${TMP}/gate-ca/01-argocd-platform/argocd-apps-install/application.yaml"
AGC="${TMP}/gate-ca/56-clearance-gate/agent/application.yaml"
[ "$(grep -c 'name: CLEARANCE_CA_FILE, value: /etc/clearance-ca/ca.crt' "${RSC}")" = 2 ] && ok "caConfigMap: both sidecars read the CA file" || bad "caConfigMap: CLEARANCE_CA_FILE is not on both sidecars"
[ "$(grep -c 'name: clearance-ca, mountPath: /etc/clearance-ca, readOnly: true' "${RSC}")" = 2 ] && ok "caConfigMap: both sidecars mount the CA read-only" || bad "caConfigMap: the CA mount is not on both sidecars"
[ "$(grep -c 'name: CLEARANCE_WAIT_CA_CONFIGMAP, value: "hangar-cluster-ca"' "${RSC}")" = 2 ] && ok "waitCAInject: both sidecars inject the wait Job's CA" || bad "waitCAInject: CLEARANCE_WAIT_CA_CONFIGMAP is not on both sidecars"
# clearance.gate.fsSandbox (A-24): unset, no CLEARANCE_CMP_FS_SANDBOX renders (gate-agent, gate-ca above); set, both sidecars carry it;
# a value other than try, require or off is refused by render and check.
if grep -q 'CLEARANCE_CMP_FS_SANDBOX' "${RSA}" "${RSC}"; then bad "fsSandbox unset: the env rendered"; else ok "fsSandbox unset: no CLEARANCE_CMP_FS_SANDBOX"; fi
new "${TMP}/gate-fs" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=https://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' \
  --set clearance.gate.fsSandbox=require \
  --set clearance.gate.canary.image=ghcr.io/acme/clearance-cmp@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-fs" "gate on with fsSandbox require"
[ "$(grep -c 'name: CLEARANCE_CMP_FS_SANDBOX, value: "require"' "${TMP}/gate-fs/01-argocd-platform/argocd-apps-install/application.yaml")" = 2 ] \
  && ok "fsSandbox: both sidecars set CLEARANCE_CMP_FS_SANDBOX" || bad "fsSandbox: CLEARANCE_CMP_FS_SANDBOX is not on both sidecars"
python3 hack/check.py --cluster "${TMP}/gate-fs/cluster.yaml" >/dev/null 2>&1 && ok "fsSandbox: check accepts require" || bad "fsSandbox: check refused require"
mkdir -p "${TMP}/gate-fs-bad"
sed 's/fsSandbox: require/fsSandbox: strict/' "${TMP}/gate-fs/cluster.yaml" >"${TMP}/gate-fs-bad/cluster.yaml"
grep -q 'fsSandbox: strict' "${TMP}/gate-fs-bad/cluster.yaml" || bad "fsSandbox: the bad-value fixture did not take"
out="$(python3 hack/render.py --cluster "${TMP}/gate-fs-bad/cluster.yaml" 2>&1)" && bad "fsSandbox: a bad value rendered" \
  || { grep -q 'clearance.gate.fsSandbox' <<<"${out}" && ok "fsSandbox: a bad value is refused by render" || bad "fsSandbox: bad value refusal text: ${out}"; }
out="$(python3 hack/check.py --cluster "${TMP}/gate-fs-bad/cluster.yaml" 2>&1)" && bad "fsSandbox: check accepted a bad value" \
  || { grep -q 'clearance.gate.fsSandbox' <<<"${out}" && ok "fsSandbox: a bad value is refused by check" || bad "fsSandbox: check refusal text: ${out}"; }
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${RSC}" "${AGC}" <<'PY' && ok "gate CA: the repo-server volume is the ConfigMap's ca.crt only; the agent's tls.caConfigMap and waitJob.caConfigMap name it" || bad "gate CA: the rendered values are wrong"
import sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
vols = app["spec"]["source"]["helm"]["valuesObject"]["repoServer"]["volumes"]
ca = [x for x in vols if x["name"] == "clearance-ca"]
assert ca == [{"name": "clearance-ca", "configMap": {"name": "hangar-cluster-ca", "items": [{"key": "ca.crt", "path": "ca.crt"}]}}], ca
ag = yaml.safe_load(open(sys.argv[2]))["spec"]["source"]["helm"]["valuesObject"]
assert ag["tls"] == {"caConfigMap": "hangar-cluster-ca"}, ag.get("tls")
assert ag["waitJob"]["caConfigMap"] == "hangar-cluster-ca", ag["waitJob"]
PY
fi
new "${TMP}/gate-ca-old" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.53.0 \
  --set clearance.gate.caConfigMap=hangar-cluster-ca
out="$(python3 hack/render.py --cluster "${TMP}/gate-ca-old/cluster.yaml" 2>&1)" && bad "gate CA on an agent chart before 0.54.0 rendered" \
  || { grep -q 'argocdAgentChart 0.54.0 or later' <<<"${out}" && ok "gate CA on an agent chart before 0.54.0 is refused" || bad "gate CA, old agent chart: ${out}"; }
new "${TMP}/gate-ca-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'clearance.gate.caConfigMap=Not_A_Name'
out="$(python3 hack/render.py --cluster "${TMP}/gate-ca-bad/cluster.yaml" 2>&1)" && bad "a caConfigMap that is not a ConfigMap name rendered" \
  || { grep -q 'clearance.gate.caConfigMap is' <<<"${out}" && ok "a caConfigMap that is not a ConfigMap name is refused" || bad "bad caConfigMap: ${out}"; }
# The grant-expiry webhook, agent HA, the status heartbeat and the alerts (I-44; agent chart 0.55.0): unset, none renders (gate-agent
# above); set, the agent's values carry them; check refuses a bad value, a missing prerequisite and the chart's gate.enforce rule.
if grep -qE 'grantExpiry|^ *ha:|statusHeartbeat|alerts:|^ *gate:|previousURL' "${AGA}"; then bad "I-44 unset: a setting rendered in the agent"; else ok "I-44 unset: no grantExpiry, ha, statusHeartbeat, alerts or gate in the agent"; fi
