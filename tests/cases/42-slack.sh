# tests/cases/42-slack.sh (see tests/run.sh)
# group: render
# secs: 15
# needs: lab
echo "== 1c-5. Clearance Slack (clearance.slack.enabled)"
new "${TMP}/slack-on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${SLACK_COMMON[@]}" "${SLACK_DNS[@]}"
render_ok "${TMP}/slack-on" "slack on (dns01-route53)"
SL="${TMP}/slack-on"
python3 hack/check.py --cluster "${SL}/cluster.yaml" >/dev/null && ok "slack on passes check" || bad "slack on fails check"
CC=55-clearance/clearance-config
expect "${SL}" "slack on" ${CC}/slack-secret.yaml ${CC}/slack-route.yaml ${CC}/slack-tls.yaml 55-identity/people-dex/clearance-slack-secret.yaml
has "${SL}/${CA}" '^        slack:$' "slack on: the chart's slack values"
has "${SL}/${CA}" 'existingSecret: clearance-slack$' "slack on: the Secret is the one the ExternalSecret makes"
has "${SL}/${CA}" 'idpClientId: clearance-slack$' "slack on: the IdP client id"
has "${SL}/${CA}" 'idpClientSecret: true' "slack on: the IdP client is confidential"
has "${SL}/${CA}" 'transport: socket$' "slack on: Socket Mode by default"
has "${SL}/${CA}" 'publicUrl: "https://slack\.clearance\.example\.com"' "slack on: the public URL"
has "${SL}/${CA}" 'slackClientId: "1234\.5678"' "slack on: the Slack client id"
has "${SL}/${CA}" 'digest: "sha256:f422dd02' "slack on: the image is pinned by digest"
has "${SL}/${CA}" '"groups": \{"group:default/payments": "C0123456789"\}' "slack on: routes"
has "${SL}/${CA}" 'webUrl: ""' "slack on: no web UI, no web URL"
has "${SL}/${CA}" '\{"ip": "192\.0\.2\.10", "hostnames": \["dex\.hangar-dev\.local"\]\}' "slack on: the IdP host alias"
has "${SL}/${CA}" 'cidr": "192\.0\.2\.10/32"' "slack on: egress to the IdP narrowed to the alias"
has "${SL}/${CA}" 'port: 5556' "slack on: egress to people-dex's keys"
has "${SL}/${CC}/postgres.yaml" 'name: clearance_slack$' "slack on: the managed role"
has "${SL}/${CC}/postgres.yaml" 'passwordSecret: \{name: clearance-pg-slack\}' "slack on: the role's password is the generated Secret"
has "${SL}/${CC}/slack-secret.yaml" 'kind: Password' "slack on: the password is generated in the cluster"
has "${SL}/${CC}/slack-secret.yaml" 'kind: Database' "slack on: the database is declared"
has "${SL}/${CC}/slack-secret.yaml" 'owner: clearance_slack' "slack on: the role owns its database"
has "${SL}/${CC}/slack-secret.yaml" 'dsn: "postgresql://clearance_slack:\{\{ \.password \}\}@clearance-pg-rw\.clearance-system\.svc:5432/clearance_slack"' "slack on: the DSN is built from the generated password"
has "${SL}/${CC}/slack-secret.yaml" 'key: dsn' "slack on: dsn joins the Secret by templateFrom"
for key in clearance-slack-bot-token clearance-slack-app-token clearance-slack-signin-client-secret clearance-slack-idp-client-secret; do
  has "${SL}/${CC}/slack-secret.yaml" "key: ${key}\}" "slack on: Infisical key ${key}"
