#!/usr/bin/env bash
# tests/run.sh - offline tests for Apron's renderer and checks. No cluster, no network.
#
#   1. render: the lab pair (dev on kiac as hangar-dev, prod on kind as hangar-prod), the cross pair (dev on kind,
#      prod on kiac) and both profiles on an existing cluster with another SCM host/owner. Each must leave no @@, no
#      old cluster name, no hardcoded owner; every YAML must parse (if python3 has PyYAML) and every script `bash -n`.
#   2. re-render: a second render changes nothing; removing a component removes its files; cluster.yaml survives.
#   3. check: each invariant violation is refused.
#   4. TOKENS.md lists exactly the tokens templates use.
#   5. the AgentRun confinement policy admits a run's objects and refuses everything D15 forbids, and Clearance's
#      argo.sync.lower grant admits only a sync of a -lower Application (skipped without envtest binaries in
#      KUBEBUILDER_ASSETS: tests/policy/test_agentrun_grants.py, test_argo_sync.py).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
APRON="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
OLD='kind-dev|kiac-dev|kind-prod|kiac-prod|kind-man|kiac-man|kiac\.local|jfillman|gitops-cluster-dev\b|gitops-cluster-kind|192\.168\.1\.78|700017004810'
HAVE_YAML=false
python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=true

new() { # new DIR PROFILE NAME RUNTIME [more new_cluster.py flags]
  local dir="$1" profile="$2" name="$3" runtime="$4"; shift 4
  mkdir -p "${dir}"
  python3 hack/new_cluster.py --profile "${profile}" --name "${name}" --runtime "${runtime}" "$@" >"${dir}/cluster.yaml"
}

render_ok() { # render_ok DIR LABEL
  local dir="$1" label="$2" out
  if ! out="$(python3 hack/render.py --cluster "${dir}/cluster.yaml" 2>&1)"; then
    bad "${label}: render failed: ${out}"
    return
  fi
  ok "${label}: $(head -1 <<<"${out}" | sed 's/ into .*:/:/')"
  local leftovers olds
  leftovers="$(grep -rn '@@' "${dir}" --exclude=cluster.yaml | head -3)"
  [ -z "${leftovers}" ] && ok "${label}: no @@ left" || bad "${label}: leftover @@: ${leftovers}"
  olds="$(grep -rnE "${OLD}" "${dir}" | head -3)"
  [ -z "${olds}" ] && ok "${label}: no old cluster names, owner or lab addresses" || bad "${label}: old literals: ${olds}"
  if [ "${HAVE_YAML}" = true ]; then
    local yerr
    yerr="$(python3 - "${dir}" <<'PY'
import os, sys, yaml
bad = []
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        p = os.path.join(d, f)
        # Helm chart templates (Go templates) and ApplicationSet templates are not plain YAML.
        if not f.endswith((".yaml", ".yml")) or "/chart/templates/" in p or f.endswith(".tmpl.yaml"):
            continue
        try:
            list(yaml.safe_load_all(open(p)))
        except Exception as e:
            bad.append(f"{p}: {str(e).splitlines()[0]}")
print("\n".join(bad))
PY
)"
    [ -z "${yerr}" ] && ok "${label}: every YAML file parses" || bad "${label}: YAML: ${yerr}"
  fi
  local sh
  for sh in $(find "${dir}" -name '*.sh'); do
    bash -n "${sh}" && ok "${label}: bash -n ${sh#"${dir}"/}" || bad "${label}: bash -n ${sh}"
  done
}

expect() { # expect DIR LABEL WANT_PATH|!PATH ...
  local dir="$1" label="$2"; shift 2
  local p
  for p in "$@"; do
    if [[ "${p}" == !* ]]; then
      [ ! -e "${dir}/${p#!}" ] && ok "${label}: no ${p#!}" || bad "${label}: ${p#!} should not be rendered"
    else
      [ -e "${dir}/${p}" ] && ok "${label}: has ${p}" || bad "${label}: missing ${p}"
    fi
  done
}

has() { # has FILE REGEX LABEL
  grep -qE "$2" "$1" && ok "$3" || bad "$3 ($1 lacks /$2/)"
}

echo "== 1. render"
LAB="${TMP}/lab"
new "${LAB}/dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod
new "${LAB}/prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev
render_ok "${LAB}/dev" "dev/kiac"
render_ok "${LAB}/prod" "prod/kind"
expect "${LAB}/dev" "dev/kiac" 10-crds-operators/infisical/application.yaml 50-glidepath/glidepath-control-plane/values.yaml \
  00-bootstrap/cluster-identity/authentication-config.yaml 10-crds-operators/traefik/traefik.yaml \
  01-argocd-platform/argocd-apps-install/application.yaml '!hack/kind-config.yaml' '!66-tower-access' '!65-backstage'
expect "${LAB}/prod" "prod/kind" hack/kind-config.yaml 66-tower-access/rbac.yaml 10-crds-operators/traefik/traefik.yaml \
  10-crds-operators/external-secrets/secretstore-xr.yaml 01-argocd-platform/argocd-apps-install/application.yaml \
  '!10-crds-operators/infisical' '!50-glidepath' '!55-autopilot' '!65-backstage'
has "${LAB}/dev/00-bootstrap/cluster-identity/authentication-config.yaml" 'oidc/hangar-prod' "dev trusts prod's issuer"
has "${LAB}/dev/00-bootstrap/cluster-identity/authentication-config.yaml" 'namespace == "app-backstage-prod"' \
  "dev trusts Tower's namespace app-backstage-prod"
has "${LAB}/dev/50-glidepath/glidepath-control-plane/values.yaml" '^clusterName: hangar-dev$' "glidepath clusterName = name"
has "${LAB}/dev/60-gateway-routes/argocd-httproute.yaml" 'argocd\.hangar-dev\.local' "dev hostnames use <name>.local"
has "${LAB}/dev/60-gateway-routes/argocd-httproute.yaml" 'namespace: hangar-gateway' "routes attach to hangar-gateway"
has "${LAB}/prod/hack/kind-config.yaml" 'containerPort: 30080' "kind maps host 80 to Traefik's NodePort"
has "${LAB}/prod/10-crds-operators/traefik/traefik.yaml" 'nodePort: 30080' "Traefik NodePort matches kind mapping"
has "${LAB}/prod/20-service-catalog/airframe-service-catalog/application.yaml" 'xrds/dex.yaml' "prod gets the Dex XRD"
has "${LAB}/prod/10-crds-operators/crossplane/functions.yaml" 'function-dex' "prod gets function-dex"
has "${LAB}/prod/10-crds-operators/external-secrets/cluster-secret-store.yaml" 'hangar-dev\.local:31800/api' \
  "prod reaches the hub's Infisical"
has "${LAB}/prod/00-bootstrap/cluster-registry/application.yaml" 'gitops-cluster-hangar-dev' "prod reads the hub's fleet file"
# generated passwords land in the cluster repo, never the template's old values
has "${LAB}/dev/10-crds-operators/infisical/application.yaml" 'password: "[0-9a-f]{40}"' "Infisical passwords generated"
if grep -rqE '900bf58b|8826860c|6cf8f3dc|cbc9d507' "${LAB}" "${APRON}/templates"; then
  bad "an old committed password is still present"
else
  ok "no old committed password anywhere"
fi
d1="$(grep -h 'infisicalPgPassword' "${LAB}/dev/cluster.yaml")"
new "${TMP}/again" dev hangar-dev kiac --repo-url https://github.com/acme/x --scm-owner acme --tower-cluster hangar-prod
[ "${d1}" != "$(grep -h 'infisicalPgPassword' "${TMP}/again/cluster.yaml")" ] && ok "passwords differ per init" \
  || bad "two inits generated the same password"

X="${TMP}/cross"
new "${X}/dev" dev lab-a kind --repo-url https://github.com/acme/gitops-cluster-lab-a --scm-owner acme --tower-cluster lab-b
new "${X}/prod" prod lab-b kiac --repo-url https://github.com/acme/gitops-cluster-lab-b --scm-owner acme \
  --fleet-hub lab-a --fleet-repo-url https://github.com/acme/gitops-cluster-lab-a
render_ok "${X}/dev" "dev/kind (cross)"
render_ok "${X}/prod" "prod/kiac (cross)"
expect "${X}/dev" "dev/kind (cross)" hack/kind-config.yaml 10-crds-operators/infisical/application.yaml 50-glidepath
expect "${X}/prod" "prod/kiac (cross)" '!hack/kind-config.yaml' 66-tower-access '!50-glidepath'

