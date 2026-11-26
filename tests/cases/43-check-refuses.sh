# tests/cases/43-check-refuses.sh (see tests/run.sh)
# group: render
# secs: 12
# needs: lab gate-agent targets
echo "== 3. check refuses"
python3 hack/check.py --cluster "${LAB}/dev/cluster.yaml" >/dev/null && ok "lab dev passes" || bad "lab dev fails check"
echo "== 1c-4c. clearance core's startup budget (clearance.core.startupSeconds, chart default when unset)"
new "${TMP}/sus-on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set clearance.core.startupSeconds=900
render_ok "${TMP}/sus-on" "core startupSeconds on"
python3 hack/check.py --cluster "${TMP}/sus-on/cluster.yaml" >/dev/null && ok "core startupSeconds on passes check" || bad "core startupSeconds on fails check"
has "${TMP}/sus-on/${CA}" '^          startupSeconds: 900$' "core startupSeconds on: the chart's core.startupSeconds is 900"
if grep -rq 'startupSeconds' "${LAB}/dev" "${LAB}/prod"; then bad "core startupSeconds default: rendered"; else ok "core startupSeconds default: not rendered (chart default)"; fi

python3 hack/check.py --cluster "${LAB}/prod/cluster.yaml" >/dev/null && ok "lab prod passes" || bad "lab prod fails check"
P="${LAB}/prod"
D="${LAB}/dev"
refuse "web on over http" "${D}" 'clearance: {web: {enabled: true}}' 'gateway: {scheme: http}'
refuse "a coverage cache over 300 seconds" "${D}" 'clearance: {api: {coverageCacheSeconds: 301}}'
refuse "a core startupSeconds over 3600" "${D}" 'clearance: {core: {startupSeconds: 3601}}'
refuse "a core startupSeconds that is not a whole number" "${D}" 'clearance: {core: {startupSeconds: "15m"}}'
refuse "a coverage cache that is not a whole number" "${D}" 'clearance: {api: {coverageCacheSeconds: "30s"}}'
# Slack refusals: each case is built from the working Slack cluster with one --set changed (the keys sit in a block cluster.yaml
# already has, so refuse() above, which appends a second top-level key, cannot reach them), and must be refused for the stated reason.
slack_refuse() { # slack_refuse LABEL WANT-IN-MESSAGE [--set k=v ...]   (SLACK_NODNS=1: without the dns01 block)
  local label="$1" want="$2"; shift 2
  local d base=("${SLACK_COMMON[@]}" "${SLACK_DNS[@]}")
  d="$(mktemp -d "${TMP}/slack-refuse-XXXXXX")"
  [ -n "${SLACK_NODNS:-}" ] && base=("${SLACK_COMMON[@]}")
  new "${d}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${base[@]}" "$@"
  if python3 hack/check.py --cluster "${d}/cluster.yaml" >/dev/null 2>"${d}/err"; then
    bad "check accepted: ${label}"
  elif grep -qF -- "${want}" "${d}/err"; then
    ok "refuses ${label}: $(head -1 "${d}/err" | cut -c8-110)"
  else
    bad "refused ${label}, but not for '${want}': $(head -1 "${d}/err")"
  fi
  if python3 hack/render.py --cluster "${d}/cluster.yaml" --out "${d}/out" >/dev/null 2>&1; then bad "render accepted: ${label}"; else ok "render refuses it too: ${label}"; fi
}
slack_refuse "slack on without a publicUrl" "clearance.slack.publicUrl is required" --set clearance.slack.publicUrl=
slack_refuse "slack on with an http publicUrl" "clearance.slack.publicUrl is required" --set clearance.slack.publicUrl=http://slack.clearance.example.com
slack_refuse "slack on with a publicUrl whose port is not a number" "clearance.slack.publicUrl is required" --set clearance.slack.publicUrl=https://slack.clearance.example.com:abc
slack_refuse "slack on with a publicUrl that has a path" "clearance.slack.publicUrl is required" --set clearance.slack.publicUrl=https://slack.clearance.example.com/link
slack_refuse "slack on without slackClientId" "clearance.slack.slackClientId is required" --set clearance.slack.slackClientId=
slack_refuse "slack on with an unknown transport" "clearance.slack.transport must be" --set clearance.slack.transport=webhook
slack_refuse "slack routes by channel name" "must be a Slack channel id" --set 'clearance.slack.routes.security=#security'
slack_refuse "slack routes with a misspelled key" "is not a route" --set clearance.slack.routes.secuirty=C0123456789
slack_refuse "slack webUrl without {id}" "clearance.slack.webUrl must be" --set clearance.slack.webUrl=https://clearance.example.com/changes
slack_refuse "slack on the old chart (no slack.*)" "versions.clearance.chart 0.47.1 or later" --set versions.clearance.chart=0.47.0
slack_refuse "slack without an image digest" "versions.clearance.slackImageDigest" --set versions.clearance.slackImageDigest=
slack_refuse "slack without Clearance" "needs components.clearance" --set components.clearance=false
slack_refuse "slack without people" "needs clearance.people" --set 'clearance.people=[]'
slack_refuse "slack dns01 without a hosted zone" "hostedZoneID is required" --set clearance.slack.tls.dns01.hostedZoneID=
slack_refuse "slack dns01 without an ACME email" "dns01.email is required" --set clearance.slack.tls.dns01.email=
slack_refuse "slack dns01 keyless without a role" "dns01.roleARN is required" --set clearance.slack.tls.dns01.roleARN=
slack_refuse "slack dns01 with an unknown auth" "dns01.auth must be" --set clearance.slack.tls.dns01.auth=password
slack_refuse "slack with an unknown tls mode" "tls.mode must be" --set clearance.slack.tls.mode=acme-http
slack_refuse "slack dns01 without cert-manager" "needs components.certManager" --set components.certManager=false
slack_refuse "slack dns01 behind a load balancer's TLS (https gateway)" "use tls.mode: gateway-existing" --set gateway.scheme=https
SLACK_NODNS=1 slack_refuse "slack gateway-existing on a plain-http gateway" "use tls.mode: dns01-route53"
slack_refuse "slack idp.hostAlias that is not an IP" "idp.hostAlias must be an IP" --set clearance.slack.idp.hostAlias=dex.example.com
slack_refuse "slack idp.cidrs that is not a CIDR" "idp.cidrs is a list of CIDRs" --set 'clearance.slack.idp.cidrs=[dex.example.com]'
refuse "web on without a gateway scheme" "${D}" 'clearance: {web: {enabled: true}}'
refuse "web idpCidrs that is not a CIDR" "${D}" 'clearance: {web: {idpCidrs: [dex.example.com]}}'
refuse "web idpCidrs with a slash that is not a CIDR" "${D}" 'clearance: {web: {idpCidrs: [dex.example.com/x]}}'
refuse "an invalid name" "${D}" 'name: Hangar_Dev'
refuse "a name longer than 63" "${D}" "name: $(printf 'a%.0s' {1..64})"
refuse "no scm owner" "${P}" 'scm: {owner: ""}'
refuse "an unknown runtime" "${P}" 'runtime: {type: minikube}'
refuse "the ledger without a witness" "${D}" 'clearance: {ledger: {enabled: true}}'
refuse "a ledger witness listed by the log's own key (not a cosignature key)" "${D}" 'clearance: {ledger: {enabled: true, witnesses: [{name: w, vkey: "hangarplatform.dev/clearance/hangar-dev+108edc37+AetdxRXum9f4nBr0a6ahyidBM9om7vJErTsu6/TYqQkc", url: "http://w.local"}]}}'
refuse "a ledger witness key with a bad hash" "${D}" 'clearance: {ledger: {enabled: true, witnesses: [{name: w, vkey: "hangarplatform.dev/witness/hangar-prod+df3c5654+BFmnD24M4mdUFnMP9nWpmurlGFfwfX3QK3zYcpjFtlEW", url: "http://w.local"}]}}'
refuse "the witness on a lower-zone cluster" "${D}" 'clearance: {witness: {enabled: true, name: w, logsVkeys: ["hangarplatform.dev/clearance/hangar-dev+108edc37+AetdxRXum9f4nBr0a6ahyidBM9om7vJErTsu6/TYqQkc"]}}'
refuse "the witness listing a cosignature key as a log" "${P}" 'clearance: {witness: {enabled: true, name: w, logsVkeys: ["hangarplatform.dev/witness/hangar-prod+df3c5653+BFmnD24M4mdUFnMP9nWpmurlGFfwfX3QK3zYcpjFtlEW"]}}'
refuse "providerGithub off the control plane" "${P}" 'components: {crossplane: {providerGithub: true}}'
refuse "glidepath off the control plane" "${P}" 'components: {glidepath: true}'
refuse "autopilot off the control plane" "${P}" 'components: {autopilot: true}'
refuse "scope full off the control plane" "${P}" 'components: {serviceCatalog: {enabled: true, scope: full}}'
refuse "signing.managedKeys: 1 (not a boolean)" "${D}" 'signing: {managedKeys: 1}'
refuse "signing.managedKeys off the control plane" "${P}" 'signing: {managedKeys: true}'
refuse "signing.trustedRoot off the control plane" "${P}" 'signing: {trustedRoot: true}'
refuse "keyless attestation off the control plane" "${P}" 'clearance: {attestation: {keyless: true}}'
refuse "keyless attestation without Clearance" "${D}" 'components: {clearance: false}' 'clearance: {attestation: {keyless: true}}'
refuse "targets publishers of a cluster the core does not trust" "${TMP}/tgt-bad" 'clearance: {targets: {enabled: true, publishers: [{cluster: other-prod}]}}'
refuse "ownedProject.create without the gate's agent" "${LAB}/dev" 'clearance: {gate: {agent: {ownedProject: {create: true}}}}'
refuse "targets on without a core" "${TMP}/gate-agent" 'components: {clearance: false}' 'clearance: {targets: {enabled: true}, gate: {url: ""}}'
refuse "autopilot.hardenedRuntime on kiac (no gVisor there)" "${D}" 'autopilot: {hardenedRuntime: gvisor}'
refuse "an unknown autopilot.hardenedRuntime" "${D}" 'autopilot: {hardenedRuntime: kata}'
refuse "autopilot.hardenedRuntime without autopilot" "${P}" 'autopilot: {hardenedRuntime: gvisor}'
refuse "autopilot without the full catalog" "${D}" 'components: {serviceCatalog: {enabled: true, scope: attached-tier-only}}'
refuse "a control plane in the upper zone" "${D}" 'zone: upper'
refuse "an unknown role" "${P}" 'roles: [workloads, gateway]'
refuse "an Infisical consumer without the catalog" "${P}" 'components: {serviceCatalog: {enabled: false}}'
refuse "Infisical on a non-control-plane cluster" "${P}" 'infisical: {host: true}'
refuse "the default issuer" "${D}" 'issuer: https://kubernetes.default.svc.cluster.local'
refuse "an issuer not ending in the name" "${D}" 'issuer: https://hangarplatform.dev/oidc/other'
refuse "a plain-http issuer" "${D}" 'issuer: http://hangarplatform.dev/oidc/hangar-dev'
refuse "towerAccessHub without tower.cluster" "${D}" 'tower: {cluster: ""}'
refuse "an existing context that is not the name" "${P}" 'runtime: {type: existing, existing: {context: kind-old}}'
refuse "kind with a LoadBalancer Traefik" "${P}" 'traefik: {serviceType: LoadBalancer}'
refuse "kiac's own gateway" "${D}" 'runtime: {type: kiac, kiac: {gateway: true}}'
refuse "cloudTargets without an AWS account" "${D}" 'components: {cloudTargets: true}'
refuse "backstage and towerAccess together" "${P}" 'components: {backstage: true}'
refuse "a missing generated password" "${D}" 'generated: {}'
refuse "a consumer without fleet.hub" "${P}" 'fleet: {hub: ""}'
# fleet file rules
F="${TMP}/fleet.yaml"
cat >"${F}" <<'EOF'
clusters:
  - {name: hangar-dev, zone: lower, roles: [control-plane, workloads], airframe: {infisicalHost: true}}
  - {name: other, zone: lower, roles: [control-plane], airframe: {infisicalHost: true}}
  - {name: hangar-prod, zone: upper, roles: [workloads]}
EOF
errs="$(python3 hack/check.py --cluster "${D}/cluster.yaml" --fleet "${F}" 2>&1)"
for want in 'scm: \{owner' 'exactly one control-plane' 'exactly one airframe.infisicalHost' 'relaySecretName'; do
  grep -qE "${want}" <<<"${errs}" && ok "fleet: refuses ${want//\\/}" || bad "fleet: did not refuse ${want}"
done
