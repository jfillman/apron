# tests/cases/45-go-gateway.sh (see tests/run.sh)
# group: render
# secs: 28
# needs: eks
echo "== 3b. the Go gateway (autopilot.gateway.implementation): off by default, the same Services when on"
GO_SETTINGS='  gateway:
    implementation: go
    go:
      tag: gateway-go-v0.1.0
      digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      brokerUrl: https://broker.example.dev
      githubOwners: [acme]
      airframeUpperClusters: [eks-prod]
      agentXRs: {namespaces: [app-gate-api-cicd], names: {gate-reader: app-gate-api-cicd}}
      egress: {apiServerCIDRs: [203.0.113.10/32]}
      plainHttp: {glidepath: true, logs: true, jwks: true, clearanceApi: true}'
# unset and `python` render the same bytes (the default is the Python gateway and read API, as before)
mkdir -p "${K}/gopy" "${K}/go" "${K}/pyx"
cp "${K}/dev/cluster.yaml" "${K}/pyx/cluster.yaml"
printf 'autopilot:\n  people: [alice, bob]\n  customImages: ["ghcr.io/acme/*@sha256:*"]\n' >>"${K}/pyx/cluster.yaml"
cp "${K}/pyx/cluster.yaml" "${K}/gopy/cluster.yaml"
printf '  gateway: {implementation: python}\n' >>"${K}/gopy/cluster.yaml"
cp "${K}/pyx/cluster.yaml" "${K}/go/cluster.yaml"
printf '%s\n' "${GO_SETTINGS}" >>"${K}/go/cluster.yaml"
render_ok "${K}/pyx" "eks-dev (people), Go switch unset"
render_ok "${K}/gopy" "eks-dev (people), implementation: python"
render_ok "${K}/go" "eks-dev (people), implementation: go"
if diff -r -x cluster.yaml "${K}/pyx" "${K}/gopy" >/dev/null; then ok "implementation: python renders byte-identically to the switch unset"; else bad "implementation: python differs from unset"; fi
expect "${K}/pyx" "switch unset" 55-autopilot/gateway/gateway.yaml 55-autopilot/gateway/autopilot-api.yaml '!55-autopilot/gateway/gateway-go.yaml' \
  '!55-autopilot/gateway/autopilot-api-go.yaml' '!55-autopilot/gateway/gateway-go-extras.yaml' '!55-autopilot/gateway/gateway-go-egress.yaml' '!55-autopilot/gateway/gateway-go-migrate.yaml'
if grep -rq 'autopilot-gateway-go\|gateway-go-v' "${K}/pyx" --exclude=cluster.yaml; then bad "Go image named with the switch unset"; else ok "the Go image is named nowhere with the switch unset"; fi
G="${K}/go/55-autopilot/gateway"
expect "${K}/go" "implementation: go" 55-autopilot/gateway/gateway-go.yaml 55-autopilot/gateway/autopilot-api-go.yaml 55-autopilot/gateway/gateway-go-extras.yaml \
  55-autopilot/gateway/gateway-go-egress.yaml '!55-autopilot/gateway/gateway.yaml' '!55-autopilot/gateway/autopilot-api.yaml' '!55-autopilot/gateway/gateway-go-migrate.yaml'
for f in gateway-go.yaml autopilot-api-go.yaml; do
  has "${G}/${f}" 'image: [^ ]*/autopilot-gateway-go:gateway-go-v0\.1\.0@sha256:a{64}$' "go: ${f} pins the Go image by tag and digest"