E="${TMP}/existing"
new "${E}/dev" dev eks-dev existing --repo-url https://gitlab.example.com/org/gitops-eks-dev --scm-host gitlab.example.com \
  --scm-owner org --registry-owner org-images --tower-cluster eks-prod
new "${E}/prod" prod eks-prod existing --repo-url https://gitlab.example.com/org/gitops-eks-prod \
  --scm-host gitlab.example.com --scm-owner org --fleet-hub eks-dev --fleet-repo-url https://gitlab.example.com/org/gitops-eks-dev
render_ok "${E}/dev" "dev/existing"
render_ok "${E}/prod" "prod/existing"
has "${E}/prod/10-crds-operators/traefik/traefik.yaml" 'type: LoadBalancer' "existing: Traefik is a LoadBalancer"
has "${E}/dev/50-glidepath/glidepath-catalog/application.yaml" 'ghcr.io/org-images/airframe-validate' "registry owner flows"
has "${E}/dev/root-app-of-apps.yaml" 'https://gitlab.example.com/org/gitops-eks-dev' "repo URL flows"
# eks-dev sets registry owner org-images: nothing may fall back to the SCM owner or to github.com/ghcr.io/acme.
if grep -rqE '(github\.com|gitlab\.example\.com)/acme/|github\.com/org/|ghcr\.io/(org|acme)/' "${E}/dev"; then bad "existing: another owner/host leaked"; else ok "existing: only the configured SCM host/owner"; fi

# EKS (runtime eks, hangar-infra): three clusters, Infisical as its own service (no infisical.host anywhere), EKS's own
# issuers, Tower on the platform cluster trusted through an EKS OIDC identity provider config.
K="${TMP}/eks"
ISS=https://oidc.eks.us-east-1.amazonaws.com/id
INF=https://infisical.aws.example.dev/api
CERT=arn:aws:acm:us-east-1:111111111111:certificate/abc
eks_extra() { # eks_extra TOWER_ISSUER: the keys Terraform's apron_values output supplies
  printf 'traefik: {loadBalancer: {certificateArn: %s, sourceRanges: [203.0.113.7/32, 198.51.100.0/24]}}\n' "${CERT}"
  printf 'tower: {cluster: eks-man, issuer: %s}\n' "$1"
}
new "${K}/dev" dev eks-dev eks --repo-url https://github.com/acme/gitops-eks-dev --scm-owner acme \
  --domain eks-dev.aws.example.dev --set infisical.host=false --set "infisical.url=${INF}" --set "issuer=${ISS}/AAA1"
eks_extra "${ISS}/CCC3" >>"${K}/dev/cluster.yaml"
new "${K}/prod" prod eks-prod eks --repo-url https://github.com/acme/gitops-eks-prod --scm-owner acme \
  --domain eks-prod.aws.example.dev --fleet-hub eks-dev --fleet-repo-url https://github.com/acme/gitops-eks-dev \
  --set "infisical.url=${INF}" --set "issuer=${ISS}/BBB2" --set components.towerAccess=false \
  --set components.towerAccessHub=true --set fleet.relayUrl=https://relay.eks-dev.aws.example.dev
eks_extra "${ISS}/CCC3" >>"${K}/prod/cluster.yaml"
echo 'roles: [workloads]' >>"${K}/prod/cluster.yaml"
new "${K}/man" platform eks-man eks --repo-url https://github.com/acme/gitops-eks-man --scm-owner acme \
  --domain eks-man.aws.example.dev --fleet-hub eks-dev --fleet-repo-url https://github.com/acme/gitops-eks-dev \
  --set "infisical.url=${INF}" --set "issuer=${ISS}/CCC3" --set fleet.relayUrl=https://relay.eks-dev.aws.example.dev
eks_extra "${ISS}/CCC3" >>"${K}/man/cluster.yaml"
for c in dev prod man; do
  python3 hack/check.py --cluster "${K}/${c}/cluster.yaml" >/dev/null 2>"${TMP}/eks-check" \
    && ok "eks-${c}: passes check" || bad "eks-${c}: check: $(cat "${TMP}/eks-check")"
  render_ok "${K}/${c}" "eks-${c}"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" 'loadBalancerClass: service.k8s.aws/nlb' "eks-${c}: Traefik on the LBC's NLB"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" "aws-load-balancer-ssl-cert: ${CERT}" "eks-${c}: ACM cert on the NLB"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" 'loadBalancerSourceRanges: \["203\.0\.113\.7/32"' "eks-${c}: source ranges"
  expect "${K}/${c}" "eks-${c}" '!10-crds-operators/infisical' '!00-bootstrap/cluster-identity' '!10-crds-operators/metrics-server'
done
expect "${K}/dev" "eks-dev" 50-glidepath 55-autopilot 60-gateway-routes/glidepath-relay-httproute.yaml \
  60-gateway-routes/pac-webhook-httproute.yaml 00-bootstrap/backstage-ingestor-rbac/rbac.yaml \
  '!10-crds-operators/external-secrets/cluster-secret-store.yaml' '!10-crds-operators/external-secrets/secretstore-xr.yaml' \
  '!10-crds-operators/crossplane/provider-infisical-creds-external-secret.yaml'
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" "hostAPI: \"${INF}\"" "eks-dev: glidepath store reaches Infisical's URL"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" '^    auth: universal$' "eks-dev: glidepath store uses universal auth"
has "${K}/dev/00-bootstrap/backstage-ingestor-rbac/rbac.yaml" \
  'name: hangar:eks-man:system:serviceaccount:app-backstage-prod:backstage-ingestor' "eks-dev: Tower's EKS OIDC username"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" \
  'hangar:eks-man:system:serviceaccount:app-backstage-prod:tower-actor' "eks-dev: glidepath-api allows Tower's actor"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" "${ISS}/AAA1" "eks-dev: Fulcio trusts the EKS issuer"
has "${K}/dev/55-autopilot/gateway/autopilot-api.yaml" 'value: "https://autopilot\.eks-dev\.aws\.example\.dev"' "eks-dev: Clearance's URL over https"
has "${LAB}/dev/55-autopilot/gateway/autopilot-api.yaml" 'value: "http://autopilot\.hangar-dev\.local"' "lab: Clearance's URL stays http"
# R-10c/e: the gateway is autopilot-gateway (label, Deployment, SA, Service); the old `clearance` aliases (Service, host,
# principal, Application name) are gone since R-10e.
G="${LAB}/dev/55-autopilot/gateway"
has "${G}/gateway.yaml" '^  name: autopilot-gateway$' "lab: gateway Deployment is autopilot-gateway"
has "${G}/gateway.yaml" 'serviceAccountName: autopilot-gateway' "lab: gateway runs as SA autopilot-gateway"
has "${G}/gateway.yaml" 'selector: \{app.kubernetes.io/name: autopilot-gateway\}' "lab: Services select the new label"
has "${G}/gateway.yaml" 'gateway-v0.9.1@sha256:a0797bd4d75902d3cce91f11e8ac669c550121a6b3ca4f9aedd327b596afd5cc' "lab: gateway image pinned"
has "${G}/autopilot-api.yaml" 'gateway-v0.9.1@sha256:a0797bd4d75902d3cce91f11e8ac669c550121a6b3ca4f9aedd327b596afd5cc' "lab: read API on the same image"
has "${G}/autopilot-api.yaml" 'AUTOPILOT_GATEWAY_URL' "lab: read API uses AUTOPILOT_GATEWAY_URL"
if grep -rn 'app.kubernetes.io/name: clearance[},]' "${G}" >/dev/null; then bad "lab: a gateway object still carries the label clearance"; else ok "lab: no gateway object carries the label clearance"; fi
if grep -q '^  name: clearance$' "${G}/gateway.yaml"; then bad "lab: the clearance Service alias is still rendered"; else ok "lab: no clearance Service alias (R-10e)"; fi
if grep -q 'clearance\.hangar-dev\.local' "${G}/routes.yaml" "${G}/gateway.yaml"; then bad "lab: the gateway still answers on clearance.<domain>"; else ok "lab: the gateway's route and resource URL are autopilot.<domain> only"; fi
has "${G}/routes.yaml" '    - autopilot\.hangar-dev\.local' "lab: the gateway route's host is autopilot.<domain>"
has "${G}/application.yaml" '^  name: autopilot-gateway$' "lab: the Argo Application is autopilot-gateway"
if grep -rq 'autopilot-system:clearance\|autopilot-system/clearance\|name: clearance, namespace: autopilot-system' "${LAB}/dev/50-glidepath" "${LAB}/dev/55-autopilot" "${LAB}/dev/55-clearance"; then bad "lab: the old principal is still named"; else ok "lab: no list names the old principal"; fi
has "${G}/argo-sync.yaml" "autopilot-system:autopilot-gateway'" "lab: argo-sync admits the new principal"
has "${LAB}/dev/50-glidepath/glidepath-control-plane/values.yaml" 'system:serviceaccount:autopilot-system:autopilot-gateway' "lab: glidepath-api delegates the new principal"
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'principals": \["autopilot-system/autopilot-gateway"\]' "lab: the provider registers the gateway's principal only"
has "${LAB}/dev/10-crds-operators/crossplane/functions.yaml" 'function-agentrun@sha256:30324c992ab970427abe6a9f959c5d6199ab39bece35393593e9037932b065e9' "lab: function-agentrun v0.4.0"
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
mkdir -p "${K}/badiss"
sed "s#issuer: ${ISS}/AAA1#issuer: https://hangarplatform.dev/oidc/eks-dev#" "${K}/dev/cluster.yaml" >"${K}/badiss/cluster.yaml"
python3 hack/check.py --cluster "${K}/badiss/cluster.yaml" >/dev/null 2>&1 && bad "eks: accepted a non-EKS issuer" \
  || ok "eks: refuses an issuer that is not the cluster's EKS issuer"

# Flight admission (glidepath ADR-0029 phase 4): off by default; Audit+Warn when enabled; Deny + Flight pull when told.
expect "${LAB}/prod" "prod/kind" '!30-policy/kyverno-policies/flight-images.yaml'
has "${LAB}/prod/10-crds-operators/external-secrets/registry-credentials-cluster-external-secret.yaml" \
  'key: registry-credentials-dockerconfigjson' "prod pulls with the Ground credential by default"
F="${TMP}/flight"
mkdir -p "${F}/audit" "${F}/enforce" "${F}/incomplete"
FLIGHT_KEYS='registries: {flight: {host: ghcr.io, namespace: acme-flight}}
promotion: {promoter: {repo: acme-flight/flight-promoter}}'
{ cat "${LAB}/prod/cluster.yaml"; echo "${FLIGHT_KEYS}"; echo 'admission: {flight: {enabled: true}}'; } >"${F}/audit/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo "${FLIGHT_KEYS}"
  echo 'admission: {flight: {enabled: true, enforce: true, pullFromFlight: true}}'; } >"${F}/enforce/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'admission: {flight: {enabled: true}}'; } >"${F}/incomplete/cluster.yaml"