done
if grep -q 'secretKey: signing-secret' "${SL}/${CC}/slack-secret.yaml"; then bad "slack on (socket): the signing secret is asked for"; else ok "slack on (socket): no signing secret"; fi
if grep -qE 'remoteRef: \{key: [a-z-]*dsn' "${SL}/${CC}/slack-secret.yaml"; then bad "slack on: a dsn secret is read from Infisical"; else ok "slack on: no dsn in Infisical"; fi
has "${SL}/${CC}/slack-route.yaml" 'sectionName: clearance-slack-https' "slack on (dns01): the route attaches to the https listener"
has "${SL}/${CC}/slack-route.yaml" '- slack\.clearance\.example\.com$' "slack on: the route's host"
has "${SL}/${CC}/slack-route.yaml" 'name: clearance-slack$' "slack on: the route's backend is the chart's Service"
has "${SL}/10-crds-operators/traefik/gateway.yaml" 'name: clearance-slack-https' "slack on (dns01): the Gateway gets the https listener"
has "${SL}/10-crds-operators/traefik/gateway.yaml" 'hostname: slack\.clearance\.example\.com' "slack on (dns01): the listener is for the one host"
has "${SL}/10-crds-operators/traefik/gateway.yaml" 'name: clearance-slack-tls' "slack on (dns01): the listener's certificate is the Certificate's Secret"
has "${SL}/${CC}/slack-tls.yaml" 'hostedZoneID: Z0123456789ABC' "slack on (dns01): the Route 53 zone"
has "${SL}/${CC}/slack-tls.yaml" 'server: "https://acme-v02\.api\.letsencrypt\.org/directory"' "slack on (dns01): Let's Encrypt production"
has "${SL}/${CC}/slack-tls.yaml" 'role: "arn:aws:iam::111122223333:role/dns01"' "slack on (dns01): the role cert-manager assumes"
has "${SL}/${CC}/slack-tls.yaml" 'serviceAccountRef:' "slack on (dns01): keyless by default"
has "${SL}/${CC}/slack-tls.yaml" 'resourceNames: \[clearance-dns01\]' "slack on (dns01): cert-manager may create tokens for that account only"
has "${SL}/${CC}/slack-tls.yaml" 'dnsNames: \["slack\.clearance\.example\.com"\]' "slack on (dns01): the Certificate names the host"
if grep -qE 'accessKeyIDSecretRef|remoteRef' "${SL}/${CC}/slack-tls.yaml"; then bad "slack on (serviceAccount): a stored key is referenced"; else ok "slack on (serviceAccount): no stored key"; fi
has "${SL}/55-identity/people-dex/dex.yaml" 'id: clearance-slack$' "slack on: the Dex client"
has "${SL}/55-identity/people-dex/dex.yaml" 'secretEnv: CLEARANCE_SLACK_CLIENT_SECRET' "slack on: Dex reads the client secret from env (confidential)"
has "${SL}/55-identity/people-dex/dex.yaml" 'redirectURIs: \["https://slack\.clearance\.example\.com/link/idp"\]' "slack on: the redirect is <publicUrl>/link/idp"
has "${SL}/55-identity/people-dex/clearance-slack-secret.yaml" 'key: clearance-slack-idp-client-secret' "slack on: the Infisical key (Dex side)"
if grep -q 'trustedPeers' "${SL}/55-identity/people-dex/dex.yaml"; then bad "slack on: trustedPeers rendered without the web UI"; else ok "slack on: the clearance client's trust is unchanged"; fi
if [ "${HAVE_YAML}" = true ]; then
  if python3 - "${SL}" <<'PY'
import sys, yaml, glob
d = sys.argv[1]
for f in glob.glob(d + "/55-clearance/clearance-config/slack-*.yaml"):
    assert [x for x in yaml.safe_load_all(open(f)) if x], f
gw = [x for x in yaml.safe_load_all(open(d + "/10-crds-operators/traefik/gateway.yaml")) if x and x["kind"] == "Gateway"][0]
assert [l["name"] for l in gw["spec"]["listeners"]] == ["web", "clearance-slack-https"], gw["spec"]["listeners"]
app = yaml.safe_load(open(d + "/55-clearance/clearance/application.yaml"))["spec"]["source"]["helm"]["valuesObject"]
assert app["slack"]["routes"]["security"] == "C0SECURITY"
assert app["networkPolicy"]["slack"]["extraEgress"][1]["ports"][0]["port"] == 80
PY
  then ok "slack on: objects parse, the Gateway has web + the https listener, values are structured"; else bad "slack on: structure check failed"; fi
fi
# Sync order: the route on the https listener is Degraded (not Accepted) until the Certificate's Secret exists, and Argo CD
# starts no later wave past a Degraded one, so it must come after the Issuer and the Certificate (route > Certificate > Issuer).
slack_waves() { # slack_waves DIR LABEL
  python3 - "$1" <<'PY' && ok "$2: sync waves route > Certificate > Issuer" || bad "$2: sync waves out of order"
import re, sys
d = sys.argv[1] + "/55-clearance/clearance-config/"
def wave(text, kind):
    for doc in text.split("\n---\n"):
        if re.search(rf"^kind: {kind}$", doc, re.M):
            m = re.search(r'argocd\.argoproj\.io/sync-wave: "(-?\d+)"', doc)
            return int(m.group(1)) if m else 0
    raise SystemExit(f"no {kind}")
tls = open(d + "slack-tls.yaml").read()
issuer, cert, route = wave(tls, "Issuer"), wave(tls, "Certificate"), wave(open(d + "slack-route.yaml").read(), "HTTPRoute")
print(f"    Issuer {issuer}, Certificate {cert}, HTTPRoute {route}")
assert route > cert > issuer, (issuer, cert, route)
PY
}
slack_waves "${SL}" "slack on (dns01, serviceAccount)"

