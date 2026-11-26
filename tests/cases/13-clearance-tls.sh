# tests/cases/13-clearance-tls.sh (see tests/run.sh)
# group: render
# secs: 11
echo "== 1-tls. the Clearance core's and API's https (clearance.tls, A-19)"
# Off: no tls block, the routes on 8080, no BackendTLSPolicy, Traefik's status rule as before. On: the chart's tls.* with the cluster
# CA's ClusterIssuer and 90/30 days; gatewayBackendTLS moves exactly the core's and the API's routes to 8443 behind a v1 policy.
CLR="55-clearance/clearance/application.yaml"
TLSDIR="${TMP}/ctls"
TLS_BASE=(--repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set components.clearance=true)
new "${TLSDIR}/off" dev hangar-dev kiac "${TLS_BASE[@]}"
render_ok "${TLSDIR}/off" "dev clearance, tls off"
if grep -q '^        tls:' "${TLSDIR}/off/${CLR}"; then bad "tls off: the Clearance Application has a tls block"; else ok "tls off: no tls block"; fi
[ "$(grep -c 'port: 8080' "${TLSDIR}/off/55-clearance/clearance-config/routes.yaml")" -ge 2 ] && ok "tls off: the routes send to 8080" || bad "tls off: the routes do not send to 8080"
expect "${TLSDIR}/off" "tls off" '!55-clearance/clearance-config/backend-tls.yaml'
if grep -q 'backendtlspolicies/status' "${TLSDIR}/off/10-crds-operators/traefik/gateway.yaml"; then bad "tls off: Traefik's status rule changed"; else ok "tls off: Traefik's status rule as before"; fi
new "${TLSDIR}/on" dev hangar-dev kiac "${TLS_BASE[@]}" --set components.trustManager=true --set components.clusterCA=true \
  --set clearance.tls.enabled=true --set clearance.tls.gatewayBackendTLS=true
render_ok "${TLSDIR}/on" "dev clearance tls + gatewayBackendTLS"
has "${TLSDIR}/on/${CLR}" '^          plainHttp: true$' "tls on: plain http stays by default"
has "${TLSDIR}/on/${CLR}" 'issuerRef: \{"name": "hangar-cluster-ca", "kind": "ClusterIssuer"\}' "tls on: the cluster CA's ClusterIssuer signs the leaves"
has "${TLSDIR}/on/${CLR}" '^            duration: 2160h$' "tls on: 90-day leaves"
has "${TLSDIR}/on/${CLR}" '^            renewBefore: 720h$' "tls on: renewed 30 days early"
[ "$(grep -c 'port: 8080' "${TLSDIR}/on/55-clearance/clearance-config/routes.yaml")" = 0 ] && [ "$(grep -c 'port: 8443' "${TLSDIR}/on/55-clearance/clearance-config/routes.yaml")" -ge 2 ] \
  && ok "gatewayBackendTLS: every core and API route sends to 8443" || bad "gatewayBackendTLS: a route still sends to 8080"
has "${TLSDIR}/on/10-crds-operators/traefik/gateway.yaml" 'tlsroutes/status, backendtlspolicies/status\]' "gatewayBackendTLS: Traefik may report the policies' status"
BTP="${TLSDIR}/on/55-clearance/clearance-config/backend-tls.yaml"
if [ "${HAVE_YAML}" = true ]; then
  if out="$(python3 - "${BTP}" <<'PY' 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
bad = []
if sorted(d["metadata"]["name"] for d in docs) != ["clearance-api", "clearance-core"]:
    bad.append("want two policies, clearance-core and clearance-api")
for d in docs:
    n = d["metadata"]["name"]
    if d["apiVersion"] != "gateway.networking.k8s.io/v1" or d["kind"] != "BackendTLSPolicy":
        bad.append(f"{n}: {d['apiVersion']} {d['kind']}")
    if d["spec"]["targetRefs"] != [{"group": "", "kind": "Service", "name": n, "sectionName": "https"}]:
        bad.append(f"{n}: targetRefs {d['spec']['targetRefs']}")
    want = {"caCertificateRefs": [{"group": "", "kind": "ConfigMap", "name": "hangar-cluster-ca"}], "hostname": f"{n}.clearance-system.svc"}
    if d["spec"]["validation"] != want:
        bad.append(f"{n}: validation {d['spec']['validation']}")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
  )"; then
    ok "gatewayBackendTLS: a v1 BackendTLSPolicy per Service, section https, verified against hangar-cluster-ca for <service>.<ns>.svc"
  else
    bad "gatewayBackendTLS: ${out}"
  fi