render_ok "${F}/audit" "prod flight audit"
render_ok "${F}/enforce" "prod flight enforce"
FP=30-policy/kyverno-policies/flight-images.yaml
has "${F}/audit/${FP}" "startsWith\('ghcr\.io/acme-flight/'\)" "flight: Flight prefix from registries.flight"
has "${F}/audit/${FP}" 'acme\\-flight/flight\\-promoter/\\\.github/workflows/promote' "flight: promoter identity from promotion.promoter.repo"
has "${F}/audit/${FP}" 'ghcr\.io/cloudnative-pg/' "flight: third-party allow list from the profile"
has "${F}/audit/${FP}" 'validationActions: \[Audit, Warn\]' "flight: audit by default"
has "${F}/enforce/${FP}" 'validationActions: \[Deny\]' "flight: enforce denies"
has "${F}/enforce/${FP}" 'failurePolicy: Fail' "flight: enforce fails closed"
has "${F}/enforce/10-crds-operators/external-secrets/registry-credentials-cluster-external-secret.yaml" \
  'key: flight-registry-read-dockerconfigjson' "flight: pullFromFlight swaps the tenant pull secret"
python3 hack/render.py --cluster "${F}/incomplete/cluster.yaml" >/dev/null 2>&1 \
  && bad "flight admission rendered without a Flight namespace or promoter" \
  || ok "refuses flight admission without a Flight namespace and promoter"
mkdir -p "${F}/dev"
{ cat "${LAB}/dev/cluster.yaml"; echo "${FLIGHT_KEYS}"; echo 'admission: {flight: {enabled: true}}'; } >"${F}/dev/cluster.yaml"
render_ok "${F}/dev" "dev flight keys"
expect "${F}/dev" "dev flight keys" "!${FP}"

echo "== 1a. signing PKI (C-2a: off by default; the flags render the public chain, the trusted root and Clearance's keyless wiring)"
SIGOFF="${LAB}/dev"
if grep -q '^sigstore:' "${SIGOFF}/50-glidepath/glidepath-control-plane/values.yaml"; then bad "signing off: managedKeys rendered"; else ok "signing off: the control plane keeps its bootstrap hooks"; fi
if grep -rq 'fulcio-server.fulcio-system\|keyless:' "${SIGOFF}/55-clearance"; then bad "signing off: keyless wiring rendered"; else ok "signing off: Clearance attests nothing"; fi
SG="${TMP}/signing"
new "${SG}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set signing.managedKeys=true --set signing.trustedRoot=true --set clearance.attestation.keyless=true
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "signing on without signing-pki/: rendered"; else
  ok "signing on without signing-pki/: refused ($(grep -o 'signing-pki/[a-z.-]* is missing' "${TMP}/sg-out" | head -1))"; fi
mkdir -p "${SG}/signing-pki"
printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
printf '{"mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1"}\n' >"${SG}/signing-pki/trusted-root.json"
render_ok "${SG}" "signing on"
V="${SG}/50-glidepath/glidepath-control-plane/values.yaml"
has "${V}" '^    enabled: true$' "signing on: sigstore.managedKeys.enabled"
has "${V}" '^    rootCaPem: "-----BEGIN CERTIFICATE-----\\nAAAA' "signing on: the chain is the cluster repo's fulcio-chain.pem"
has "${V}" '^    trustedRootJson: "\{' "signing on: the trusted root is published"
C="${SG}/55-clearance/clearance/application.yaml"
has "${C}" 'fulcioUrl: "http://fulcio-server.fulcio-system.svc"' "keyless: the in-cluster Fulcio"
has "${C}" 'rekorUrl: "http://rekor-server.rekor-system.svc"' "keyless: the in-cluster Rekor"
has "${C}" 'audience: "sigstore"' "keyless: the audience Fulcio's issuer entry expects"
has "${C}" 'kubernetes.io/metadata.name: fulcio-system' "keyless: egress to fulcio-system"
has "${C}" 'port: 5555' "keyless: egress on Fulcio's pod port"
has "${C}" 'port: 3000' "keyless: egress on Rekor's pod port"
printf -- '-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "a private key in signing-pki/: rendered"; else ok "a private key in signing-pki/: refused"; fi
printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
printf -- '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n' >"${SG}/signing-pki/root.pem"
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "a private key in another signing-pki/ file: rendered"; else ok "a private key in any signing-pki/ file: refused"; fi
# hack/build-trust-root.sh refuses a private key too, before it needs clearance
mkdir -p "${TMP}/bt/signing-pki"
for f in root.pem intermediate.pem rekor.pub legacy-fulcio-root.pem legacy-rekor.pub; do echo x >"${TMP}/bt/signing-pki/${f}"; done
echo '-----BEGIN PRIVATE KEY-----' >"${TMP}/bt/signing-pki/root.pem"
if hack/build-trust-root.sh "${TMP}/bt" --new-start 2026-11-10T00:00:00Z --legacy-end 2026-11-10T02:00:00Z >/dev/null 2>"${TMP}/bt-err"; then
  bad "build-trust-root.sh accepted a private key"; else ok "build-trust-root.sh refuses a private key: $(head -1 "${TMP}/bt-err" | cut -c1-70)"; fi

# Clearance gate (clearance G-ARGO-2, 56-clearance-gate): upper clusters only, off by default; Warn, then Deny + Allow->Deny.
expect "${LAB}/prod" "prod/kind" '!56-clearance-gate/admission.yaml'
G="${TMP}/gate"
mkdir -p "${G}/warn" "${G}/enforce" "${G}/dev"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111"}}'; } >"${G}/warn/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, agentServiceAccount: "clearance-system:the-agent"}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111"}}'; } >"${G}/enforce/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111"}}'; } >"${G}/dev/cluster.yaml"
render_ok "${G}/warn" "prod clearance gate warn"
render_ok "${G}/enforce" "prod clearance gate enforce"
render_ok "${G}/dev" "dev clearance gate key"
GP=56-clearance-gate/admission.yaml
expect "${G}/dev" "dev clearance gate key" "!${GP}"
has "${G}/warn/56-clearance-gate/application.yaml" 'path: 56-clearance-gate' "clearance gate: its own Application"
has "${G}/warn/56-clearance-gate/clearancegrant-crd.yaml" 'name: clearancegrants.clearance.hangar.io' "clearance gate: the ClearanceGrant CRD"
has "${G}/warn/${GP}" "== 'registry.invalid/clearance-wait@sha256:1{64}'" "clearance gate: the exemption pins the wait image from versions.clearance.waitImage"
has "${G}/warn/${GP}" 'validationActions: \[Warn, Audit\]' "clearance gate: Warn by default"
has "${G}/warn/${GP}" 'parameterNotFoundAction: Allow' "clearance gate: Warn allows a missing grant"
has "${G}/warn/${GP}" "== 'system:serviceaccount:argocd-apps:argocd-application-controller'" "clearance gate: matches Argo's controller only"
has "${G}/warn/${GP}" "== 'system:serviceaccount:clearance-system:clearance-argocd-agent'" "clearance gate: the agent is the only grant writer"
has "${G}/enforce/${GP}" 'validationActions: \[Deny, Audit\]' "clearance gate: enforce denies"
has "${G}/enforce/${GP}" 'parameterNotFoundAction: Deny' "clearance gate: enforce flips parameterNotFoundAction too"
has "${G}/enforce/${GP}" "clearance-system:the-agent'" "clearance gate: the agent account is configurable"
if out="$(python3 tests/policy/test_clearance_gate.py "${G}/warn" "${G}/enforce" 2>&1)"; then
  ok "clearance gate admission: $(tail -1 <<<"${out}")"