new "${TMP}/slack-static" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${SLACK_COMMON[@]}" --set clearance.slack.tls.mode=dns01-route53 --set clearance.slack.tls.dns01.hostedZoneID=Z0123456789ABC \
  --set clearance.slack.tls.dns01.email=ops@example.com --set clearance.slack.tls.dns01.auth=static --set clearance.slack.transport=events \
  --set 'clearance.slack.tls.dns01.server=https://acme-staging-v02.api.letsencrypt.org/directory'
render_ok "${TMP}/slack-static" "slack on (static key, events, staging ACME)"
SS="${TMP}/slack-static"
has "${SS}/${CC}/slack-tls.yaml" 'accessKeyIDSecretRef: \{name: clearance-dns01-route53, key: access-key-id\}' "slack static: the key pair by reference"
has "${SS}/${CC}/slack-tls.yaml" 'key: clearance-dns01-route53-access-key-id\}' "slack static: the Infisical access key id"
has "${SS}/${CC}/slack-tls.yaml" 'key: clearance-dns01-route53-secret-access-key\}' "slack static: the Infisical secret access key"
has "${SS}/${CC}/slack-tls.yaml" 'acme-staging-v02' "slack static: the ACME server is the one asked for"
if grep -qE 'serviceAccountRef|kind: Role$' "${SS}/${CC}/slack-tls.yaml"; then bad "slack static: the service-account path rendered"; else ok "slack static: no service-account token path"; fi
slack_waves "${SS}" "slack static (dns01, static key)"
has "${SS}/${CA}" 'transport: events$' "slack events: the chart's transport"
has "${SS}/${CC}/slack-secret.yaml" 'key: clearance-slack-signing-secret\}' "slack events: the signing secret is read"
if grep -q 'secretKey: app-token' "${SS}/${CC}/slack-secret.yaml"; then bad "slack events: the app token is asked for"; else ok "slack events: no app token"; fi
has "${SS}/${CA}" 'cidr": "0\.0\.0\.0/0"' "slack: without a hostAlias the IdP egress is idp.cidrs (default anywhere)"
has "${SS}/${CA}" 'hostAliases: \[\]' "slack: without a hostAlias no host alias"

new "${TMP}/slack-eks" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${SLACK_COMMON[@]}" --set gateway.scheme=https --set clearance.web.enabled=true
render_ok "${TMP}/slack-eks" "slack on (gateway-existing, https gateway, web UI)"
SE="${TMP}/slack-eks"
expect "${SE}" "slack gateway-existing" ${CC}/slack-secret.yaml ${CC}/slack-route.yaml "!${CC}/slack-tls.yaml"
if grep -q 'clearance-slack-https' "${SE}/10-crds-operators/traefik/gateway.yaml" "${SE}/${CC}/slack-route.yaml"; then bad "slack gateway-existing: an https listener or sectionName rendered"; else ok "slack gateway-existing: the Gateway and the route are the ordinary ones"; fi
if grep -q 'sync-wave' "${SE}/${CC}/slack-route.yaml"; then bad "slack gateway-existing: the route has a sync wave (no certificate to wait for)"; else ok "slack gateway-existing: the route has no sync wave"; fi
has "${SE}/${CA}" 'webUrl: "https://clearance\.hangar-dev\.local/changes/\{id\}"' "slack + web UI: tier 3 links to the web UI by default"
has "${SE}/${CA}" 'port: 443' "slack on an https gateway: IdP egress on 443"
if grep -q 'trustedPeers: \["clearance-web"\]' "${SE}/55-identity/people-dex/dex.yaml" && grep -q 'id: clearance-slack$' "${SE}/55-identity/people-dex/dex.yaml"; then ok "slack + web UI: both Dex clients"; else bad "slack + web UI: Dex clients missing"; fi

if grep -rniE 'clearance-slack|clearance_slack|slack\.' "${LAB}/dev" "${LAB}/prod" --exclude=cluster.yaml >/dev/null; then bad "slack off: something of the Slack service rendered"; else ok "slack off: nothing of the Slack service renders"; fi
mkdir -p "${TMP}/slack-offdev"
cp "${LAB}/dev/cluster.yaml" "${TMP}/slack-offdev/cluster.yaml"
printf 'clearance:\n  slack: {enabled: false}\n' >>"${TMP}/slack-offdev/cluster.yaml"
render_ok "${TMP}/slack-offdev" "slack explicitly off"
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/slack-offdev" >/dev/null; then ok "slack key off == absent, byte for byte"; else bad "slack off differs from absent"; fi
