# tests/cases/09-clearance-gate.sh (see tests/run.sh)
# group: render
# secs: 21
# needs: lab
# Clearance gate (clearance G-ARGO-2, 56-clearance-gate): upper clusters only, off by default; Warn, then Deny + Allow->Deny.
expect "${LAB}/prod" "prod/kind" '!56-clearance-gate/admission.yaml'
G="${TMP}/gate"
mkdir -p "${G}/warn" "${G}/enforce" "${G}/dev" "${G}/ca" "${G}/ca-empty" "${G}/ca-bad"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/warn/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, agentServiceAccount: "clearance-system:the-agent"}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/enforce/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/dev/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, waitCAConfigMap: hangar-cluster-ca}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, waitCAConfigMap: ""}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca-empty/cluster.yaml"
render_ok "${G}/warn" "prod clearance gate warn"
render_ok "${G}/enforce" "prod clearance gate enforce"
render_ok "${G}/dev" "dev clearance gate key"
GP=56-clearance-gate/admission.yaml
expect "${G}/dev" "dev clearance gate key" "!${GP}"
has "${G}/warn/56-clearance-gate/application.yaml" 'path: 56-clearance-gate' "clearance gate: its own Application"
has "${G}/warn/56-clearance-gate/clearancegrant-crd.yaml" 'name: clearancegrants.clearance.hangar.io' "clearance gate: the ClearanceGrant CRD"
CRDF="${G}/warn/56-clearance-gate/clearancegrant-crd.yaml"
[ "$(grep -c '^  annotations:' "${CRDF}")" = 1 ] && ok "clearance gate: the CRD has one annotations key (a duplicate drops the sync wave)" \
  || bad "clearance gate: the CRD has a duplicate metadata.annotations key"
if [ "${HAVE_YAML}" = true ]; then
  if out="$(python3 - "${CRDF}" <<'PY' 2>&1
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))["metadata"]
a = m.get("annotations") or {}
want = {"argocd.argoproj.io/sync-wave": "0", "clearance.hangar.io/schema-revision": "3"}
bad = [k for k, v in want.items() if a.get(k) != v]
bad += [k for k in want if k in (m.get("labels") or {})]
if bad:
    print("wrong or misplaced: " + ", ".join(bad))
    sys.exit(1)
PY
  )"; then
    ok "clearance gate: the CRD's metadata.annotations hold sync-wave 0 and schema-revision 3"
  else
    bad "clearance gate: the CRD's metadata.annotations ${out}"
  fi
fi
has "${G}/warn/${GP}" "== 'registry.invalid/clearance-wait@sha256:1{64}'" "clearance gate: the exemption pins the wait image from versions.clearance.waitImage"
has "${G}/warn/${GP}" 'validationActions: \[Warn, Audit\]' "clearance gate: Warn by default"
has "${G}/warn/${GP}" 'parameterNotFoundAction: Allow' "clearance gate: Warn allows a missing grant"
has "${G}/warn/${GP}" "== 'system:serviceaccount:argocd-apps:argocd-application-controller'" "clearance gate: matches Argo's controller only"
has "${G}/warn/${GP}" "== 'system:serviceaccount:clearance-system:clearance-argocd-agent'" "clearance gate: the agent is the only grant writer"
has "${G}/enforce/${GP}" 'validationActions: \[Deny, Audit\]' "clearance gate: enforce denies"
has "${G}/enforce/${GP}" 'parameterNotFoundAction: Deny' "clearance gate: enforce flips parameterNotFoundAction too"
has "${G}/enforce/${GP}" "clearance-system:the-agent'" "clearance gate: the agent account is configurable"
# clearance.gate.waitCAConfigMap (I-43, A-17): off (unset or empty) the policy is byte for byte the one without the key; on, it
# admits only the plugin's CA volume of that ConfigMap; a name that is not a ConfigMap name is refused before it reaches the CEL.
render_ok "${G}/ca" "prod clearance gate enforce + waitCAConfigMap"
render_ok "${G}/ca-empty" "prod clearance gate enforce + empty waitCAConfigMap"
sed 's/clearance-system:the-agent/clearance-system:clearance-argocd-agent/' "${G}/enforce/${GP}" | cmp -s - "${G}/ca-empty/${GP}" \
  && ok "clearance gate: the waitCAConfigMap-off policy is the enforce policy byte for byte (bar the agent account)" \
  || bad "clearance gate: the waitCAConfigMap-off policy differs from the enforce policy"