else
  bad "clearance gate admission: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi

echo "== 1b. the Argo CD gate (clearance.gate.enabled: the plugin sidecar and the ApplicationSet's plugin source)"
GATE_SET=(--set clearance.gate.enabled=true --set 'clearance.protectedEnvironments=[hangar-prod/prod]'
  --set versions.clearance.cmpImage=ghcr.io/acme/clearance-cmp@sha256:aaaa --set versions.clearance.waitImage=ghcr.io/acme/clearance-wait@sha256:bbbb)
new "${TMP}/gate" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local
render_ok "${TMP}/gate" "gate on"
AS="${TMP}/gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${AS}" 'name: clearance$' "gate on: the ApplicationSet has the Clearance plugin source"
has "${AS}" 'regexMatch "\^hangar\[-\]prod\[/\]prod\$"' "gate on: only clearance.protectedEnvironments are gated, as a regex with no backslash"
has "${AS}" 'name: valueFiles, string: "hangar-prod/base.yaml,hangar-prod/\{\{.env\}\}/values.yaml,hangar-prod/\{\{.env\}\}/release.yaml"' \
  "gate on: the plugin gets all three value files and skips absent ones (the Helm source's ignoreMissingValueFiles)"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'name: clearance-cmp' "gate on: repo-server has the plugin sidecar"
has "${AS}" 'regexMatch "\^\.\*\$" .appName' "gate on without gate.apps: every app in a protected environment"
[ ! -e "${TMP}/gate/56-clearance-gate/agent/application.yaml" ] && ok "gate on without gate.agent: no agent" || bad "gate on without gate.agent: the agent rendered"
new "${TMP}/gate-agent" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true
render_ok "${TMP}/gate-agent" "gate on with the agent, one app"
has "${TMP}/gate-agent/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" 'regexMatch "\^\(gate-api\)\$" .appName' "gate.apps: only that app gets the plugin"
has "${TMP}/gate-agent/30-policy/kyverno-policies/flight-images.yaml" 'ghcr.io/acme/clearance-wait@sha256:bbbb' "gate on: Flight admission allows exactly the wait image"
has "${TMP}/gate-agent/56-clearance-gate/agent/application.yaml" 'clearance-api.hangar-dev.local' "gate.agent: the agent's host alias names clearance-api"
has "${TMP}/gate-agent/01-argocd-platform/argocd-apps-install/application.yaml" 'hostAliases: \[\{"ip": "192.0.2.1"' "gate.hostAlias: the repo-server gets it"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'value: "http://clearance.hangar-dev.local"' "gate on: the sidecar reaches the core at clearance.gate.url"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'audience: clearance' "gate on: the clearance token is a projected, audience-bound service-account token"
if grep -n 'clearance-cmp\|name: clearance$' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml" "${TMP}/lab/prod/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" | grep -v '^[^:]*:[0-9]*: *#' | grep -q .; then
  bad "gate off: the plugin leaked into a cluster that did not ask for it"
else
  ok "gate off: no sidecar and no plugin source"
fi
new "${TMP}/gate-off" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set 'clearance.protectedEnvironments=[no-slash]'
render_ok "${TMP}/gate-off" "gate off with a protectedEnvironments entry the gate would refuse"
new "${TMP}/gate-noimg" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set clearance.gate.enabled=true \
  --set 'versions.clearance.cmpImage=' --set 'versions.clearance.waitImage='
if python3 hack/render.py --cluster "${TMP}/gate-noimg/cluster.yaml" >/dev/null 2>&1; then
  bad "gate on without the images rendered"
else
  ok "gate on without versions.clearance.cmpImage and waitImage is refused"
fi

echo "== 1c. the evidence ledger (clearance C-3): the log on the core's cluster, a witness on the protected one"
# Public keys only (clearance ledger keygen prints them): the log's verifier key and the witness's cosignature key.
LOGK='hangarplatform.dev/clearance/hangar-dev+108edc37+AetdxRXum9f4nBr0a6ahyidBM9om7vJErTsu6/TYqQkc'
WITK='hangarplatform.dev/witness/hangar-prod+df3c5653+BFmnD24M4mdUFnMP9nWpmurlGFfwfX3QK3zYcpjFtlEW'
WITNESS_IMG=ghcr.io/acme/clearance-witness@sha256:2222222222222222222222222222222222222222222222222222222222222222
LEDGER_SET=(--set clearance.ledger.enabled=true --set "clearance.ledger.witnesses=[{name: hangar-prod, vkey: ${WITK}, url: http://witness.hangar-prod.local}]"
  --set clearance.ledger.hostAlias=192.0.2.9=witness.hangar-prod.local)
WIT_SET=(--set clearance.witness.enabled=true --set clearance.witness.name=hangar-prod --set "clearance.witness.logsVkeys=[${LOGK}]"
  --set "versions.clearance.witnessImage=${WITNESS_IMG}" --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight
  --set promotion.promoter.repo=acme-flight/promoter --set admission.flight.enabled=true)
new "${TMP}/led-dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tower.hostAliasIP=192.0.2.5 "${LEDGER_SET[@]}"
new "${TMP}/led-dev-notower" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${LEDGER_SET[@]}" \
  --set clearance.ledger.quorum=all
new "${TMP}/led-prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${WIT_SET[@]}"
render_ok "${TMP}/led-dev" "ledger on (dev, with Tower's host alias)"
render_ok "${TMP}/led-dev-notower" "ledger on (dev, no Tower host alias)"
render_ok "${TMP}/led-prod" "witness on (prod)"
CA=55-clearance/clearance/application.yaml
has "${TMP}/led-dev/${CA}" '^        ledger:$' "ledger on: the chart's ledger values"
has "${TMP}/led-dev/${CA}" 'existingSecret: clearance-ledger-key' "ledger on: the log key is the Secret ledger-key.yaml makes"
has "${TMP}/led-dev/${CA}" 'witnessPolicy: "witness hangar-prod hangarplatform.dev/witness/hangar-prod\+df3c5653\+[A-Za-z0-9+/]+ http://witness.hangar-prod.local\\nquorum hangar-prod\\n"' \
  "ledger on: the policy is witness <name> <cosignature vkey> <url>, then quorum"
has "${TMP}/led-dev/${CA}" 'egress: \[\{"to": \[\{"ipBlock": \{"cidr": "192.0.2.9/32"\}\}\], "ports": \[\{"protocol": "TCP", "port": 80\}\]\}\]' \
  "ledger on: the core's egress reaches the witness's address and port only"
has "${TMP}/led-dev/${CA}" 'hostAliases: \[\{ip: "192.0.2.5", hostnames: \["backstage.hangar-prod.local"\]\}, \{"ip": "192.0.2.9", "hostnames": \["witness.hangar-prod.local"\]\}\]' \
  "ledger on: the core keeps Tower's host alias and gains the witness's"