fi
new "${TLSDIR}/own" dev hangar-dev kiac "${TLS_BASE[@]}" --set clearance.tls.enabled=true
render_ok "${TLSDIR}/own" "dev clearance tls without the cluster CA"
has "${TLSDIR}/own/${CLR}" 'issuerRef: \{"name": "", "kind": "Issuer"\}' "tls without components.clusterCA: the chart's own CA"
[ "$(grep -c 'port: 8443' "${TLSDIR}/own/55-clearance/clearance-config/routes.yaml")" = 0 ] && ok "tls without gatewayBackendTLS: the routes stay on 8080" || bad "tls without gatewayBackendTLS moved a route"
tls_refused() { # tls_refused LABEL WANT --set ...
  local label="$1" want="$2"; shift 2
  new "${TLSDIR}/bad" dev hangar-dev kiac "${TLS_BASE[@]}" "$@"
  local out
  out="$(python3 hack/render.py --cluster "${TLSDIR}/bad/cluster.yaml" 2>&1)" && { bad "${label}: rendered"; return; }
  grep -qF "${want}" <<<"${out}" && ok "${label}: refused" || bad "${label}: refusal text: ${out}"
}
tls_refused "gatewayBackendTLS without tls" "clearance.tls.gatewayBackendTLS needs clearance.tls.enabled" --set components.trustManager=true --set components.clusterCA=true --set clearance.tls.gatewayBackendTLS=true
tls_refused "gatewayBackendTLS without the cluster CA" "needs components.clusterCA" --set clearance.tls.enabled=true --set clearance.tls.gatewayBackendTLS=true
tls_refused "tls on an older chart" "versions.clearance.chart 0.54.0 or later" --set clearance.tls.enabled=true --set versions.clearance.chart=0.53.0
tls_refused "tls without cert-manager" "clearance.tls.enabled needs components.certManager" --set clearance.tls.enabled=true --set components.certManager=false
tls_refused "tls.enabled not a bool" "clearance.tls.enabled is true or false" --set clearance.tls.enabled=yes-please
tls_refused "plainHttp false with plain-http routes" "the Gateway's routes (set clearance.tls.gatewayBackendTLS)" --set clearance.tls.enabled=true --set clearance.tls.plainHttp=false
tls_refused "plainHttp false with Autopilot" "the Autopilot gateway and read API" --set components.trustManager=true --set components.clusterCA=true \
  --set clearance.tls.enabled=true --set clearance.tls.gatewayBackendTLS=true --set clearance.tls.plainHttp=false
tls_refused "plainHttp false without tls" "clearance.tls.plainHttp false needs clearance.tls.enabled" --set clearance.tls.plainHttp=false
tls_refused "plainHttp false with Glidepath" "Glidepath's agent gates and deployment gate" --set components.trustManager=true --set components.clusterCA=true \
  --set clearance.tls.enabled=true --set clearance.tls.gatewayBackendTLS=true --set clearance.tls.plainHttp=false
# The callers of clearance.gate.url are refused only while that URL is plain http (CodeRabbit on #270).
new "${TLSDIR}/gurl" dev hangar-dev kiac "${TLS_BASE[@]}" --set components.trustManager=true --set components.clusterCA=true \
  --set clearance.tls.enabled=true --set clearance.tls.gatewayBackendTLS=true --set clearance.tls.plainHttp=false --set clearance.targets.enabled=true
out="$(python3 hack/check.py --cluster "${TLSDIR}/gurl/cluster.yaml" 2>&1)"
grep -qF "the target registry publisher (clearance.gate.url is plain http)" <<<"${out}" && ok "plainHttp false: the publisher on a plain-http gate.url is named" || bad "plainHttp false, publisher on http: ${out}"
python3 - "${TLSDIR}/gurl/cluster.yaml" <<'PYG'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
d["clearance"].setdefault("gate", {})["url"] = "https://clearance-core.clearance-system.svc:8443"
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PYG
out="$(python3 hack/check.py --cluster "${TLSDIR}/gurl/cluster.yaml" 2>&1)"
if grep -qF "target registry publisher (clearance.gate.url is plain http)" <<<"${out}"; then bad "plainHttp false: the publisher is named as a plain-http caller although gate.url is https"; else ok "plainHttp false: the publisher on an https gate.url is not a plain-http caller"; fi
# ...but an https gate.url to the in-cluster core is refused while the publisher (or the audit collector) cannot trust its private CA.
grep -qF "the target registry publisher (clearance.targets.enabled) has no CA setting" <<<"${out}" \
  && ok "https gate.url to the in-cluster core: refused while the publisher has no CA setting (CodeRabbit on #270)" || bad "https gate.url, publisher without a CA: ${out}"
