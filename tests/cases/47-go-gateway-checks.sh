# tests/cases/47-go-gateway-checks.sh (see tests/run.sh)
# group: render
# secs: 5
# needs: eks go-gateway
G="${K}/go/55-autopilot/gateway"
GD="${K}/dev"
refuse "go without a tag" "${GD}" 'autopilot: {gateway: {implementation: go}}'
refuse "an unknown implementation" "${GD}" 'autopilot: {gateway: {implementation: rust}}'
GODIG='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
GOREST='brokerUrl: https://b.example.dev, githubOwners: [acme], airframeUpperClusters: [eks-prod], agentXRs: {namespaces: [app-a-cicd]}'
GOEGR='egress: {apiServerCIDRs: [203.0.113.10/32]}'
GOHTTP='plainHttp: {glidepath: true, logs: true, clearanceApi: true}'
gocfg() { printf 'autopilot: {gateway: {implementation: go, go: {%s}}}' "$*"; }
refuse "go without a plain-http switch for glidepath-api's in-cluster URL" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, ${GOEGR}")"
refuse "go with a mutable digest" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: latest, ${GOREST}, ${GOEGR}, ${GOHTTP}")"
refuse "go with a tag that is not a Go release" "${GD}" "$(gocfg "tag: gateway-v0.9.1, digest: ${GODIG}, ${GOREST}, ${GOEGR}, ${GOHTTP}")"
refuse "go without the API server's addresses" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, ${GOHTTP}")"
refuse "go without the namespaces the loader reads" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, brokerUrl: https://b.example.dev, githubOwners: [acme], airframeUpperClusters: [eks-prod], ${GOEGR}, ${GOHTTP}")"
refuse "an airframeOwner outside githubOwners" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, airframeOwner: other, ${GOEGR}, ${GOHTTP}")"
refuse "a plain-http switch that does not exist" "${GD}" "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, ${GOEGR}, plainHttp: {glidepath: true, logs: true, clearanceApi: true, everything: true}")"
mkdir -p "${K}/gonoca" && cp "${GD}/cluster.yaml" "${K}/gonoca/cluster.yaml" && printf '%s\n' "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, ${GOEGR}, plainHttp: {glidepath: true, logs: true}")" >>"${K}/gonoca/cluster.yaml"
if python3 hack/check.py --cluster "${K}/gonoca/cluster.yaml" >/dev/null 2>"${TMP}/gonoca"; then bad "check accepted go without plainHttp.clearanceApi"
elif grep -q 'plainHttp.clearanceApi must be true' "${TMP}/gonoca"; then ok "check names go.plainHttp.clearanceApi when clearance-api's URL is plain http and the switch is off"
else bad "go without clearanceApi refused for another reason: $(head -1 "${TMP}/gonoca")"; fi
# CLEARANCE_API_URL and its allow-http switch are on serve; the read API names the URL and never gets the switch; egress reaches clearance-api (namespace rule, 8080)
has "${G}/gateway-go.yaml" 'name: CLEARANCE_API_URL, value: "http://clearance-api\.[^"]*\.svc:8080"' "go: serve has CLEARANCE_API_URL"
has "${G}/gateway-go.yaml" 'name: CLEARANCE_API_ALLOW_HTTP, value: "1"' "go: plainHttp.clearanceApi renders CLEARANCE_API_ALLOW_HTTP on serve"
if grep -q 'CLEARANCE_API_ALLOW_HTTP' "${G}/autopilot-api-go.yaml"; then bad "go: the read API got CLEARANCE_API_ALLOW_HTTP"; else ok "go: the read API does not get CLEARANCE_API_ALLOW_HTTP"; fi
CNS="$(grep -o 'name: CLEARANCE_API_URL, value: "http://clearance-api\.[^.]*' "${G}/gateway-go.yaml" | sed 's/.*clearance-api\.//')"
if python3 - "${G}/gateway-go-egress.yaml" "${CNS}" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
pol = {d["metadata"]["name"]: d for d in docs}
def reaches(d):
    for r in d["spec"]["egress"]:
        for t in r.get("to", []):
            ns = t.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
            if ns == sys.argv[2] and any(p["port"] == 8080 for p in r["ports"]):
                return True
    return False
sys.exit(0 if reaches(pol["autopilot-gateway-egress"]) and not reaches(pol["autopilot-api-egress"]) else 1)
PY
then ok "go: egress lets serve reach clearance-api on 8080 and the read API has no such rule"; else bad "go: egress for clearance-api wrong (namespace ${CNS})"; fi
# a plain-http catalog opens port 80 to Tower's catalog and nothing else new
mkdir -p "${K}/gocat" && sed 's/plainHttp: {glidepath: true, logs: true, jwks: true, clearanceApi: true}/plainHttp: {glidepath: true, logs: true, jwks: true, clearanceApi: true, catalog: true}/' "${K}/go/cluster.yaml" >"${K}/gocat/cluster.yaml"
render_ok "${K}/gocat" "go with a plain-http catalog"
n80="$(grep -c 'port: 80}' "${K}/gocat/55-autopilot/gateway/gateway-go-egress.yaml")"; n80b="$(grep -c 'port: 80}' "${K}/go/55-autopilot/gateway/gateway-go-egress.yaml")"
[ "${n80}" = 3 ] && ok "go: plainHttp.catalog opens port 80 (gateway, read API; Loki's :80 is the third)" || bad "go: plainHttp.catalog port 80 rules: ${n80}"
[ "${n80b}" = 1 ] && ok "go: without plainHttp.catalog port 80 is only Loki's" || bad "go: port 80 rules without plainHttp.catalog: ${n80b}"
# the same values, complete, pass: the refusals above are each about the one thing left out
mkdir -p "${K}/gook" && cp "${GD}/cluster.yaml" "${K}/gook/cluster.yaml" && printf '%s\n' "$(gocfg "tag: gateway-go-v0.1.0, digest: ${GODIG}, ${GOREST}, ${GOEGR}, ${GOHTTP}")" >>"${K}/gook/cluster.yaml"
python3 hack/check.py --cluster "${K}/gook/cluster.yaml" >/dev/null 2>"${TMP}/gook" && ok "go: the complete values pass check" || bad "go: complete values refused: $(cat "${TMP}/gook")"