# Tower and the witness on one address: one hostAliases entry, because Kubernetes merges them by ip.
LEDGER_SAME_IP=("${LEDGER_SET[@]/192.0.2.9/192.0.2.5}")
new "${TMP}/led-dev-sameip" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tower.hostAliasIP=192.0.2.5 "${LEDGER_SAME_IP[@]}"
render_ok "${TMP}/led-dev-sameip" "ledger on (dev, the witness on Tower's address)"
has "${TMP}/led-dev-sameip/${CA}" 'hostAliases: \[\{ip: "192.0.2.5", hostnames: \["backstage.hangar-prod.local", "witness.hangar-prod.local"\]\}\]' "same address as Tower: one entry with both hostnames"
has "${TMP}/led-dev-notower/${CA}" 'hostAliases: \[\{"ip": "192.0.2.9", "hostnames": \["witness.hangar-prod.local"\]\}\]' "ledger on without Tower's alias: the core gets the witness's"
has "${TMP}/led-dev/55-clearance/clearance-config/ledger-key.yaml" 'key: hangar-ledger-hangar-dev-key' "ledger on: the key is Infisical's hangar-ledger-<cluster>-key by default"
has "${TMP}/led-dev/55-clearance/clearance-config/ledger-key.yaml" 'secretKey: ledger-key' "ledger on: the Secret has the key the chart mounts"
expect "${TMP}/led-dev" "ledger on" 55-clearance/clearance-config/ledger-key.yaml '!56-clearance-witness'
WD=56-clearance-witness
expect "${TMP}/led-prod" "witness on" ${WD}/application.yaml ${WD}/witness.yaml ${WD}/routes.yaml '!55-clearance/clearance-config/ledger-key.yaml'
has "${TMP}/led-prod/${WD}/witness.yaml" "image: ${WITNESS_IMG}" "witness on: the pinned image"
has "${TMP}/led-prod/${WD}/witness.yaml" '^    type: Recreate$' "witness on: Recreate (one replica, one claim)"
has "${TMP}/led-prod/${WD}/witness.yaml" 'key: hangar-witness-hangar-prod-key' "witness on: the key is Infisical's hangar-witness-<cluster>-key by default"
has "${TMP}/led-prod/${WD}/witness.yaml" 'secretKey: witness-key' "witness on: the Secret has the key the witness reads"
has "${TMP}/led-prod/${WD}/witness.yaml" '[-][-]logs-file=/etc/clearance-witness/config/logs' "witness on: the flags the chart passes"
has "${TMP}/led-prod/${WD}/witness.yaml" '^  logs: "hangarplatform.dev/clearance/hangar-dev\+108edc37\+' "witness on: the log's public key in the ConfigMap"
has "${TMP}/led-prod/${WD}/witness.yaml" '^  egress: \[\]$' "witness on: no egress at all"
has "${TMP}/led-prod/${WD}/witness.yaml" 'pod-security.kubernetes.io/enforce: restricted' "witness on: restricted namespace"
has "${TMP}/led-prod/${WD}/routes.yaml" '^    - witness.hangar-prod.local$' "witness on: the route's host is witness.<domain>"
has "${TMP}/led-prod/${WD}/routes.yaml" 'value: /add-checkpoint' "witness on: the route carries add-checkpoint"
has "${TMP}/led-prod/30-policy/kyverno-policies/flight-images.yaml" "\"${WITNESS_IMG}\"\]'" "witness on: Flight admission allows exactly the witness image"
if grep -rnE 'PRIVATE KEY|AGE-SECRET-KEY|PRIVATE\+KEY\+' "${TMP}/led-dev" "${TMP}/led-prod" >/dev/null; then bad "ledger/witness: key material in a render"; else ok "ledger/witness: no private key material in a render"; fi
echo "== 1c-2. the Kubernetes audit collector (clearance O-3)"
OBS_SET=(--set clearance.observe.enabled=true --set 'clearance.observe.protectedNamespaces=[app-a-prod]' --set 'clearance.observe.kubeletNodes=[node-a]' --set clearance.observe.serviceIP=10.96.200.50
  --set versions.clearance.observeK8sImage=ghcr.io/acme/clearance-observe-k8s@sha256:3333333333333333333333333333333333333333333333333333333333333333)
new "${TMP}/obs-prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${OBS_SET[@]}"
render_ok "${TMP}/obs-prod" "collector on"
OA="${TMP}/obs-prod/57-clearance-observe/application.yaml"
has "${OA}" 'tag: "v[0-9.]+@sha256:[0-9a-f]{64}"' "collector on: the image is pinned by digest"
has "${OA}" 'clusterIP: "10.96.200.50"' "collector on: the pinned ClusterIP"
has "${OA}" 'kubeletNodes: \["node-a"\]' "collector on: the kubelet nodes"
has "${OA}" 'namespace: argocd-apps$' "collector on: the Argo CD namespace"
has "${OA}" 'system:serviceaccount:argocd-apps:argocd-application-controller' "collector on: that instance's controller"
expect "${TMP}/led-prod" "collector off" '!57-clearance-observe/application.yaml'
new "${TMP}/obs-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set clearance.observe.enabled=true --set 'clearance.observe.protectedNamespaces=[app-a-prod]'
# Capture first: under pipefail, the render's own exit 1 would fail a `render | grep` even when grep matches.
OBS_ERR="$(python3 hack/render.py --cluster "${TMP}/obs-bad/cluster.yaml" 2>&1 || true)"
grep -q 'clearance.observe.serviceIP is required' <<<"${OBS_ERR}" && ok "collector on without a serviceIP refuses" || bad "collector on without a serviceIP should be refused by name: ${OBS_ERR}"
echo "== 1c-3. the AWS collector (clearance observe-aws)"
AWS_IMG=ghcr.io/acme/clearance-observe-aws@sha256:4444444444444444444444444444444444444444444444444444444444444444
AWS_SET=(--set clearance.observeAWS.enabled=true --set clearance.observeAWS.account=111122223333 --set clearance.observeAWS.queueURL=https://sqs.us-east-1.amazonaws.com/111122223333/observe
  --set clearance.observeAWS.roleARN=arn:aws:iam::111122223333:role/observe --set 'clearance.observeAWS.applyRoles=[deployer]'
  --set 'clearance.observeAWS.governedAccounts=[444455556666]' --set 'clearance.extraAuditors=[clearance-system/clearance-observe-aws]'
  --set versions.clearance.observeAWSImage="${AWS_IMG}")
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
EXPECT_PROD='{"targets": [{"app": "gate-api", "env": "prod", "gates": [{"instance": "app-gate-api-cicd/pipeline-runner", "mode": "enforce", "type": "glidepath"}, {"instance": "argocd-agent", "mode": "flag", "type": "g-argo"}], "group": "hangar-prod", "id": "hangar-prod.app-gate-api-prod", "kind": "k8s-namespace", "name": "app-gate-api-prod", "observers": [{"provider": "observe-k8s", "source": "observe-k8s"}], "owner": "group:default/team-gate", "registry": "flight", "scope": "hangar-prod"}]}'
[ "$(targets_json "${TMP}/tgt-prod")" = "${EXPECT_PROD}" ] && ok "targets (prod): the protected namespace, its Glidepath and Argo CD gates (warn mode: flag), the audit collector, Flight, scope = the cluster" || bad "targets (prod): unexpected set: $(targets_json "${TMP}/tgt-prod")"
has "${TP}" 'value: "http://clearance.hangar-dev.local"' "targets (prod): publishes to the core as the gate reaches it"
has "${TP}" 'value: "hangar-prod"' "targets (prod): the source is the cluster"
has "${TP}" 'path: clearance, audience: clearance' "targets (prod): a projected token for audience clearance, minted per run"
has "${TP}" 'hostAliases: \[\{"ip": "192.0.2.1"' "targets (prod): the hub's address through the host alias"
has "${TP}" 'cidr": "192.0.2.1/32"' "targets (prod): egress to the core's address only"
has "${TP}" 'schedule: "\*/15 \* \* \* \*"' "targets (prod): every 15 minutes"
if grep -qE 'automountServiceAccountToken: true|hostNetwork|privileged: true' "${TP}"; then bad "targets (prod): the publisher is not locked down"; else ok "targets (prod): the Job mounts no default token, no host network, no privilege"; fi
has "${TMP}/tgt-prod/59-clearance-targets/application.yaml" 'path: 59-clearance-targets' "targets (prod): its own Application"
# enforce mode flips the Argo CD gate's declared mode; an unprotected environment's Glidepath gate flags
mkdir -p "${TMP}/tgt-prod-enf"
python3 - "${TMP}/tgt-prod/cluster.yaml" "${TMP}/tgt-prod-enf/cluster.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
c["clearance"]["gate"]["enforce"] = True
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
EXPECT_DEV='{"targets": [{"env": "lab", "gates": [{"instance": "github:repo:acme/infra:ref:refs/heads/main", "mode": "enforce", "type": "g-tf"}], "group": "111122223333", "id": "aws.111122223333", "kind": "aws-account", "name": "aws-lab", "observers": [{"provider": "observe-aws", "source": "observe-aws"}], "owner": "group:default/admins", "scope": "111122223333"}, {"gates": [], "group": "hangar-dev", "id": "hangar-dev.observe-rehearsal", "kind": "k8s-namespace", "name": "observe-rehearsal", "observers": [{"provider": "observe-k8s", "source": "observe-k8s"}], "registry": "ground", "scope": "hangar-dev"}]}'
[ "$(targets_json "${TMP}/tgt-dev")" = "${EXPECT_DEV}" ] && ok "targets (dev): the AWS account (scope = the account, G-TF from cluster.yaml) and the rehearsal namespace (no app: no gates), Ground" || bad "targets (dev): unexpected set: $(targets_json "${TMP}/tgt-dev")"
TC="${TMP}/tgt-dev/55-clearance/clearance/application.yaml"
has "${TMP}/tgt-dev/55-clearance/clearance-config/routes.yaml" 'value: "\^/v1/targets/\[a-z0-9\]\[a-z0-9-\]\*\$"' "targets (dev): the Gateway routes a remote publisher's PUT /v1/targets/<source> to the core"
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
# Off by default, and keys present but off render what absent keys render.
new "${TMP}/led-abs" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set versions.clearance.witnessImage=
mkdir -p "${TMP}/led-offprod" "${TMP}/led-offdev"
cp "${LAB}/prod/cluster.yaml" "${TMP}/led-offprod/cluster.yaml"
printf 'clearance:\n  ledger: {enabled: false}\n  witness: {enabled: false}\n' >>"${TMP}/led-offprod/cluster.yaml"
cp "${LAB}/dev/cluster.yaml" "${TMP}/led-offdev/cluster.yaml"
printf 'clearance:\n  ledger: {enabled: false}\n  witness: {enabled: false}\n' >>"${TMP}/led-offdev/cluster.yaml"
render_ok "${TMP}/led-offprod" "ledger and witness explicitly off (prod)"
render_ok "${TMP}/led-offdev" "ledger and witness explicitly off (dev)"
expect "${TMP}/led-offprod" "witness off" '!56-clearance-witness'
expect "${TMP}/led-offdev" "ledger off" '!55-clearance/clearance-config/ledger-key.yaml'
if grep -rnE 'ledger|witness' "${TMP}/led-offdev/${CA}" "${TMP}/led-offprod/30-policy/kyverno-policies/flight-images.yaml" 2>/dev/null | grep -v '^[^:]*:[0-9]*: *#' | grep -q .; then
  bad "ledger/witness off: a value leaked into the core's Application or Flight admission"
