# tests/cases/40-web.sh (see tests/run.sh)
# group: render
# secs: 7
# needs: lab
echo "== 1c-4. the standalone web UI (clearance.web.enabled)"
new "${TMP}/web-on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set clearance.web.enabled=true --set gateway.scheme=https --set 'clearance.people=[alice]' --set 'clearance.web.idpCidrs=[203.0.113.10/32]'
render_ok "${TMP}/web-on" "web on"
W="${TMP}/web-on"
python3 hack/check.py --cluster "${W}/cluster.yaml" >/dev/null && ok "web on passes check" || bad "web on fails check"
expect "${W}" "web on" 55-clearance/clearance-config/web-secret.yaml 55-identity/people-dex/clearance-web-secret.yaml
has "${W}/${CA}" '^        web:$' "web on: the chart's web values"
has "${W}/${CA}" 'publicURL: "https://clearance\.hangar-dev\.local"' "web on: public URL"
has "${W}/${CA}" 'issuer: "https://dex\.hangar-dev\.local/dex"' "web on: issuer is people-dex"
has "${W}/${CA}" 'existingSecret: clearance-web-oidc' "web on: client secret by reference"
has "${W}/${CA}" '203\.0\.113\.10/32' "web on: IdP egress from idpCidrs"
has "${W}/55-clearance/clearance-config/routes.yaml" '^  name: clearance-web$' "web on: the route"
has "${W}/55-identity/people-dex/dex.yaml" 'id: clearance-web' "web on: the Dex client"
has "${W}/${CA}" 'upstreamAudience: clearance' "web on: the web asks for the core's audience"
has "${W}/55-identity/people-dex/dex.yaml" 'trustedPeers: \["clearance-web"\]' "web on: the clearance client trusts clearance-web"
has "${W}/55-identity/people-dex/dex.yaml" 'secretEnv: CLEARANCE_WEB_CLIENT_SECRET' "web on: Dex reads the secret from env"
has "${W}/55-identity/people-dex/dex.yaml" 'https://clearance\.hangar-dev\.local/auth/callback' "web on: redirect URI"
has "${W}/55-identity/people-dex/clearance-web-secret.yaml" 'key: clearance-web-oidc-client-secret' "web on: the Infisical key (Dex side)"
has "${W}/55-clearance/clearance-config/web-secret.yaml" 'key: clearance-web-oidc-client-secret' "web on: the Infisical key (pod side)"
if grep -rqE 'trustedPeers|upstreamAudience' "${LAB}/dev" "${LAB}/prod"; then bad "web off: trustedPeers or upstreamAudience rendered"; else ok "web off: no trustedPeers, no upstreamAudience"; fi
if grep -rn 'clearance-web' "${LAB}/dev" "${LAB}/prod" >/dev/null; then bad "web off: clearance-web rendered"; else ok "web off: nothing of the web UI renders"; fi
mkdir -p "${TMP}/web-offdev"
cp "${LAB}/dev/cluster.yaml" "${TMP}/web-offdev/cluster.yaml"
printf 'clearance:\n  web: {enabled: false}\n' >>"${TMP}/web-offdev/cluster.yaml"
render_ok "${TMP}/web-offdev" "web explicitly off"
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/web-offdev" >/dev/null; then ok "web key off == absent, byte for byte"; else bad "web off differs from absent"; fi