nca() { grep -c "$1" "$2" 2>/dev/null || true; }
[ "$(nca 'clearance-ca' "${G}/warn/${GP}")" = 0 ] && [ "$(nca 'clearance-ca' "${G}/enforce/${GP}")" = 0 ] \
  && ok "clearance gate: no CA volume is admitted without waitCAConfigMap" || bad "clearance gate: the CA exemption renders without waitCAConfigMap"
has "${G}/ca/${GP}" "configMap.name == 'hangar-cluster-ca'" "clearance gate: the CA exemption pins the ConfigMap from waitCAConfigMap"
has "${G}/ca/${GP}" "mountPath == '/etc/clearance-ca'" "clearance gate: the CA exemption pins the mount path"
{ cat "${LAB}/prod/cluster.yaml"; echo "clearance: {gate: {enabled: true, waitCAConfigMap: \"x' || true || 'y\"}}"; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca-bad/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/ca-bad/cluster.yaml" 2>&1)" && bad "clearance gate: a waitCAConfigMap that is not a ConfigMap name rendered" \
  || { grep -q 'waitCAConfigMap' <<<"${out}" && ok "clearance gate: a waitCAConfigMap that is not a ConfigMap name is refused" || bad "clearance gate: bad waitCAConfigMap refusal text: ${out}"; }
# clearance.gate.previousURL (A-19): one release only; off, the URL test is the single == as before; on, exactly the two URLs.
WIMG='versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'
mkdir -p "${G}/prev" "${G}/prev-same" "${G}/prev-bad" "${G}/inject-noca"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, url: "https://clearance-core.clearance-system.svc:8443", previousURL: "http://clearance-core.clearance-system.svc:8080"}}'; echo "${WIMG}"; } >"${G}/prev/cluster.yaml"
render_ok "${G}/prev" "prod clearance gate enforce + previousURL"
has "${G}/prev/${GP}" "variables.waitctr.env\[0\].value in \['https://clearance-core.clearance-system.svc:8443', 'http://clearance-core.clearance-system.svc:8080'\] &&" "previousURL: the exemption admits the current and the previous URL"
has "${G}/enforce/${GP}" "variables.waitctr.env\[0\].value == '" "no previousURL: the single-URL test as before"
if grep -q 'env\[0\].value in' "${G}/enforce/${GP}" "${G}/warn/${GP}"; then bad "no previousURL: the URL test renders a list"; else ok "no previousURL: no URL list"; fi
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, url: "http://clearance.hangar-dev.local", previousURL: "http://clearance.hangar-dev.local"}}'; echo "${WIMG}"; } >"${G}/prev-same/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/prev-same/cluster.yaml" 2>&1)" && bad "previousURL equal to gate.url rendered" \
  || { grep -q 'previousURL equals' <<<"${out}" && ok "previousURL equal to gate.url is refused" || bad "previousURL equal: ${out}"; }
{ cat "${LAB}/prod/cluster.yaml"; echo "clearance: {gate: {enabled: true, previousURL: \"http://x' || true || 'y\"}}"; echo "${WIMG}"; } >"${G}/prev-bad/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/prev-bad/cluster.yaml" 2>&1)" && bad "a previousURL that is not a URL rendered" \
  || { grep -q 'clearance.gate.previousURL is' <<<"${out}" && ok "a previousURL that could reach the CEL is refused" || bad "bad previousURL: ${out}"; }
mkdir -p "${G}/prev-v6"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, url: "https://clearance-core.clearance-system.svc:8443", previousURL: "http://[2001:db8::1]:8080"}}'; echo "${WIMG}"; } >"${G}/prev-v6/cluster.yaml"
python3 hack/render.py --cluster "${G}/prev-v6/cluster.yaml" >/dev/null 2>&1 \
  && has "${G}/prev-v6/${GP}" "'http://\[2001:db8::1\]:8080'\] &&" "previousURL: an IPv6 host renders (CodeRabbit on #271)" || bad "previousURL: an IPv6 URL was refused"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, waitCAInject: true}}'; echo "${WIMG}"; } >"${G}/inject-noca/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/inject-noca/cluster.yaml" 2>&1)" && bad "waitCAInject without waitCAConfigMap rendered" \
  || { grep -q 'waitCAInject needs clearance.gate.waitCAConfigMap' <<<"${out}" && ok "waitCAInject without waitCAConfigMap is refused" || bad "waitCAInject without the policy key: ${out}"; }
