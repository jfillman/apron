# tests/cases/36-targets.sh (see tests/run.sh)
# group: render
# secs: 15
# needs: lab signing gate-agent observe-aws
SG="${TMP}/signing"
echo "== 1c-4. the target registry publisher (clearance Map) and the api's attestation trust"
# targets_json DIR -> the rendered target set as sorted JSON on stdout (the ConfigMap's targets.json)
targets_json() {
  python3 - "$1/59-clearance-targets/publisher.yaml" <<'PY'
import json, sys, yaml
cm = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ConfigMap"][0]
print(json.dumps(json.loads(cm["data"]["targets.json"]), sort_keys=True))
PY
}
# The lab shape: prod (upper, Flight, the gate with its agent for one app, the audit collector) publishes to the hub's core;
# dev (the core, the audit collector on a rehearsal namespace, the AWS collector) publishes to its own and registers prod's.
TGT_COMMON=(--set clearance.targets.enabled=true --set 'clearance.targets.owners={gate-api: "group:default/team-gate"}')
new "${TMP}/tgt-prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true \
  "${OBS_SET[@]}" --set 'clearance.observe.protectedNamespaces=[app-gate-api-prod]' "${TGT_COMMON[@]}"
render_ok "${TMP}/tgt-prod" "targets on (prod)"
TP="${TMP}/tgt-prod/59-clearance-targets/publisher.yaml"
EXPECT_PROD='{"targets": [{"app": "gate-api", "env": "prod", "gates": [{"instance": "app-gate-api-cicd/pipeline-runner", "mode": "enforce", "type": "glidepath"}, {"instance": "app-gate-api-cicd/clearance-gate", "mode": "enforce", "type": "glidepath"}, {"instance": "argocd-agent", "mode": "flag", "type": "g-argo"}], "group": "hangar-prod", "id": "hangar-prod.app-gate-api-prod", "kind": "k8s-namespace", "name": "app-gate-api-prod", "observers": [{"provider": "observe-k8s", "source": "k8s-audit-webhook"}], "owner": "group:default/team-gate", "registry": "flight", "scope": "hangar-prod"}]}'
[ "$(targets_json "${TMP}/tgt-prod")" = "${EXPECT_PROD}" ] && ok "targets (prod): the protected namespace, its Glidepath and Argo CD gates (warn mode: flag), the audit collector, Flight, scope = the cluster" || bad "targets (prod): unexpected set: $(targets_json "${TMP}/tgt-prod")"
has "${TP}" 'value: "http://clearance.hangar-dev.local"' "targets (prod): publishes to the core as the gate reaches it"
has "${TP}" 'value: "hangar-prod"' "targets (prod): the source is the cluster"
has "${TP}" 'path: clearance, audience: clearance' "targets (prod): a projected token for audience clearance, minted per run"
has "${TP}" 'hostAliases: \[\{"ip": "192.0.2.1"' "targets (prod): the hub's address through the host alias"
has "${TP}" 'cidr": "192.0.2.1/32"' "targets (prod): egress to the core's address only"
has "${TP}" 'schedule: "3-59/15 \* \* \* \*"' "targets (prod): every 15 minutes, at minute 3"
if grep -qE 'automountServiceAccountToken: true|hostNetwork|privileged: true' "${TP}"; then bad "targets (prod): the publisher is not locked down"; else ok "targets (prod): the Job mounts no default token, no host network, no privilege"; fi
has "${TMP}/tgt-prod/59-clearance-targets/application.yaml" 'path: 59-clearance-targets' "targets (prod): its own Application"
# enforce mode flips the Argo CD gate's declared mode; an unprotected environment's Glidepath gate flags
mkdir -p "${TMP}/tgt-prod-enf"
python3 - "${TMP}/tgt-prod/cluster.yaml" "${TMP}/tgt-prod-enf/cluster.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
c["clearance"]["gate"]["enforce"] = True
# Deny needs an enforcing grant-expiry webhook (I-44; the agent chart and check refuse it otherwise).
c["clearance"]["gate"]["agent"]["grantExpiry"] = {"enabled": True, "mode": "enforce"}
c["clearance"]["protectedEnvironments"] = ["hangar-prod/staging"]
yaml.safe_dump(c, open(sys.argv[2], "w"))
PY
render_ok "${TMP}/tgt-prod-enf" "targets on, enforce and another protected environment"
python3 - "$(targets_json "${TMP}/tgt-prod-enf")" <<'PY' && ok "targets: enforce flips the g-argo mode; an unprotected environment's Glidepath gate is flag" || bad "targets: enforce / unprotected modes wrong"
import json, sys
g = {x["type"]: x["mode"] for x in json.loads(sys.argv[1])["targets"][0]["gates"]}
sys.exit(0 if g == {"glidepath": "flag", "g-argo": "enforce"} else 1)
PY
expect "${TMP}/gate-agent" "targets off" '!59-clearance-targets'
# the core's cluster: its own publisher, a registered remote publisher, the AWS account
new "${TMP}/tgt-dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${AWS_SET[@]}" "${OBS_SET[@]}" --set 'clearance.observe.protectedNamespaces=[observe-rehearsal]' "${TGT_COMMON[@]}" \
  --set 'clearance.targets.publishers=[{cluster: hangar-prod}]' --set 'clearance.observeAWS.environment=lab' \
  --set 'clearance.observeAWS.gates=[{type: g-tf, instance: "github:repo:acme/infra:ref:refs/heads/main", mode: enforce}]'