done
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${G}/gateway-go-egress.yaml" <<'PY6' && ok "go: both egress policies are wave 2 (with the Go Deployments, after migrate) and the read API's allow DNS, the database, the API server and the OTLP collector" || bad "go: egress policies not in wave 2 or missing a destination the read API needs"
import sys, yaml
docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
for n in ("autopilot-gateway-egress", "autopilot-api-egress"):
    assert docs[n]["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "2", n
ports = lambda d: {(p["protocol"], p["port"]) for r in d["spec"]["egress"] for p in r.get("ports", [])}
api = ports(docs["autopilot-api-egress"])
assert {("UDP", 53), ("TCP", 5432), ("TCP", 443), ("TCP", 4318)} <= api, api
gw = ports(docs["autopilot-gateway-egress"])
assert {("TCP", 5432), ("TCP", 8080), ("TCP", 4318), ("TCP", 443)} <= gw, gw
PY6
fi
has "${G}/gateway-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "go: the gateway is in wave 2, after the migrate Job (wave 1)"
has "${G}/autopilot-api-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "go: the read API is in wave 2, after the migrate Job (wave 1)"
has "${G}/gateway-go.yaml" 'args: \[serve\]' "go: the gateway runs serve"
has "${G}/autopilot-api-go.yaml" 'args: \[api\]' "go: the read API runs api"
has "${G}/gateway-go.yaml" 'path: /healthz, port: mcp' "go: gateway probes /healthz"
has "${G}/autopilot-api-go.yaml" 'path: /readyz, port: http' "go: read API readiness is /readyz"
has "${G}/autopilot-api-go.yaml" 'name: "autopilot-pg-reader", key: uri' "go: the read API's DSN is the read-only role's secret (by reference)"
has "${G}/gateway-go.yaml" 'secretKeyRef: \{name: autopilot-pg-app, key: uri\}' "go: serve uses the same database as the Python gateway"
for f in gateway-go.yaml autopilot-api-go.yaml; do
  has "${G}/${f}" 'readOnlyRootFilesystem: true' "go: ${f} read-only root filesystem"
  has "${G}/${f}" 'capabilities: \{drop: \["ALL"\]\}' "go: ${f} drops every capability"
  has "${G}/${f}" 'runAsNonRoot: true' "go: ${f} runs as non-root"
  has "${G}/${f}" 'seccompProfile: \{type: RuntimeDefault\}' "go: ${f} seccomp RuntimeDefault"
done
has "${G}/gateway-go.yaml" 'name: AGENT_XRS_NAMESPACES, value: "app-gate-api-cicd"' "go: AGENT_XRS_NAMESPACES from autopilot.gateway.go.agentXRs"
has "${G}/gateway-go.yaml" 'name: AGENT_XRS_NAMES, value: "gate-reader=app-gate-api-cicd"' "go: AGENT_XRS_NAMES from autopilot.gateway.go.agentXRs.names"
has "${G}/gateway-go.yaml" 'name: AIRFRAME_UPPER_CLUSTERS, value: "eks-prod"' "go: AIRFRAME_UPPER_CLUSTERS"
has "${G}/gateway-go.yaml" 'name: GITHUB_OWNERS, value: "acme"' "go: GITHUB_OWNERS"
has "${G}/gateway-go.yaml" 'name: AIRFRAME_TENANTS_REPO' "go: AIRFRAME_TENANTS_REPO"
has "${G}/autopilot-api-go.yaml" 'name: GATEWAY_API_AUDITORS, value: "user:alice,user:bob"' "go: GATEWAY_API_AUDITORS are the people as principals"
has "${G}/autopilot-api-go.yaml" 'name: GATEWAY_API_NOTIFIERS, value: "eks-man/' "go: GATEWAY_API_NOTIFIERS name Tower's backend"
has "${G}/gateway-go.yaml" 'name: BACKSTAGE_TOKEN_FILE, value: /var/run/clearance/backstage-token' "go: the catalog token file"
has "${G}/gateway-go-extras.yaml" 'resources: \["namespaces"\]' "go: the namespace read the Go gateway needs"
has "${G}/gateway-go-egress.yaml" 'cidr: 203\.0\.113\.10/32|203\.0\.113\.10/32' "go: egress admits the API server at the address cluster.yaml says"
has "${G}/gateway-go-egress.yaml" 'port: 4318' "go: egress admits the OTLP collector"
has "${G}/gateway-go-egress.yaml" 'cnpg\.io/cluster: autopilot-pg' "go: egress admits the database"
has "${G}/gateway-go-egress.yaml" 'app.kubernetes.io/name: people-dex' "go: port 5556 is admitted to the people-dex pods only"
# autopilot.peopleTls (I-28): people-dex serves its keys over https from a cert-manager certificate; the Go gateway and read API fetch them
# over https and trust the in-cluster CA (AUTOPILOT_JWKS_CA_FILE); off, none of it renders (the go/ render above is the byte-for-byte baseline)
for f in gateway-go.yaml autopilot-api-go.yaml; do
  if grep -q 'JWKS_CA_FILE\|people-dex-ca\|5557' "${G}/${f}"; then bad "tls off: ${f} renders something of people-dex TLS"; else ok "tls off: ${f} renders nothing of people-dex TLS"; fi
done
if grep -rq 'https: 0.0.0.0:5557\|people-dex-tls' "${K}/go/55-identity" "${K}/go/55-autopilot/gateway/gateway-go-egress.yaml"; then bad "tls off: people-dex TLS rendered"; else ok "tls off: people-dex renders without TLS"; fi
mkdir -p "${K}/gotls"
sed 's/^  gateway:/  peopleTls: true\n  gateway:/' "${K}/go/cluster.yaml" >"${K}/gotls/cluster.yaml"
render_ok "${K}/gotls" "eks-dev (people), go, autopilot.peopleTls"
python3 hack/check.py --cluster "${K}/gotls/cluster.yaml" >/dev/null && ok "tls on: check passes" || bad "tls on: check fails"
T="${K}/gotls/55-autopilot/gateway"
expect "${K}/gotls" "peopleTls" 55-identity/people-dex/tls.yaml
for f in gateway-go.yaml autopilot-api-go.yaml; do
  has "${T}/${f}" 'name: AUTOPILOT_OIDC_JWKS_URL, value: "https://people-dex\.autopilot-system\.svc:5557/dex/keys"' "tls on: ${f} fetches the keys over https"
  has "${T}/${f}" 'name: AUTOPILOT_JWKS_CA_FILE, value: /etc/people-dex-ca/ca\.crt' "tls on: ${f} trusts the in-cluster CA file"
  has "${T}/${f}" 'secretName: people-dex-tls' "tls on: ${f} mounts the cert-manager Secret"
  has "${T}/${f}" 'items: \[\{key: ca\.crt, path: ca\.crt\}\]' "tls on: ${f} mounts only the CA certificate, never the key"
  if grep -q 'http://people-dex' "${T}/${f}"; then bad "tls on: ${f} still names the http keys URL"; else ok "tls on: ${f} names no http keys URL"; fi
done
has "${T}/gateway-go-egress.yaml" 'port: 5557' "tls on: egress admits people-dex's https port"
has "${K}/gotls/55-identity/people-dex/dex.yaml" 'https: 0\.0\.0\.0:5557' "tls on: dex serves https on 5557"
has "${K}/gotls/55-identity/people-dex/dex.yaml" 'http: 0\.0\.0\.0:5556' "tls on: dex keeps the http listener (Clearance and glidepath-api still use it)"
has "${K}/gotls/55-identity/people-dex/dex.yaml" 'tlsKey: /etc/dex/tls/tls\.key' "tls on: dex reads its key from the cert-manager Secret mount"
has "${K}/gotls/55-identity/people-dex/dex.yaml" 'issuer: http' "tls on: the issuer is still the public URL"
if grep -q 'issuer: https\?://[^d]' "${K}/gotls/55-identity/people-dex/dex.yaml"; then bad "tls on: dex issuer changed"; else ok "tls on: the issuer is unchanged (dex.<domain>/dex)"; fi
has "${K}/gotls/55-identity/people-dex/dex.yaml" 'port: 5557, targetPort: https' "tls on: the Service exposes 5557"
has "${K}/gotls/55-identity/people-dex/tls.yaml" 'issuerRef: \{name: people-dex-ca, kind: Issuer' "tls on: the serving certificate is signed by the in-cluster CA Issuer"
has "${K}/gotls/55-identity/people-dex/tls.yaml" 'people-dex\.autopilot-system\.svc$' "tls on: the certificate names the Service host the gateway dials"
if grep -q 'kind: Secret' "${K}/gotls/55-identity/people-dex/tls.yaml"; then bad "tls on: a Secret is hand-made"; else ok "tls on: no Secret is written, cert-manager fills it"; fi
# autopilot.peopleTlsClusterCA (A-19, plan step P6): the cluster CA signs people-dex's certificate (90 days, renewed 30 early) and the
# gateway and read API trust the Bundle's ConfigMap; off (the gotls render above), the namespace's own CA as before.
has "${K}/gotls/55-identity/people-dex/tls.yaml" '^  duration: 8760h$' "peopleTls without the cluster CA: the 1-year leaf as before"
if grep -q 'hangar-cluster-ca' "${K}/gotls/55-identity/people-dex/tls.yaml" "${T}/gateway-go.yaml" "${T}/autopilot-api-go.yaml"; then
  bad "peopleTlsClusterCA off: the cluster CA rendered"; else ok "peopleTlsClusterCA off: nothing of the cluster CA"; fi
mkdir -p "${K}/gotlsca"
python3 - "${K}/gotls/cluster.yaml" "${K}/gotlsca/cluster.yaml" <<'PYCA'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["autopilot"]["peopleTlsClusterCA"] = True
d.setdefault("components", {}).update({"trustManager": True, "clusterCA": True})
yaml.safe_dump(d, open(sys.argv[2], "w"), sort_keys=False)
PYCA
render_ok "${K}/gotlsca" "eks-dev (people), go, peopleTls on the cluster CA"
TC="${K}/gotlsca/55-identity/people-dex/tls.yaml"
has "${TC}" 'issuerRef: \{name: hangar-cluster-ca, kind: ClusterIssuer, group: cert-manager.io\}' "peopleTlsClusterCA: the cluster CA's ClusterIssuer signs people-dex"
has "${TC}" '^  duration: 2160h$' "peopleTlsClusterCA: 90-day leaf (owner decision 3)"
has "${TC}" '^  renewBefore: 720h$' "peopleTlsClusterCA: renewed 30 days early"
if grep -q 'people-dex-selfsigned\|name: people-dex-ca' "${TC}"; then bad "peopleTlsClusterCA: the namespace's own CA still renders"; else ok "peopleTlsClusterCA: no namespace CA, Issuer or bootstrap Issuer"; fi
[ "$(grep -c '^kind: Certificate$' "${TC}")" = 1 ] && ok "peopleTlsClusterCA: one Certificate, the serving one" || bad "peopleTlsClusterCA: want exactly one Certificate"
for f in gateway-go.yaml autopilot-api-go.yaml; do
  FC="${K}/gotlsca/55-autopilot/gateway/${f}"
  if [ "${HAVE_YAML}" = true ]; then
    python3 - "${FC}" <<'PYCA2' && ok "peopleTlsClusterCA: ${f} mounts ca.crt of ConfigMap hangar-cluster-ca, not the Secret" || bad "peopleTlsClusterCA: ${f} volume is wrong"
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Deployment":
        v = [x for x in d["spec"]["template"]["spec"]["volumes"] if x["name"] == "people-dex-ca"]
        assert v == [{"name": "people-dex-ca", "configMap": {"name": "hangar-cluster-ca", "items": [{"key": "ca.crt", "path": "ca.crt"}]}}], v
        break
else:
    raise SystemExit("no Deployment")
PYCA2
  fi
  has "${FC}" 'name: AUTOPILOT_JWKS_CA_FILE, value: /etc/people-dex-ca/ca\.crt' "peopleTlsClusterCA: ${f} still reads the CA at the same path"
done
for c in "autopilot.peopleTls=false:autopilot.peopleTlsClusterCA needs autopilot.peopleTls" "components.clusterCA=false:autopilot.peopleTlsClusterCA needs components.clusterCA"; do
  python3 - "${K}/gotlsca/cluster.yaml" "${K}/gotlsca-bad.yaml" "${c%%:*}" <<'PYCA3'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
k, _, val = sys.argv[3].partition("=")
a, b = k.split(".")
d[a][b] = yaml.safe_load(val)
yaml.safe_dump(d, open(sys.argv[2], "w"), sort_keys=False)
PYCA3
  out="$(python3 hack/check.py --cluster "${K}/gotlsca-bad.yaml" 2>&1)" && bad "peopleTlsClusterCA with ${c%%:*}: check passed" \
    || { grep -qF "${c#*:}" <<<"${out}" && ok "peopleTlsClusterCA with ${c%%:*}: refused" || bad "peopleTlsClusterCA with ${c%%:*}: ${out}"; }
done
# with TLS the jwks plain-http switch is not needed (and stays harmless on): check passes without it
mkdir -p "${K}/gotls-nojwks"
sed 's/jwks: true, //' "${K}/gotls/cluster.yaml" >"${K}/gotls-nojwks/cluster.yaml"
python3 hack/check.py --cluster "${K}/gotls-nojwks/cluster.yaml" >/dev/null && ok "tls on: check passes without plainHttp.jwks" || bad "tls on: check wants plainHttp.jwks"
sed 's/jwks: true, //' "${K}/go/cluster.yaml" >"${K}/gonojwks.yaml"
if python3 hack/check.py --cluster "${K}/gonojwks.yaml" >/dev/null 2>&1; then bad "tls off: check accepted a missing plainHttp.jwks"; else ok "tls off: check still requires plainHttp.jwks"; fi
if grep -q 'podSelector: {}' "${G}/gateway-go-egress.yaml"; then bad "go: an egress rule admits every pod of the namespace"; else ok "go: no egress rule admits every pod of the namespace"; fi
# the read API's public-HTTPS rule exists only with a Tower (its one public destination); the gateway keeps its own (GitHub, registry, model provider)
n="$(grep -c 'cidr: 0.0.0.0/0' "${G}/gateway-go-egress.yaml")"
[ "${n}" = 2 ] && ok "go: both policies have the public-HTTPS rule when there is a Tower" || bad "go: ${n} public-HTTPS rules, want 2 with a Tower"
has "${G}/gateway-go-egress.yaml" 'narrowest rule plain NetworkPolicy can say' "go: the public-HTTPS rule says why it cannot be narrower"
has "${G}/gateway-go.yaml" 'name: GLIDEPATH_API_ALLOW_HTTP' "go: a plain-http switch renders only when turned on (glidepath)"
if grep -q 'BROKER_ALLOW_HTTP\|BACKSTAGE_ALLOW_HTTP' "${G}/gateway-go.yaml" "${G}/autopilot-api-go.yaml"; then bad "go: a plain-http switch rendered that was not turned on"; else ok "go: plain-http switches that were not turned on are not rendered"; fi
# the Service names and ports are the Python gateway's: callers do not change
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${K}/pyx/55-autopilot/gateway" "${G}" <<'PY3' && ok "go: the same Services, ports, labels and ServiceAccounts as the Python gateway; every Python env name is still set" || bad "go: the Go render differs from the Python render in names, ports or env"
import glob, sys, yaml
def load(d, names):
    out = {}
    for n in names:
        for doc in yaml.safe_load_all(open(f"{d}/{n}")):
            if doc:
                out[(doc["kind"], doc["metadata"]["name"])] = doc
    return out
py = load(sys.argv[1], ["gateway.yaml", "autopilot-api.yaml"])
go = load(sys.argv[2], ["gateway-go.yaml", "autopilot-api-go.yaml"])
assert set(py) == set(go), (sorted(set(py) ^ set(go)))
for k in py:
    if k[0] == "Service":
        assert py[k]["spec"] == go[k]["spec"], (k, py[k]["spec"], go[k]["spec"])
        assert py[k]["metadata"]["labels"] == go[k]["metadata"]["labels"], k
    if k[0] == "Deployment":
        a, b = py[k]["spec"], go[k]["spec"]
        assert a["selector"] == b["selector"] and a["replicas"] == b["replicas"], k
        assert a["template"]["metadata"]["labels"] == b["template"]["metadata"]["labels"], k
        assert a["template"]["spec"]["serviceAccountName"] == b["template"]["spec"]["serviceAccountName"], k
        pe = [e["name"] for e in a["template"]["spec"]["containers"][0]["env"]]
        ge = [e["name"] for e in b["template"]["spec"]["containers"][0]["env"]]
        assert not set(pe) - set(ge), (k, "Python env not set by Go", sorted(set(pe) - set(ge)))
        pp = {p["containerPort"] for p in a["template"]["spec"]["containers"][0]["ports"]}
        gp = {p["containerPort"] for p in b["template"]["spec"]["containers"][0]["ports"]}
        assert pp <= gp, (k, pp, gp)
PY3
fi
# Every file the Go gateway is told to read must exist in the pod: each *_FILE env value, and the Clearance core token (the Go default,
# /var/run/secrets/tokens/clearance, is not the name the manifest projects, clearance-core: serve must set CLEARANCE_CORE_TOKEN_FILE), sits
# under a volumeMount and, where the volume is projected, is the path of one of its service account tokens. Secret volumes: the mount only.
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${G}" <<'PY7' && ok "go: every *_FILE env and the core token path point at a mounted volume (projected token paths exist)" || bad "go: a *_FILE env or the core token path does not point at a file the pod mounts"
import sys, yaml
for f in ("gateway-go.yaml", "autopilot-api-go.yaml"):
    for d in yaml.safe_load_all(open(f"{sys.argv[1]}/{f}")):
        if not d or d["kind"] != "Deployment":
            continue
        pod = d["spec"]["template"]["spec"]
        c = pod["containers"][0]
        vols = {v["name"]: v for v in pod.get("volumes", [])}
        env = {e["name"]: e.get("value") for e in c["env"] if e.get("value") is not None}
        if d["metadata"]["name"] == "autopilot-gateway":
            assert "CLEARANCE_CORE_TOKEN_FILE" in env, (f, "serve reads the core token from the Go default path; set CLEARANCE_CORE_TOKEN_FILE to the projected path")
        n = 0
        for k, v in env.items():
            if not (k.endswith("_FILE") or k == "CLEARANCE_CORE_TOKEN_FILE"):
                continue
            n += 1
            ms = [m for m in c["volumeMounts"] if v.startswith(m["mountPath"].rstrip("/") + "/")]
            assert ms, (f, k, v, "no volumeMount holds this path")
            m = max(ms, key=lambda m: len(m["mountPath"]))
            rest = v[len(m["mountPath"].rstrip("/")) + 1:]
            vol = vols[m["name"]]
            if "projected" in vol:
                paths = [s["serviceAccountToken"]["path"] for s in vol["projected"]["sources"] if "serviceAccountToken" in s]
                assert rest in paths, (f, k, v, "projected paths are", paths)
        assert n, (f, "no *_FILE env at all")
PY7
fi
# What the Python Deployments set is a list in autopilot's gateway/envtable.json (`deployed`); this holds that list to the rendered Python
# Deployments, from a copy vendored at the pinned autopilot commit (tests/fixtures/autopilot-envtable.COMMIT), so clearing or adding an entry on either side fails.
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${K}/pyx/55-autopilot/gateway" "${APRON}/tests/fixtures/autopilot-envtable.json" <<'PY4' && ok "the Python Deployments' env names equal the vendored envtable.json's deployed set (serve and api)" || bad "the Python Deployments' env names differ from the vendored envtable.json (tests/fixtures/autopilot-envtable.COMMIT)"
import json, sys, yaml
vars_ = json.load(open(sys.argv[2]))["vars"]
want = {p: {v["name"] for v in vars_ if v.get("deployed") == "both" or p in v.get("deployed", "").split(",")} for p in ("serve", "api")}
assert len(want["serve"]) >= 30 and len(want["api"]) >= 20, {k: len(v) for k, v in want.items()}
got = {}
for f in ("gateway.yaml", "autopilot-api.yaml"):
    for d in yaml.safe_load_all(open(f"{sys.argv[1]}/{f}")):
        if d and d["kind"] == "Deployment":
            got["serve" if d["metadata"]["name"] == "autopilot-gateway" else "api"] = {e["name"] for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}
for p in want:
    assert want[p] == got[p], (p, "only in the table:", sorted(want[p] - got[p]), "only rendered:", sorted(got[p] - want[p]))
PY4
fi
# nothing lab-only in the Go path off a lab: no hostAliases, no .local host, no LAN address
if grep -rqE 'hostAliases|\.local\b|192\.168\.|10\.0\.0\.[0-9]+' "${G}/gateway-go.yaml" "${G}/autopilot-api-go.yaml" "${G}/gateway-go-extras.yaml"; then bad "go on eks: a lab-only value was rendered"; else ok "go on eks: no hostAliases, .local host or LAN address"; fi
# the lab renders hostAliases only where the Python gateway does (a lab runtime with tower.hostAliasIP)
mkdir -p "${K}/gomig"
cp "${K}/go/cluster.yaml" "${K}/gomig/cluster.yaml"
printf '%s\n' '  # migrate as a PreSync hook' >>"${K}/gomig/cluster.yaml"
sed -i.bak 's/^      plainHttp: /      migrateJob: true\n      plainHttp: /' "${K}/gomig/cluster.yaml" && rm -f "${K}/gomig/cluster.yaml.bak"
render_ok "${K}/gomig" "go with migrateJob"
expect "${K}/gomig" "go with migrateJob" 55-autopilot/gateway/gateway-go-migrate.yaml
if grep -q 'argocd\.argoproj\.io/hook' "${K}/gomig/55-autopilot/gateway/gateway-go-migrate.yaml"; then bad "go: the migrate file has an Argo CD hook annotation (hooks are dropped from partial syncs, argo-cd#28701)"; else ok "go: the migrate Job and policy are ordinary resources, not hooks"; fi
has "${K}/gomig/55-autopilot/gateway/gateway-go-migrate.yaml" 'args: \[migrate\]' "go: the migrate Job runs migrate"
# the core registers the Go image's tag as the gateway's provider version
has "${K}/go/55-clearance/clearance/application.yaml" '"version": "gateway-go-v0\.1\.0"' "go: the Clearance core registers the Go image's tag as the provider version"
has "${K}/pyx/55-clearance/clearance/application.yaml" '"version": "gateway-v' "default: the provider version is still the Python gateway's"
# A-9 S9 step 1 ("prepare"): migrateJob with the Python gateway still serving renders the Job and its NetworkPolicy and nothing else
mkdir -p "${K}/pymig"
cp "${K}/pyx/cluster.yaml" "${K}/pymig/cluster.yaml"
printf '%s\n' '  gateway:' '    implementation: python' '    go:' '      tag: gateway-go-v0.1.0' \
  '      digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' '      migrateJob: true' >>"${K}/pymig/cluster.yaml"
render_ok "${K}/pymig" "implementation: python + migrateJob (step 1)"
expect "${K}/pymig" "step 1" 55-autopilot/gateway/gateway.yaml 55-autopilot/gateway/autopilot-api.yaml 55-autopilot/gateway/gateway-go-migrate.yaml \
  '!55-autopilot/gateway/gateway-go.yaml' '!55-autopilot/gateway/autopilot-api-go.yaml' '!55-autopilot/gateway/gateway-go-extras.yaml' '!55-autopilot/gateway/gateway-go-egress.yaml'
d="$(diff -rq -x cluster.yaml -x .apron-rendered "${K}/pyx" "${K}/pymig" || true)"
if [ "$(wc -l <<<"${d}" | tr -d ' ')" = 1 ] && [[ "${d}" == "Only in ${K}/pymig/55-autopilot/gateway: gateway-go-migrate.yaml" ]]; then
  ok "step 1: the only difference from the switch unset is the migrate file (the Python gateway, read API and everything else are byte-identical)"
else bad "step 1: differences from the switch unset, want only gateway-go-migrate.yaml: ${d}"; fi
M="${K}/pymig/55-autopilot/gateway/gateway-go-migrate.yaml"
has "${M}" 'image: [^ ]*/autopilot-gateway-go:gateway-go-v0\.1\.0@sha256:b{64}$' "step 1: the migrate Job pins the Go image by tag and digest"
has "${M}" 'args: \[migrate\]' "step 1: the Job runs migrate"
has "${M}" 'name: autopilot-pg-migrate' "step 1: the NetworkPolicy that admits the Job to the database renders"
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${M}" <<'PY5' && ok "step 1: ordinary tracked resources (no hook), policy wave 0 < Job wave 1 < the Go Deployments' wave 2, Job named for the image, no TTL, fails fast, cause in the termination message" || bad "step 1: the migrate shape is not as designed"
import sys, yaml
docs = {d["kind"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
np, job = docs["NetworkPolicy"], docs["Job"]
ann = lambda d: d["metadata"].get("annotations", {})
for d in (np, job):
    assert not any(k.startswith("argocd.argoproj.io/hook") for k in ann(d)), "a hook is dropped from a partial sync (argo-cd#28701)"
assert int(ann(np)["argocd.argoproj.io/sync-wave"]) < int(ann(job)["argocd.argoproj.io/sync-wave"]) < 2, "policy, then Job, then the Deployments (wave 2)"
assert job["metadata"]["name"] == "autopilot-gateway-migrate-v0-1-0-bbbbbbbb", job["metadata"]["name"]
assert "ttlSecondsAfterFinished" not in job["spec"], "a deleted finished Job would be re-created and migrate re-run"
assert job["spec"]["activeDeadlineSeconds"] == 300 and job["spec"]["backoffLimit"] == 2
c = job["spec"]["template"]["spec"]["containers"][0]
assert c["terminationMessagePolicy"] == "FallbackToLogsOnError"
assert np["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"] == {"app.kubernetes.io/name": "autopilot-gateway-migrate"}
assert job["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] == "autopilot-gateway-migrate"
PY5
fi
if grep -c 'kind: Deployment\|kind: Service$' "${M}" | grep -qv '^0$'; then bad "step 1: the migrate file renders a Deployment or Service"; else ok "step 1: the migrate file renders no Deployment or Service"; fi
if grep -rl 'autopilot-gateway-go\|gateway-go-v' "${K}/pymig" --exclude=cluster.yaml | grep -qv 'gateway-go-migrate.yaml$'; then bad "step 1: the Go image is named outside the migrate file"; else ok "step 1: the Go image is named only in the migrate file"; fi
has "${K}/pymig/55-clearance/clearance/application.yaml" '"version": "gateway-v' "step 1: the core still registers the Python gateway's version"
refuse "migrateJob (python) without go.digest" "${K}/pyx" '  gateway: {go: {tag: gateway-go-v0.1.0, migrateJob: true}}'
refuse "migrateJob (python) without go.tag" "${K}/pyx" '  gateway: {go: {digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc, migrateJob: true}}'