else
  ok "ledger/witness off: nothing in the core's Application or Flight admission"
fi
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/led-offdev" >/dev/null; then ok "ledger/witness keys off == absent (dev), byte for byte"; else bad "ledger/witness off differs from absent (dev)"; fi
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/prod" "${TMP}/led-offprod" >/dev/null; then ok "ledger/witness keys off == absent (prod), byte for byte"; else bad "ledger/witness off differs from absent (prod)"; fi
# Refusals: render-time (image) and check-time.
new "${TMP}/led-noimg" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${WIT_SET[@]}" --set 'versions.clearance.witnessImage='
if python3 hack/render.py --cluster "${TMP}/led-noimg/cluster.yaml" >/dev/null 2>&1; then bad "witness on without versions.clearance.witnessImage rendered"; else ok "witness on without versions.clearance.witnessImage is refused"; fi

# Cloud-target providers: each of iam/ec2/rds/azure drops on its own (components.crossplane.*); the rest stay.
CT="${TMP}/cloudtargets"
new "${CT}/on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set components.cloudTargets=true --set 'aws.accountId="123456789012"'
new "${CT}/off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set components.cloudTargets=true --set 'aws.accountId="123456789012"' \
  --set components.crossplane.awsIam=false --set components.crossplane.awsEc2=false \
  --set components.crossplane.awsRds=false --set components.crossplane.azure=false
render_ok "${CT}/on" "cloudTargets/all providers"
render_ok "${CT}/off" "cloudTargets/trimmed providers"
CR=10-crds-operators/crossplane
expect "${CT}/on" "cloudTargets/all" ${CR}/provider-aws-iam.yaml ${CR}/provider-aws-ec2.yaml ${CR}/provider-aws-rds.yaml \
  ${CR}/provider-azure.yaml ${CR}/provider-azure-config.yaml ${CR}/provider-cloud-runtime.yaml
expect "${CT}/off" "cloudTargets/trimmed" !${CR}/provider-aws-iam.yaml !${CR}/provider-aws-ec2.yaml !${CR}/provider-aws-rds.yaml \
  !${CR}/provider-azure.yaml !${CR}/provider-azure-config.yaml !${CR}/provider-azure-creds-external-secret.yaml \
  !${CR}/provider-cloud-runtime.yaml ${CR}/provider-aws-runtime.yaml ${CR}/provider-aws-config.yaml
grep -rq 'name: provider-aws-ecr$' "${CT}/off/${CR}" && grep -rq 'name: provider-aws-sqs$' "${CT}/off/${CR}" \
  && grep -rq 'name: provider-family-aws$' "${CT}/off/${CR}" && ok "cloudTargets/trimmed: ecr, ecs, lambda, s3, sqs and the AWS family stay" \
  || bad "cloudTargets/trimmed: a kept provider is missing"
! grep -rqE 'name: provider-(aws-iam|aws-ec2|aws-rds|family-azure|azure-containerapp)$' "${CT}/off/${CR}" \
  && ok "cloudTargets/trimmed: no iam/ec2/rds/azure Provider rendered" || bad "cloudTargets/trimmed: a dropped provider is still rendered"
grep -rq 'name: provider-aws-iam$' "${CT}/on/${CR}" && grep -rq 'name: provider-azure-containerapp$' "${CT}/on/${CR}" \
  && ok "cloudTargets/all: iam and azure Providers rendered" || bad "cloudTargets/all: a provider is missing"

echo "== 2. re-render"
out="$(python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml")"
grep -q '0 added, 0 changed, 0 removed' <<<"${out}" && ok "second render changes nothing" || bad "re-render not idempotent: ${out}"
cp "${LAB}/dev/cluster.yaml" "${TMP}/before.yaml"
echo 'components: {aiTriage: false}' >>"${LAB}/dev/cluster.yaml"
out="$(python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml")"
grep -q 'removed  70-ai-triage' <<<"${out}" && [ ! -e "${LAB}/dev/70-ai-triage" ] && ok "turning a component off removes its files" \
  || bad "component removal: ${out}"
grep -q 'aiTriage: false' "${LAB}/dev/cluster.yaml" && ok "cluster.yaml left alone" || bad "cluster.yaml was rewritten"
cp "${TMP}/before.yaml" "${LAB}/dev/cluster.yaml"
python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" >/dev/null && [ -e "${LAB}/dev/70-ai-triage" ] \
  && ok "turning it back on restores them" || bad "component restore"
python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --print-values >"${TMP}/v.json" \
  && python3 - "${TMP}/v.json" <<'PY' && ok "--print-values has the CLI keys and no secrets" || bad "--print-values"
import json, sys
v = json.load(open(sys.argv[1]))
for k in ("name", "profile", "context", "domain", "issuerBase", "scm", "registry", "infisical", "runtime", "argocd",
          "rootApp", "bootstrapSecrets", "hostnames"):
    assert k in v, k
assert v["context"] == v["name"] == "hangar-dev"
assert v["runtime"]["type"] == "kiac" and "cni" not in v
assert "generated" not in v and "Password" not in json.dumps(v)
names = {(s["namespace"], s["name"]) for s in v["bootstrapSecrets"]}
assert ("infisical", "infisical-secrets") in names and ("infisical", "infisical-bootstrap-credentials") in names
PY

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

echo "== 3. check refuses"
refuse() { # refuse LABEL BASE-DIR YAML-TO-APPEND...
  local label="$1" base="$2"; shift 2
  local d="${TMP}/refuse-$((RANDOM))"
  mkdir -p "${d}"
  cp "${base}/cluster.yaml" "${d}/cluster.yaml"
  printf '%s\n' "$@" >>"${d}/cluster.yaml"
  if python3 hack/check.py --cluster "${d}/cluster.yaml" >/dev/null 2>"${d}/err"; then
    bad "check accepted: ${label}"
  else
    ok "refuses ${label}: $(head -1 "${d}/err" | cut -c8-110)"
  fi
}
python3 hack/check.py --cluster "${LAB}/dev/cluster.yaml" >/dev/null && ok "lab dev passes" || bad "lab dev fails check"
python3 hack/check.py --cluster "${LAB}/prod/cluster.yaml" >/dev/null && ok "lab prod passes" || bad "lab prod fails check"
P="${LAB}/prod"
D="${LAB}/dev"
refuse "web on over http" "${D}" 'clearance: {web: {enabled: true}}' 'gateway: {scheme: http}'
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