render_ok "${TMP}/tgt-dev" "targets on (dev, the core)"
EXPECT_DEV='{"targets": [{"env": "lab", "gates": [{"instance": "github:repo:acme/infra:ref:refs/heads/main", "mode": "enforce", "type": "g-tf"}], "group": "111122223333", "id": "aws.111122223333", "kind": "aws-account", "name": "aws-lab", "observers": [{"provider": "observe-aws", "source": "observe-aws"}], "owner": "group:default/admins", "scope": "111122223333"}, {"gates": [], "group": "hangar-dev", "id": "hangar-dev.observe-rehearsal", "kind": "k8s-namespace", "name": "observe-rehearsal", "observers": [{"provider": "observe-k8s", "source": "k8s-audit-webhook"}], "registry": "ground", "scope": "hangar-dev"}]}'
[ "$(targets_json "${TMP}/tgt-dev")" = "${EXPECT_DEV}" ] && ok "targets (dev): the AWS account (scope = the account, G-TF from cluster.yaml) and the rehearsal namespace (no app: no gates), Ground" || bad "targets (dev): unexpected set: $(targets_json "${TMP}/tgt-dev")"
TC="${TMP}/tgt-dev/55-clearance/clearance/application.yaml"
has "${TMP}/tgt-dev/55-clearance/clearance-config/routes.yaml" 'value: "\^/v1/targets/\[a-z0-9\]\[a-z0-9-\]\*\$"' "targets (dev): the Gateway routes a remote publisher's PUT /v1/targets/<source> to the core"
# I-81: a remote gate agent (clearance.feedReaders) reads the core's protection state and reports its own cluster's pairs
# (GET /v1/protection, PUT /v1/protection/<cluster>) through the gate route; without feedReaders neither is routed.
new "${TMP}/feed-dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set 'clearance.feedReaders=[{principal: hangar-prod/clearance-system/clearance-argocd-agent, cluster: hangar-prod}]'
render_ok "${TMP}/feed-dev" "feedReaders on (dev, the core)"
FR="${TMP}/feed-dev/55-clearance/clearance-config/routes.yaml"
has "${FR}" 'value: /v1/records\}' "feedReaders: the Gateway routes the agent's POST /v1/records"
python3 - "${FR}" <<'PY' && ok "feedReaders: the gate route sends GET /v1/protection (Exact) and PUT /v1/protection/<cluster> (a name) to the core, no other method" || bad "feedReaders: the protection matches are missing or wrong"
import re, sys, yaml
route = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["metadata"]["name"] == "clearance-gate")
m = [(x["path"]["type"], x["path"]["value"], x.get("method")) for r in route["spec"]["rules"] for x in r["matches"] if "protection" in x["path"]["value"]]
assert sorted(m) == [("Exact", "/v1/protection", "GET"), ("RegularExpression", "^/v1/protection/[a-z0-9][a-z0-9-]*$", "PUT")], m
rx = re.compile(m[0][1] if m[0][0] == "RegularExpression" else m[1][1])
assert rx.match("/v1/protection/hangar-prod") and not rx.match("/v1/protection/") and not rx.match("/v1/protection/a/b") and not rx.match("/v1/protection/Hangar")
PY
if grep -q '/v1/protection' "${LAB}/dev/55-clearance/clearance-config/routes.yaml"; then bad "no feedReaders: the gate route carries /v1/protection"; else ok "no feedReaders: no /v1/protection route (the render is as before)"; fi
has "${TC}" '"name": "targets-hangar-dev", "version": "[0-9.]+", "principals": \["clearance-system/clearance-targets"\], "kinds": \[\], "targets": \["hangar-dev"\]' "targets (dev): the core registers its own publisher with the right to publish its own source only"
has "${TC}" '"name": "targets-hangar-prod", "version": "[0-9.]+", "principals": \["hangar-prod/clearance-system/clearance-targets"\], "kinds": \[\], "targets": \["hangar-prod"\]' "targets (dev): and the remote publisher, for its source only"
has "${TC}" 'serviceAccounts: \[.*"clearance-system/clearance-targets"\]' "targets (dev): the remote publisher's account is a foreign service account of the Tower cluster"
has "${TC}" 'app.kubernetes.io/name: clearance-targets' "targets (dev): the core's NetworkPolicy admits the local publisher"
has "${TMP}/tgt-dev/59-clearance-targets/publisher.yaml" 'value: "http://clearance-core.clearance-system.svc:8080"' "targets (dev): the local publisher talks to the in-cluster core"
has "${TMP}/tgt-dev/59-clearance-targets/publisher.yaml" 'app.kubernetes.io/name": "clearance-core"' "targets (dev): egress to the core pod only"
if grep -q 'targets' "${TMP}/aws-dev/55-clearance/clearance/application.yaml"; then bad "targets off: the core's providers or policy mention targets"; else ok "targets off: the core's Application is unchanged"; fi
# A real address never leaks into the templates: the only account id in the render is the one cluster.yaml gave.
if grep -rn '[0-9]\{12\}' "${TMP}/tgt-prod/59-clearance-targets" | grep -q .; then bad "targets (prod): an account id in a Kubernetes-only render"; else ok "targets (prod): no account id"; fi
# Refusals
new "${TMP}/tgt-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod
new "${TMP}/tgt-bad2" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev \
  --set clearance.targets.enabled=true --set clearance.gate.url=http://clearance.hangar-dev.local --set 'clearance.targets.extra=[{id: BAD, name: x, kind: other, group: g}]'
