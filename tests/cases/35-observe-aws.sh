# tests/cases/35-observe-aws.sh (see tests/run.sh)
# group: render
# secs: 5
# needs: ledger
echo "== 1c-3. the AWS collector (clearance observe-aws)"
new "${TMP}/aws-dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${AWS_SET[@]}"
render_ok "${TMP}/aws-dev" "aws collector on"
AA="${TMP}/aws-dev/58-clearance-observe-aws/application.yaml"
has "${AA}" 'tag: "v[0-9.]+@sha256:4{64}"' "aws collector on: the image is pinned by digest"
has "${AA}" 'apiURL: "http://clearance-api[.][a-z-]+[.]svc:8080"' "aws collector on: the clearance-api URL"
has "${AA}" 'account: "111122223333"' "aws collector on: the account"
has "${AA}" 'region: "us-east-1"' "aws collector on: region defaults"
has "${AA}" 'rules: \["observe-aws-cloudtrail", "observe-aws-config"\]' "aws collector on: the default EventBridge rules"
has "${AA}" 'applyRoles: \["deployer"\]' "aws collector on: the apply roles"
has "${AA}" 'governedAccounts: \["444455556666"\]' "aws collector on: the governed accounts"
has "${AA}" 'regions: \["us-east-1"\]' "aws collector on: trail regions default"
has "${AA}" 'name: "organization"' "aws collector on: trail name default"
has "${AA}" 'namespace: clearance-system$' "aws collector on: fixed destination namespace"
[ "$(grep -c 'app.kubernetes.io/name: clearance-observe-aws' "${TMP}/aws-dev/55-clearance/clearance/application.yaml")" = 2 ] \
  && ok "aws collector on: admitted by the core and clearance-api" || bad "aws collector on: expected the netpol entry in both core.from and api.from"
has "${TMP}/aws-dev/55-clearance/clearance/application.yaml" 'auditors: \[.*"clearance-system/clearance-observe-aws"\]' "aws collector on: the extra auditor is appended verbatim"
if grep -q 'clearance-observe-aws' "${TMP}/led-prod/55-clearance/clearance/application.yaml"; then bad "aws collector off: netpol entry rendered"; else ok "aws collector off: no netpol entry"; fi
expect "${TMP}/led-prod" "aws collector off" '!58-clearance-observe-aws/application.yaml'
new "${TMP}/aws-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set clearance.observeAWS.enabled=true --set versions.clearance.observeAWSImage="${AWS_IMG}" --set clearance.observeAWS.account=111122223333
AWS_ERR="$(python3 hack/render.py --cluster "${TMP}/aws-bad/cluster.yaml" 2>&1 || true)"
grep -q 'clearance.observeAWS.queueURL is required' <<<"${AWS_ERR}" && ok "aws collector on without a queueURL refuses" || bad "aws collector on without a queueURL should be refused by name: ${AWS_ERR}"