echo "== 4. tokens"
missing="$(DEVCFG="${LAB}/dev/cluster.yaml" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, "hack")
from render import tokens
from apronlib import resolve
doc = set(re.findall(r"@@([A-Z0-9_]+)@@", open("templates/TOKENS.md").read())) - {"TOKEN"}
used = set()
for d, _, fs in os.walk("templates"):
    for f in fs:
        if f != "TOKENS.md":
            used |= set(re.findall(r"@@([A-Z0-9_]+)@@", open(os.path.join(d, f)).read()))
known = set(tokens(resolve(sys.argv[1] if len(sys.argv) > 1 else os.environ["DEVCFG"])).keys())
out = []
if used - doc: out.append("undocumented: " + " ".join(sorted(used - doc)))
if doc - used: out.append("documented but unused: " + " ".join(sorted(doc - used)))
if used - known: out.append("unknown to render.py: " + " ".join(sorted(used - known)))
print("; ".join(out))
PY
)" 2>&1
[ -z "${missing}" ] && ok "TOKENS.md, templates and render.py agree" || bad "tokens: ${missing}"

echo "== 1d. control-plane tuning (hack/control-plane-tuning.sh against a fake node and kubectl; kind-config patch)"
CPT="${APRON}/hack/control-plane-tuning.sh"; CPF="${APRON}/tests/control-plane"
has "${LAB}/prod/hack/kind-config.yaml" 'name: leader-elect-lease-duration' "kind config patches the leader-election lease"
has "${LAB}/prod/hack/kind-config.yaml" 'value: "60s"' "kind config: lease 60s"
has "${LAB}/prod/hack/kind-config.yaml" 'value: "40s"' "kind config: renew 40s"
has "${LAB}/prod/hack/kind-config.yaml" 'value: "10s"' "kind config: retry 10s"
has "${LAB}/prod/hack/kind-config.yaml" '^        scheduler:$' "kind config: the scheduler gets the same args"
has "${LAB}/prod/hack/kind-config.yaml" '^        controllerManager:$' "kind config: the controller manager gets them"
if "${HAVE_YAML}"; then
  python3 - "${LAB}/prod/hack/kind-config.yaml" <<'PY' && ok "kind config: patch parses as a ClusterConfiguration with both components" || bad "kind config: ClusterConfiguration patch malformed"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
patches = [yaml.safe_load(p) for p in cfg["nodes"][0]["kubeadmConfigPatches"]]
cc = next(p for p in patches if p["kind"] == "ClusterConfiguration")
for comp in ("controllerManager", "scheduler"):
    got = {a["name"]: a["value"] for a in cc[comp]["extraArgs"]}
    assert got == {"leader-elect-lease-duration": "60s", "leader-elect-renew-deadline": "40s",
                   "leader-elect-retry-period": "10s"}, (comp, got)
PY
fi
out="$("${CPT}" render 2>&1)"
for f in --leader-elect-lease-duration=60s --leader-elect-renew-deadline=40s --leader-elect-retry-period=10s; do
  grep -qF -- "${f}" <<<"${out}" && ok "render prints ${f}" || bad "render lacks ${f}"
done
grep -q '^scheduler:$' <<<"${out}" && grep -q '^controllerManager:$' <<<"${out}" && ok "render prints the kubeadm patch for both components" \
  || bad "render: kubeadm patch missing a component"
out="$("${CPT}" render --lease-duration 30s --renew-deadline 20s --retry-period 5s)"
grep -qF -- '--leader-elect-lease-duration=30s' <<<"${out}" \
  && ok "render honours --lease-duration" || bad "render ignored --lease-duration"
"${CPT}" render --lease-duration 20s --renew-deadline 20s >/dev/null 2>&1 && bad "render accepted renew >= lease" || ok "render refuses renew >= lease"
"${CPT}" render --renew-deadline 40s --retry-period 40s >/dev/null 2>&1 && bad "render accepted retry >= renew" || ok "render refuses retry >= renew"
"${CPT}" render --lease-duration 1m >/dev/null 2>&1 && bad "render accepted 1m" || ok "render refuses a non Ns duration"
if [ -x "$(command -v jq)" ] && "${HAVE_YAML}"; then
  out="$("${CPT}" render --cluster-dir "${LAB}/prod" 2>&1)"
  grep -qF -- '--leader-elect-lease-duration=60s' <<<"${out}" \
    && ok "render --cluster-dir reads runtime.controlPlane.leaderElection" || bad "render --cluster-dir"
fi