new "${TMP}/tgt-bad3" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev \
  --set clearance.targets.enabled=true --set clearance.gate.url=http://clearance.hangar-dev.local
TGT_ERR="$(python3 hack/render.py --cluster "${TMP}/tgt-bad2/cluster.yaml" 2>&1 || true)"
NOALIAS_ERR="$(python3 hack/render.py --cluster "${TMP}/tgt-bad3/cluster.yaml" 2>&1 || true)"
grep -q 'needs clearance.gate.hostAlias' <<<"${NOALIAS_ERR}" && ok "targets: a remote core without a host alias is refused (no unpinned egress)" || bad "targets: remote core without hostAlias should be refused: ${NOALIAS_ERR}"
grep -q "clearance.targets.extra\[0\]: id 'BAD' is a lower-case name" <<<"${TGT_ERR}" && ok "targets: an invalid hand-declared target is refused at render, by name" || bad "targets: invalid extra target should be refused by name: ${TGT_ERR}"
# api.attest: the keyless trust (public trusted root, the core's identity, the cluster's issuer), only with the trusted root published
AC="${SG}/55-clearance/clearance/application.yaml"
has "${AC}" 'configMap: clearance-attest-trust' "attest trust: the api mounts the public trust ConfigMap"
has "${AC}" 'trustRoot: trusted-root.json' "attest trust: the trusted root is the keyless trust"
has "${AC}" 'identity: "https://kubernetes.io/namespaces/clearance-system/serviceaccounts/clearance-core"' "attest trust: the identity is the core's service account"
has "${AC}" 'issuer: "https://hangarplatform.dev/oidc/hangar-dev"' "attest trust: the issuer is the cluster's"
# clearance-api refuses an http Rekor link (not loopback, not an in-cluster Service): an http Gateway offers none.
if grep -q 'rekorUrl: "http://rekor\.' "${AC}"; then bad "attest trust: an http public Rekor URL would crash clearance-api"; else ok "attest trust: no http public Rekor URL on an http Gateway"; fi
has "${SG}/55-clearance/clearance-config/attest-trust.yaml" '^  trusted-root.json: "\{' "attest trust: the ConfigMap holds signing-pki/trusted-root.json"
expect "${TMP}/aws-dev" "attest trust without the trusted root" '!55-clearance/clearance-config/attest-trust.yaml'
if grep -q 'attest:' "${TMP}/aws-dev/55-clearance/clearance/application.yaml"; then bad "attest trust off: api.attest rendered"; else ok "attest trust off: api.attest not rendered"; fi
if grep -rn 'PRIVATE KEY' "${SG}/55-clearance" >/dev/null; then bad "attest trust: key material in the render"; else ok "attest trust: public material only"; fi
