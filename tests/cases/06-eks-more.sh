# tests/cases/06-eks-more.sh (see tests/run.sh)
# group: render
# secs: 4
# needs: lab eks
# Autopilot's hardened tier: off by default (hardened runs Rejected), on with autopilot.hardenedRuntime: gvisor
expect "${K}/dev" "eks-dev" '!55-autopilot/sandbox-runtime'
has "${K}/dev/10-crds-operators/crossplane/function-agentrun-runtime.yaml" "value: '\\{\\}'" "eks-dev: no runtime classes by default"
has "${LAB}/dev/10-crds-operators/crossplane/function-agentrun-runtime.yaml" "value: '\\{\\}'" "lab: no runtime classes"
mkdir -p "${K}/gv" && cp "${K}/dev/cluster.yaml" "${K}/gv/cluster.yaml" && printf 'autopilot: {hardenedRuntime: gvisor}\n' >>"${K}/gv/cluster.yaml"
python3 hack/check.py --cluster "${K}/gv/cluster.yaml" >/dev/null 2>"${TMP}/gv-check" \
  && ok "eks-dev with gvisor: passes check" || bad "eks-dev with gvisor: check: $(cat "${TMP}/gv-check")"
render_ok "${K}/gv" "eks-dev with gvisor"
expect "${K}/gv" "eks-dev with gvisor" 55-autopilot/sandbox-runtime/runtimeclass.yaml 55-autopilot/sandbox-runtime/application.yaml
has "${K}/gv/55-autopilot/sandbox-runtime/runtimeclass.yaml" '^handler: runsc$' "eks-dev with gvisor: RuntimeClass handler runsc"
has "${K}/gv/10-crds-operators/crossplane/function-agentrun-runtime.yaml" \
  "value: '\\{\"hardened\":\"gvisor\"\\}'" "eks-dev with gvisor: function-agentrun gets HANGAR_RUNTIME_CLASSES"
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${K}/gv/10-crds-operators/crossplane/function-agentrun-runtime.yaml" <<'PY2' \
    && ok "eks-dev with gvisor: HANGAR_RUNTIME_CLASSES parses as the JSON object the function expects" \
    || bad "eks-dev with gvisor: HANGAR_RUNTIME_CLASSES does not parse"
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = {e["name"]: e["value"] for e in d["spec"]["deploymentTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]}
assert json.loads(env["HANGAR_RUNTIME_CLASSES"]) == {"hardened": "gvisor"}, env
PY2
fi
expect "${K}/prod" "eks-prod" 00-bootstrap/backstage-ingestor-rbac/rbac.yaml 10-crds-operators/external-secrets/cluster-secret-store.yaml \
  '!66-tower-access' '!50-glidepath' '!60-gateway-routes/glidepath-relay-httproute.yaml'
if grep -q 'resourceNames:.*glidepath-api\|- glidepath-api$' "${K}/prod/00-bootstrap/backstage-ingestor-rbac/rbac.yaml" "${K}/prod/00-bootstrap/backstage-ingestor-rbac/tower-actor-rbac.yaml"; then
  bad "eks-prod: glidepath-api proxy grants rendered off the control plane"
else
  ok "eks-prod: no glidepath-api proxy grants off the control plane"
fi
has "${K}/prod/10-crds-operators/external-secrets/cluster-secret-store.yaml" "hostAPI: \"${INF}\"" "eks-prod: store reaches Infisical's URL"
has "${K}/prod/01-argocd-platform/argocd-apps-install/application.yaml" 'url: https://relay\.eks-dev\.aws\.example\.dev' "eks-prod: relay over the gateway"
expect "${K}/man" "eks-man" 66-tower-access/rbac.yaml '!50-glidepath' '!00-bootstrap/backstage-ingestor-rbac' '!10-crds-operators/mongodb-kubernetes'
# the lab renders exactly as before: none of the eks keys leak into a kubeadm cluster
has "${LAB}/dev/00-bootstrap/backstage-ingestor-rbac/rbac.yaml" 'name: hangar:hangar-prod:backstage-ingestor$' "lab: Tower's structured-authn username unchanged"
if grep -q 'loadBalancerClass\|aws-load-balancer' "${LAB}/prod/10-crds-operators/traefik/traefik.yaml"; then bad "lab: NLB keys leaked"; else ok "lab: no NLB keys"; fi
has "${LAB}/prod/10-crds-operators/traefik/traefik.yaml" 'targetPort: websecure' "lab: 443 still reaches websecure"
python3 hack/render.py --cluster "${K}/dev/cluster.yaml" --print-values | python3 -c '
import json, sys
r = json.load(sys.stdin)["runtime"]
assert r["type"] == "eks" and r["eks"]["region"] == "us-east-1", r' \
  && ok "eks: --print-values carries runtime.eks (apron up phase 1 reads its region)" \
  || bad "eks: --print-values lacks runtime.eks.region"
python3 hack/render.py --cluster "${K}/dev/cluster.yaml" --print-values | python3 -c '
import json, sys
for s in json.load(sys.stdin)["bootstrapSecrets"]:
    assert "kubectl" not in s["create"] and "bootstrap_secrets" in s["create"], s
    if s["name"] == "provider-infisical-creds":
        assert "client_id" in s["create"] and "client_secret" in s["create"], s' \
  && ok "eks: bootstrap Secrets point at Terraform, never kubectl" \
  || bad "eks: a bootstrap Secret still says kubectl create"
mkdir -p "${K}/badiss"
sed "s#issuer: ${ISS}/AAA1#issuer: https://hangarplatform.dev/oidc/eks-dev#" "${K}/dev/cluster.yaml" >"${K}/badiss/cluster.yaml"
python3 hack/check.py --cluster "${K}/badiss/cluster.yaml" >/dev/null 2>&1 && bad "eks: accepted a non-EKS issuer" \
  || ok "eks: refuses an issuer that is not the cluster's EKS issuer"