cpt_world() { # cpt_world DIR [hostname]: a fake node root, kubectl state and PATH shim in DIR
  local d="$1" host="${2:-fake-cp}"
  rm -rf "${d}"; mkdir -p "${d}/root/etc/kubernetes/manifests" "${d}/state" "${d}/bin"
  cp "${CPF}/kube-scheduler.yaml" "${CPF}/kube-controller-manager.yaml" "${d}/root/etc/kubernetes/manifests/"
  echo "${host}" >"${d}/root/etc/hostname"
  echo fakectx >"${d}/state/contexts"; echo "node/fake-cp" >"${d}/state/nodes"
  cp "${CPF}/fake-kubectl" "${d}/bin/kubectl"
  cpt_pods "${d}" up
}
cpt_pods() { # cpt_pods DIR up|noflags: the pods' and leases' state as the fake kubectl reports it
  local d="$1" mode="$2" c cmd now
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
  for c in scheduler controller-manager; do
    cmd='["kube-'"${c}"'","--leader-elect=true"]'
    [ "${mode}" != up ] || cmd='["kube-'"${c}"'","--leader-elect=true","--leader-elect-lease-duration=60s"]'
    echo '{"spec":{"containers":[{"command":'"${cmd}"'}]},"status":{"conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"restartCount":3,"state":{"running":{"startedAt":"2999-01-01T00:00:00Z"}}}]}}' \
      >"${d}/state/pod-kube-${c}-fake-cp.json"
    echo '{"spec":{"leaseDurationSeconds":60,"holderIdentity":"fake-cp_abc","leaseTransitions":7,"renewTime":"'"${now}"'"}}' \
      >"${d}/state/lease-kube-${c}.json"
  done
}
cpt() { # cpt DIR ARGS...: run the script against world DIR
  local d="$1"; shift
  PATH="${d}/bin:${PATH}" FAKE_ROOT="${d}/root" FAKE_STATE="${d}/state" HOLD_MINUTES=0 POLL_SECONDS=0 WAIT_SECONDS=1 ACQUIRE_SECONDS=1 \
    "${CPT}" "$@" --cluster fakectx --node-exec "${CPF}/fake-node"
}
MAN=etc/kubernetes/manifests
if python3 -c 'import yaml' 2>/dev/null && command -v jq >/dev/null; then
  W="${TMP}/cpt"
  cpt_world "${W}"
  before="$(cat "${W}/root/${MAN}"/*.yaml | shasum)"
  out="$(cpt "${W}" plan 2>&1)"; rc=$?
  [ ${rc} -eq 0 ] && ok "plan on a fixture exits 0" || bad "plan failed: ${out}"
  want='+    - --leader-elect-retry-period=10s'
  grep -qxF -- "${want}" <<<"${out}" && ok "plan shows the added lines" || bad "plan lacks '${want}'"
  [ "$(grep -c '^+    - --leader-elect-' <<<"${out}")" = 6 ] && ok "plan adds exactly 3 flags to each of the 2 manifests" \
    || bad "plan: expected 6 added flag lines, got $(grep -c '^+    - --leader-elect-' <<<"${out}")"
  [ "$(grep -c '^-    - ' <<<"${out}")" = 0 ] && ok "plan removes nothing" || bad "plan removes lines"
  grep -q 'kube-apiserver\|etcd' <<<"${out}" && bad "plan mentions the API server or etcd" || ok "plan never touches the API server or etcd"
  [ "${before}" = "$(cat "${W}/root/${MAN}"/*.yaml | shasum)" ] && [ ! -e "${W}/root/etc/kubernetes/hangar-backup" ] \
    && ok "plan writes nothing (manifests unchanged, no backup dir)" || bad "plan changed the node"
  [ "$(cpt "${W}" 2>&1 | grep -c '^+    - --leader-elect-')" = 6 ] && ok "no command defaults to plan" || bad "default command is not plan"

  # refusals: identity, context, nodes, conflicting values, disabled leader election
  cpt_world "${W}" other-node
  out="$(cpt "${W}" plan 2>&1)" && bad "plan accepted a node whose hostname is not the cluster's" \
    || { grep -q 'identity mismatch' <<<"${out}" && ok "refuses a --node-exec that reaches another node" || bad "identity refusal text: ${out}"; }
  cpt_world "${W}"; : >"${W}/state/contexts"
  out="$(cpt "${W}" plan 2>&1)" && bad "plan accepted a missing context" || { grep -q 'no kubectl context' <<<"${out}" && ok "refuses a context that does not exist" || bad "context refusal text: ${out}"; }
  cpt_world "${W}"; echo "node/second-cp" >>"${W}/state/nodes"
  out="$(cpt "${W}" plan 2>&1)" && bad "plan accepted two control-plane nodes" || { grep -q 'exactly one' <<<"${out}" && ok "refuses more than one control-plane node" || bad "node count refusal text: ${out}"; }
  cpt_world "${W}"
  sed -i.bak 's/--leader-elect=true/--leader-elect=true\n    - --leader-elect-lease-duration=30s/' "${W}/root/${MAN}/kube-controller-manager.yaml"; rm -f "${W}/root/${MAN}"/*.bak
  before="$(cat "${W}/root/${MAN}"/*.yaml | shasum)"
  out="$(cpt "${W}" apply --yes 2>&1)" && bad "apply accepted a different existing value" \
    || { grep -q 'already set to' <<<"${out}" && ok "refuses a flag already set to a different value" || bad "conflict refusal text: ${out}"; }
  [ "${before}" = "$(cat "${W}/root/${MAN}"/*.yaml | shasum)" ] && [ ! -e "${W}/root/etc/kubernetes/hangar-backup" ] \
    && ok "a conflict on one component leaves both untouched" || bad "a conflict still changed a manifest"
  cpt_world "${W}"
  sed -i.bak 's/--leader-elect=true/--leader-elect=false/' "${W}/root/${MAN}/kube-scheduler.yaml"; rm -f "${W}/root/${MAN}"/*.bak
  cpt "${W}" plan >/dev/null 2>&1 && bad "plan accepted --leader-elect=false" || ok "refuses --leader-elect=false"

  # apply: backup, edit, wait, hold; idempotent; verify; rollback
  cpt_world "${W}"
  orig_s="$(cat "${W}/root/${MAN}/kube-scheduler.yaml")"; orig_c="$(cat "${W}/root/${MAN}/kube-controller-manager.yaml")"
  out="$(cpt "${W}" apply 2>&1)"; grep -q 'plan only' <<<"${out}" && [ "${orig_s}" = "$(cat "${W}/root/${MAN}/kube-scheduler.yaml")" ] \
    && ok "apply without --yes only plans" || bad "apply without --yes changed the node"
  out="$(cpt "${W}" apply --yes 2>&1)"; rc=$?
  [ ${rc} -eq 0 ] && ok "apply --yes succeeds when the pods come back with the flags and hold their leases" || bad "apply failed: ${out}"
  for c in scheduler controller-manager; do
    grep -q -- '--leader-elect-lease-duration=60s' "${W}/root/${MAN}/kube-${c}.yaml" && ok "${c}: manifest carries the flags" || bad "${c}: manifest lacks the flags"
    [ "$(ls "${W}/root/etc/kubernetes/hangar-backup" | grep -c "^kube-${c}\.yaml\.[0-9]\{8\}T[0-9]\{6\}Z$")" = 1 ] \
      && ok "${c}: one timestamped backup outside manifests/" || bad "${c}: backup missing"
  done
  [ "$(ls "${W}/root/${MAN}" | wc -l | tr -d ' ')" = 2 ] && ok "nothing but the two manifests in manifests/" || bad "stray files in manifests/"
  cmp -s "${W}/root/etc/kubernetes/hangar-backup/$(ls "${W}/root/etc/kubernetes/hangar-backup" | grep '^kube-scheduler\.yaml\.[0-9]')" <(printf '%s\n' "${orig_s}") \
    && ok "the backup is the original manifest" || bad "backup differs from the original"
  python3 - "${W}/root/${MAN}/kube-scheduler.yaml" "${CPF}/kube-scheduler.yaml" <<'PY' && ok "the edit changes only the command list" || bad "the edit changed more than the command list"
import sys, yaml
new, old = (yaml.safe_load(open(f)) for f in sys.argv[1:3])
assert new["spec"]["containers"][0]["command"][:6] == old["spec"]["containers"][0]["command"]
new["spec"]["containers"][0]["command"] = old["spec"]["containers"][0]["command"]
assert new == old
PY
  out="$(cpt "${W}" apply --yes 2>&1)"; grep -q 'already set everywhere' <<<"${out}" && ok "apply is idempotent" || bad "second apply: ${out}"
  [ "$(ls "${W}/root/etc/kubernetes/hangar-backup" | wc -l | tr -d ' ')" = 2 ] && ok "the no-op apply made no new backup" || bad "no-op apply made a backup"
  cpt "${W}" verify >/dev/null 2>&1 && ok "verify passes on a tuned node" || bad "verify failed on a tuned node"
  out="$(cpt "${W}" rollback 2>&1)"; grep -q 'plan only' <<<"${out}" && grep -q -- '--leader-elect-lease-duration=60s' "${W}/root/${MAN}/kube-scheduler.yaml" \
    && ok "rollback without --yes only shows the diff" || bad "rollback without --yes changed the node"
  out="$(cpt "${W}" rollback --yes 2>&1)"; rc=$?
  [ ${rc} -eq 0 ] && [ "${orig_s}" = "$(cat "${W}/root/${MAN}/kube-scheduler.yaml")" ] && [ "${orig_c}" = "$(cat "${W}/root/${MAN}/kube-controller-manager.yaml")" ] \
    && ok "rollback restores both original manifests" || bad "rollback: ${out}"
  cpt "${W}" verify >/dev/null 2>&1 && bad "verify passed on an untuned node" || ok "verify fails on an untuned node"

  # failure: the pod never comes back with the flags -> the backup is restored by itself
  cpt_world "${W}"; cpt_pods "${W}" noflags
  orig_s="$(cat "${W}/root/${MAN}/kube-scheduler.yaml")"
  out="$(cpt "${W}" apply --yes 2>&1)" && bad "apply succeeded although the pod never showed the flags" \
    || { grep -q 'rolled back' <<<"${out}" && [ "${orig_s}" = "$(cat "${W}/root/${MAN}/kube-scheduler.yaml")" ] \
         && ok "a component that does not come up with the flags is restored automatically" || bad "automatic restore: ${out}"; }
  grep -q -- 'leader-elect-lease' "${W}/root/${MAN}/kube-controller-manager.yaml" \
    && bad "the controller manager was edited after the scheduler failed" || ok "a failed component stops the run before the next one"
  # failure: the pod restarts during the hold
  cpt_world "${W}"
  out="$(cd "${W}" && PATH="${W}/bin:${PATH}" FAKE_ROOT="${W}/root" FAKE_STATE="${W}/state" HOLD_MINUTES=1 POLL_SECONDS=1 WAIT_SECONDS=2 ACQUIRE_SECONDS=2 \
      bash -c 'cp state/pod-kube-scheduler-fake-cp.json state/pod.orig
               ( sleep 2; sed -i.bak "s/\"restartCount\":3/\"restartCount\":4/" state/pod-kube-scheduler-fake-cp.json ) &
               "'"${CPT}"'" apply --yes --cluster fakectx --node-exec "'"${CPF}"'/fake-node" 2>&1' )" \
    && bad "apply succeeded although the scheduler restarted during the hold" \
    || { grep -q 'restarted during the hold' <<<"${out}" && grep -q 'rolled back' <<<"${out}" && ok "a restart during the hold restores the backup" || bad "hold failure text: ${out}"; }
else
  echo "  skip control-plane tuning script tests: need python3 with PyYAML and jq"
fi

echo "== 5. policy (55-autopilot/agentrun-grants against a real kube-apiserver; needs KUBEBUILDER_ASSETS)"
if out="$(python3 tests/policy/test_agentrun_grants.py 2>&1)"; then
  ok "agentrun-grants: $(tail -1 <<<"${out}")"
else
  bad "agentrun-grants: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
if out="$(python3 tests/policy/test_argo_sync.py 2>&1)"; then
  ok "clearance argo-sync: $(tail -1 <<<"${out}")"
else
  bad "clearance argo-sync: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi

echo "== 6. agentrun-reaper (the script in its ConfigMap, against a fake API)"
if out="$(python3 tests/reaper/test_reaper.py 2>&1)"; then
  ok "agentrun-reaper: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "agentrun-reaper: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi

echo
echo "${PASS} passed, ${FAIL} failed$( [ "${HAVE_YAML}" = true ] || echo ' (YAML parse skipped: no PyYAML)')"
[ "${FAIL}" -eq 0 ]
