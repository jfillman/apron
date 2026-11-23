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
#      KUBEBUILDER_ASSETS: tests/policy/test_agentrun_grants.py, test_argo_sync.py), and the tenant-onboarding delete guard
#      refuses only the ApplicationSet controller's delete of a tenant Application (test_tenant_delete_guard.py).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
APRON="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
# `apron render` compares versions.glidepathRunTasks with the pinned Glidepath's values (hack/glidepath_tasks.py); the tests use a
# fixture, not the network.
export APRON_GLIDEPATH_VALUES="${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml"
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
  grep -qE -- "$2" "$1" && ok "$3" || bad "$3 ($1 lacks /$2/)"
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
  --scm-owner org --registry-owner org-images --tower-cluster eks-prod --domain eks-dev.example.dev \
  --set tower.domain=eks-prod.example.dev
new "${E}/prod" prod eks-prod existing --repo-url https://gitlab.example.com/org/gitops-eks-prod \
  --scm-host gitlab.example.com --scm-owner org --fleet-hub eks-dev --fleet-repo-url https://gitlab.example.com/org/gitops-eks-dev \
  --domain eks-prod.example.dev --set fleet.hubDomain=eks-dev.example.dev
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
  printf 'tower: {cluster: eks-man, issuer: %s, domain: eks-man.aws.example.dev, baseUrl: https://backstage.eks-man.aws.example.dev}\n' "$1"
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
# clearance-api headroom: 512Mi limit, 128Mi request, GOMEMLIMIT below the limit (the chart default OOMKilled in a loop)
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'limits: \{memory: 512Mi\}' "lab: clearance-api memory limit is 512Mi"
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'requests: \{cpu: 25m, memory: 128Mi\}' "lab: clearance-api memory request is 128Mi"
has "${LAB}/dev/55-clearance/clearance/application.yaml" '^          goMemLimit: 400MiB$' "lab: clearance-api sets GOMEMLIMIT with the chart's goMemLimit"
# Chart 0.54.0 adds its own GOMEMLIMIT: one from extraEnv too makes the env name repeat, and Argo CD's dry run refuses the patch.
if grep -rqE 'name: GOMEMLIMIT' "${LAB}/dev/55-clearance/clearance/application.yaml"; then bad "lab: clearance sets GOMEMLIMIT in extraEnv (duplicate env name with the chart's)"; else ok "lab: clearance has no extraEnv GOMEMLIMIT"; fi
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
mkdir -p "${G}/warn" "${G}/enforce" "${G}/dev" "${G}/ca" "${G}/ca-empty" "${G}/ca-bad"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/warn/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, agentServiceAccount: "clearance-system:the-agent"}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/enforce/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'clearance: {gate: {enabled: true}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/dev/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, waitCAConfigMap: hangar-cluster-ca}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca/cluster.yaml"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, waitCAConfigMap: ""}}'; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca-empty/cluster.yaml"
render_ok "${G}/warn" "prod clearance gate warn"
render_ok "${G}/enforce" "prod clearance gate enforce"
render_ok "${G}/dev" "dev clearance gate key"
GP=56-clearance-gate/admission.yaml
expect "${G}/dev" "dev clearance gate key" "!${GP}"
has "${G}/warn/56-clearance-gate/application.yaml" 'path: 56-clearance-gate' "clearance gate: its own Application"
has "${G}/warn/56-clearance-gate/clearancegrant-crd.yaml" 'name: clearancegrants.clearance.hangar.io' "clearance gate: the ClearanceGrant CRD"
CRDF="${G}/warn/56-clearance-gate/clearancegrant-crd.yaml"
[ "$(grep -c '^  annotations:' "${CRDF}")" = 1 ] && ok "clearance gate: the CRD has one annotations key (a duplicate drops the sync wave)" \
  || bad "clearance gate: the CRD has a duplicate metadata.annotations key"
if [ "${HAVE_YAML}" = true ]; then
  if out="$(python3 - "${CRDF}" <<'PY' 2>&1
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))["metadata"]
a = m.get("annotations") or {}
want = {"argocd.argoproj.io/sync-wave": "0", "clearance.hangar.io/schema-revision": "3"}
bad = [k for k, v in want.items() if a.get(k) != v]
bad += [k for k in want if k in (m.get("labels") or {})]
if bad:
    print("wrong or misplaced: " + ", ".join(bad))
    sys.exit(1)
PY
  )"; then
    ok "clearance gate: the CRD's metadata.annotations hold sync-wave 0 and schema-revision 3"
  else
    bad "clearance gate: the CRD's metadata.annotations ${out}"
  fi
fi
has "${G}/warn/${GP}" "== 'registry.invalid/clearance-wait@sha256:1{64}'" "clearance gate: the exemption pins the wait image from versions.clearance.waitImage"
has "${G}/warn/${GP}" 'validationActions: \[Warn, Audit\]' "clearance gate: Warn by default"
has "${G}/warn/${GP}" 'parameterNotFoundAction: Allow' "clearance gate: Warn allows a missing grant"
has "${G}/warn/${GP}" "== 'system:serviceaccount:argocd-apps:argocd-application-controller'" "clearance gate: matches Argo's controller only"
has "${G}/warn/${GP}" "== 'system:serviceaccount:clearance-system:clearance-argocd-agent'" "clearance gate: the agent is the only grant writer"
has "${G}/enforce/${GP}" 'validationActions: \[Deny, Audit\]' "clearance gate: enforce denies"
has "${G}/enforce/${GP}" 'parameterNotFoundAction: Deny' "clearance gate: enforce flips parameterNotFoundAction too"
has "${G}/enforce/${GP}" "clearance-system:the-agent'" "clearance gate: the agent account is configurable"
# clearance.gate.waitCAConfigMap (I-43, A-17): off (unset or empty) the policy is byte for byte the one without the key; on, it
# admits only the plugin's CA volume of that ConfigMap; a name that is not a ConfigMap name is refused before it reaches the CEL.
render_ok "${G}/ca" "prod clearance gate enforce + waitCAConfigMap"
render_ok "${G}/ca-empty" "prod clearance gate enforce + empty waitCAConfigMap"
sed 's/clearance-system:the-agent/clearance-system:clearance-argocd-agent/' "${G}/enforce/${GP}" | cmp -s - "${G}/ca-empty/${GP}" \
  && ok "clearance gate: the waitCAConfigMap-off policy is the enforce policy byte for byte (bar the agent account)" \
  || bad "clearance gate: the waitCAConfigMap-off policy differs from the enforce policy"
nca() { grep -c "$1" "$2" 2>/dev/null || true; }
[ "$(nca 'clearance-ca' "${G}/warn/${GP}")" = 0 ] && [ "$(nca 'clearance-ca' "${G}/enforce/${GP}")" = 0 ] \
  && ok "clearance gate: no CA volume is admitted without waitCAConfigMap" || bad "clearance gate: the CA exemption renders without waitCAConfigMap"
has "${G}/ca/${GP}" "configMap.name == 'hangar-cluster-ca'" "clearance gate: the CA exemption pins the ConfigMap from waitCAConfigMap"
has "${G}/ca/${GP}" "mountPath == '/etc/clearance-ca'" "clearance gate: the CA exemption pins the mount path"
{ cat "${LAB}/prod/cluster.yaml"; echo "clearance: {gate: {enabled: true, waitCAConfigMap: \"x' || true || 'y\"}}"; echo 'versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'; } >"${G}/ca-bad/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/ca-bad/cluster.yaml" 2>&1)" && bad "clearance gate: a waitCAConfigMap that is not a ConfigMap name rendered" \
  || { grep -q 'waitCAConfigMap' <<<"${out}" && ok "clearance gate: a waitCAConfigMap that is not a ConfigMap name is refused" || bad "clearance gate: bad waitCAConfigMap refusal text: ${out}"; }
# clearance.gate.previousURL (A-19): one release only; off, the URL test is the single == as before; on, exactly the two URLs.
WIMG='versions: {clearance: {cmpImage: "ghcr.io/acme/clearance-cmp@sha256:aaaa", waitImage: "registry.invalid/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111", previousWaitImage: ""}}'
mkdir -p "${G}/prev" "${G}/prev-same" "${G}/prev-bad" "${G}/inject-noca"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, enforce: true, url: "https://clearance-core.clearance-system.svc:8443", previousURL: "http://clearance-core.clearance-system.svc:8080"}}'; echo "${WIMG}"; } >"${G}/prev/cluster.yaml"
render_ok "${G}/prev" "prod clearance gate enforce + previousURL"
has "${G}/prev/${GP}" "variables.waitctr.env\[0\].value in \['https://clearance-core.clearance-system.svc:8443', 'http://clearance-core.clearance-system.svc:8080'\] &&" "previousURL: the exemption admits the current and the previous URL"
has "${G}/enforce/${GP}" "variables.waitctr.env\[0\].value == '" "no previousURL: the single-URL test as before"
if grep -q 'env\[0\].value in' "${G}/enforce/${GP}" "${G}/warn/${GP}"; then bad "no previousURL: the URL test renders a list"; else ok "no previousURL: no URL list"; fi
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, url: "http://clearance.hangar-dev.local", previousURL: "http://clearance.hangar-dev.local"}}'; echo "${WIMG}"; } >"${G}/prev-same/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/prev-same/cluster.yaml" 2>&1)" && bad "previousURL equal to gate.url rendered" \
  || { grep -q 'previousURL equals' <<<"${out}" && ok "previousURL equal to gate.url is refused" || bad "previousURL equal: ${out}"; }
{ cat "${LAB}/prod/cluster.yaml"; echo "clearance: {gate: {enabled: true, previousURL: \"http://x' || true || 'y\"}}"; echo "${WIMG}"; } >"${G}/prev-bad/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/prev-bad/cluster.yaml" 2>&1)" && bad "a previousURL that is not a URL rendered" \
  || { grep -q 'clearance.gate.previousURL is' <<<"${out}" && ok "a previousURL that could reach the CEL is refused" || bad "bad previousURL: ${out}"; }
mkdir -p "${G}/prev-v6"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, url: "https://clearance-core.clearance-system.svc:8443", previousURL: "http://[2001:db8::1]:8080"}}'; echo "${WIMG}"; } >"${G}/prev-v6/cluster.yaml"
python3 hack/render.py --cluster "${G}/prev-v6/cluster.yaml" >/dev/null 2>&1 \
  && has "${G}/prev-v6/${GP}" "'http://\[2001:db8::1\]:8080'\] &&" "previousURL: an IPv6 host renders (CodeRabbit on #271)" || bad "previousURL: an IPv6 URL was refused"
{ cat "${LAB}/prod/cluster.yaml"; echo 'clearance: {gate: {enabled: true, waitCAInject: true}}'; echo "${WIMG}"; } >"${G}/inject-noca/cluster.yaml"
out="$(python3 hack/render.py --cluster "${G}/inject-noca/cluster.yaml" 2>&1)" && bad "waitCAInject without waitCAConfigMap rendered" \
  || { grep -q 'waitCAInject needs clearance.gate.waitCAConfigMap' <<<"${out}" && ok "waitCAInject without waitCAConfigMap is refused" || bad "waitCAInject without the policy key: ${out}"; }
if out="$(python3 tests/policy/test_clearance_gate.py "${G}/warn" "${G}/enforce" "${G}/ca" "${G}/prev" 2>&1)"; then
  ok "clearance gate admission: $(tail -1 <<<"${out}")"
else
  bad "clearance gate admission: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi

echo "== 1-ca. trust-manager and the cluster CA (A-19)"
# Off by default: neither renders. On: the chart and its image are pinned (the image by digest), no public-CA package image runs,
# the CA is ECDSA P-256 with its key never rotated, and the Bundle writes ConfigMap hangar-cluster-ca (key ca.crt) to every namespace.
expect "${LAB}/dev" "dev/kiac default" '!10-crds-operators/trust-manager/application.yaml' '!10-crds-operators/cluster-ca/ca.yaml'
expect "${LAB}/prod" "prod/kind default" '!10-crds-operators/trust-manager/application.yaml' '!10-crds-operators/cluster-ca/ca.yaml'
CAD="${TMP}/cluster-ca"
new "${CAD}/on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.trustManager=true --set components.clusterCA=true
render_ok "${CAD}/on" "dev trustManager + clusterCA"
TMA="${CAD}/on/10-crds-operators/trust-manager/application.yaml"
CAY="${CAD}/on/10-crds-operators/cluster-ca/ca.yaml"
TMV="$(sed -n 's/^    chart: \(v[0-9.]*\)$/\1/p' <(sed -n '/^  trustManager:/,/imageDigest/p' versions.yaml))"
TMD="$(sed -n 's/^    imageDigest: \(sha256:[0-9a-f]*\)$/\1/p' <(sed -n '/^  trustManager:/,/imageDigest/p' versions.yaml))"
[ -n "${TMV}" ] && [ -n "${TMD}" ] && ok "versions.trustManager: chart ${TMV}, image ${TMD:0:19}..." || bad "versions.trustManager: no chart or digest read"
has "${TMA}" "targetRevision: ${TMV}$" "trust-manager: the chart is pinned from versions.trustManager.chart"
has "${TMA}" "tag: \"${TMV}\"" "trust-manager: the image tag is the chart version"
has "${TMA}" "digest: \"${TMD}\"" "trust-manager: the image index is pinned by digest"
has "${TMA}" 'namespace: cert-manager$' "trust-manager: installs into cert-manager, its trust namespace"
grep -A1 'defaultPackage:' "${TMA}" | grep -q 'enabled: false' && ok "trust-manager: no public-CA package image" || bad "trust-manager: defaultPackage is not off"
grep -A1 'secretTargets:' "${TMA}" | grep -q 'enabled: false' && ok "trust-manager: no Secret targets" || bad "trust-manager: secretTargets is not off"
has "${CAD}/on/10-crds-operators/cluster-ca/application.yaml" 'path: 10-crds-operators/cluster-ca$' "cluster CA: its own Application"
if [ "${HAVE_YAML}" = true ]; then
  if out="$(python3 - "${CAY}" <<'PY' 2>&1
import sys, yaml
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
bad = []
ca = docs[("Certificate", "hangar-cluster-ca")]
s = ca["spec"]
if not (s.get("isCA") is True and s.get("secretName") == "hangar-cluster-ca" and ca["metadata"].get("namespace") == "cert-manager"):
    bad.append("the CA Certificate is not isCA hangar-cluster-ca in cert-manager")
if s.get("privateKey") != {"algorithm": "ECDSA", "size": 256, "rotationPolicy": "Never"}:
    bad.append(f"CA key {s.get('privateKey')}")
if s.get("duration") != "87600h":
    bad.append("CA duration is not 10 years")
if s.get("issuerRef", {}).get("name") != "hangar-cluster-ca-bootstrap" or s["issuerRef"].get("kind") != "ClusterIssuer":
    bad.append("the CA is not signed by the bootstrap ClusterIssuer")
if docs[("ClusterIssuer", "hangar-cluster-ca-bootstrap")]["spec"] != {"selfSigned": {}}:
    bad.append("the bootstrap issuer is not self-signed")
if docs[("ClusterIssuer", "hangar-cluster-ca")]["spec"] != {"ca": {"secretName": "hangar-cluster-ca"}}:
    bad.append("the CA ClusterIssuer does not sign with hangar-cluster-ca")
b = docs[("Bundle", "hangar-cluster-ca")]
if b["apiVersion"] != "trust.cert-manager.io/v1alpha1":
    bad.append("Bundle apiVersion " + b["apiVersion"])
if b["spec"].get("sources") != [{"secret": {"name": "hangar-cluster-ca", "key": "ca.crt"}}]:
    bad.append(f"Bundle sources {b['spec'].get('sources')} (want only the CA Secret's ca.crt)")
if b["spec"].get("target") != {"configMap": {"key": "ca.crt"}}:
    bad.append(f"Bundle target {b['spec'].get('target')} (want a ConfigMap, key ca.crt, every namespace: no namespaceSelector)")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
  )"; then
    ok "cluster CA: self-signed bootstrap -> CA (P-256, 10y, key kept) -> CA ClusterIssuer; the Bundle publishes only ca.crt to every namespace"
  else
    bad "cluster CA: ${out}"
  fi
fi
for c in "components.clusterCA=true:components.clusterCA needs components.certManager" \
         "components.trustManager=true:components.trustManager needs components.certManager"; do
  new "${CAD}/bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
    --set components.certManager=false --set "${c%%:*}" --set components.trustManager=true
  out="$(python3 hack/render.py --cluster "${CAD}/bad/cluster.yaml" 2>&1)" && bad "${c%%:*} without cert-manager rendered" \
    || { grep -qF "${c#*:}" <<<"${out}" && ok "${c%%:*} without cert-manager is refused" || bad "${c%%:*} without cert-manager: ${out}"; }
done
new "${CAD}/notm" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.clusterCA=true
out="$(python3 hack/render.py --cluster "${CAD}/notm/cluster.yaml" 2>&1)" && bad "clusterCA without trustManager rendered" \
  || { grep -qF "components.clusterCA needs" <<<"${out}" && ok "clusterCA without trustManager is refused" || bad "clusterCA without trustManager: ${out}"; }
new "${CAD}/nodig" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.trustManager=true --set versions.trustManager.imageDigest=latest
out="$(python3 hack/render.py --cluster "${CAD}/nodig/cluster.yaml" 2>&1)" && bad "trustManager with no image digest rendered" \
  || { grep -qF "versions.trustManager.imageDigest" <<<"${out}" && ok "trustManager without an image digest is refused" || bad "trustManager without a digest: ${out}"; }

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

echo "== 1a. glidepath-api's PipelineRun policies (pipeline trust T5)"
GA="${TMP}/gpapi"
mkdir -p "${GA}/warn"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {sourceIsolation: warn, runStorageClasses: [fast]}'; } >"${GA}/warn/cluster.yaml"
render_ok "${GA}/warn" "dev glidepath.sourceIsolation warn"
GW=30-policy/kyverno-policies/tower-identity-writes.yaml
CPV=50-glidepath/glidepath-control-plane/values.yaml
has "${LAB}/dev/${GW}" 'name: glidepath-api-pipelinerun-source-isolation' "glidepath-api: the source-isolation policy is rendered"
has "${LAB}/dev/${GW}" "expression: '\{\"build\": \[\"build-source\", \"unit-test\", \"build-image\", \"build-python-wheel-artifact\", \"build-go-binary-artifact\"\], \"clearance-gate-check\": \[\"render\"\], \"policy-validation-check\": \[\"render\"\], \"test\": \[\"run-integration-script\"\], \"values-check\": \[\"render\"\]\}'" "glidepath-api: the source tasks come from versions.glidepathRunTasks"
has "${LAB}/dev/${GW}" "expression: '\{\"build\": \[\"push-image\"\]\}'" "glidepath-api: the pusher task"
has "${LAB}/dev/${GW}" "expression: '\{\"deploy\": \[\"deploy-aws-lambda\", \"deploy-aws-ecs\"\]\}'" "glidepath-api: the cloud deployer tasks"
has "${LAB}/dev/${GW}" "expression: '\{\"bypass-merge-check\": \[\"mark-release-merged\", \"itsm-implement\"\], \"clearance-gate-check\": \[\"join-release\"\], \"itsm-check\": \[\"verify-change\", \"verify-change-advisory\"\], \"release\": \[\"open-release-pr\"\], \"release-outcome-notify\": \[\"itsm-close\"\], \"release-rollback-notify\": \[\"itsm-close-rolled-back\"\]\}'" "glidepath-api: the release-record-writer tasks"
has "${LAB}/dev/${GW}" "expression: '\{\"test\": \[\"run-testworkflow\"\]\}'" "glidepath-api: the test-runner task"
has "${LAB}/dev/${GW}" "s.serviceAccountName == 'clearance-gate' && variables.pipelineName in variables.clearanceTasks" "glidepath-api: clearance-gate is allowed on its own tasks, by exact name"
has "${LAB}/dev/${GW}" '^  validationActions: \[Deny\]$' "glidepath-api: deny by default"
has "${LAB}/dev/${CPV}" '^  sourceIsolationActions: \[Deny\]$' "glidepath control plane: source isolation Deny by default"
# itsm.enabled (glidepath-app, pipeline trust T4 step 3) follows itsm.provider: true with the webhook provider (hangar-dev's mock), absent without.
mkdir -p "${GA}/itsm" "${GA}/noitsm"
{ cat "${LAB}/dev/cluster.yaml"; echo 'itsm: {provider: webhook, webhookUrl: "http://itsm-mock.platform-system.svc.cluster.local:8080/webhook"}'; } >"${GA}/itsm/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'itsm: {provider: null, webhookUrl: null}'; } >"${GA}/noitsm/cluster.yaml"
render_ok "${GA}/itsm" "dev with the webhook ITSM provider"
render_ok "${GA}/noitsm" "dev with no ITSM provider"
for d in itsm noitsm; do [ -f "${GA}/${d}/${CPV}" ] || bad "glidepath control plane: the ${d} render has no ${CPV} to check"; done
if awk '/^itsm:$/{f=1;next} f&&/^  enabled: true$/{ok=1} f&&/^[^ #]/{f=0} END{exit !ok}' "${GA}/itsm/${CPV}"; then ok "glidepath control plane: the webhook ITSM provider renders itsm.enabled: true"; else bad "glidepath control plane: the webhook ITSM provider does not render itsm.enabled: true"; fi
if grep -q '^itsm:' "${GA}/noitsm/${CPV}"; then bad "glidepath control plane: no ITSM provider still renders itsm.enabled"; else ok "glidepath control plane: no ITSM provider leaves itsm.enabled out (false)"; fi
has "${LAB}/dev/${CPV}" '^  concurrencyLimit: 3$' "glidepath control plane: the dev profile queues Pipelines-as-Code runs at 3 per repository"
mkdir -p "${GA}/nogate"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateConcurrency: null, gitopsRepoProvenance: null}'; } >"${GA}/nogate/cluster.yaml"
render_ok "${GA}/nogate" "dev glidepath.gateConcurrency and gitopsRepoProvenance unset"
[ -f "${GA}/nogate/${CPV}" ] || bad "glidepath control plane: the unset render has no ${CPV} to check"
if grep -q 'pipelinesAsCode:' "${GA}/nogate/${CPV}"; then bad "glidepath control plane: glidepath.gateConcurrency and gitopsRepoProvenance unset still render a pipelinesAsCode block"; else ok "glidepath control plane: unset gateConcurrency and gitopsRepoProvenance leave pipelinesAsCode out"; fi
has "${LAB}/dev/${CPV}" '^  gitopsRepoProvenance: default_branch$' "glidepath control plane: the dev profile reads gitops repositories' .tekton from the default branch"
has "${LAB}/dev/${CPV}" '^pipelinesAsCode:$' "glidepath control plane: limit and provenance share one pipelinesAsCode block"
mkdir -p "${GA}/noprov"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: null}'; } >"${GA}/noprov/cluster.yaml"
render_ok "${GA}/noprov" "dev glidepath.gitopsRepoProvenance unset"
[ -f "${GA}/noprov/${CPV}" ] || bad "glidepath control plane: the unset-provenance render has no ${CPV} to check"
has "${GA}/noprov/${CPV}" '^  concurrencyLimit: 3$' "glidepath control plane: unset gitopsRepoProvenance keeps the concurrency limit"
if grep -q 'gitopsRepoProvenance' "${GA}/noprov/${CPV}"; then bad "glidepath control plane: glidepath.gitopsRepoProvenance unset still renders gitopsRepoProvenance"; else ok "glidepath control plane: unset glidepath.gitopsRepoProvenance leaves it out"; fi
has "${GA}/warn/${GW}" '^  validationActions: \[Warn, Audit\]$' "glidepath-api: glidepath.sourceIsolation warn warns"
has "${GA}/warn/${CPV}" '^  sourceIsolationActions: \[Warn, Audit\]$' "glidepath control plane: warn flips Glidepath's own binding too"
has "${GA}/warn/${GW}" "expression: '\[\"fast\"\]'" "glidepath-api: glidepath.runStorageClasses is the volumeClaimTemplate allowlist"
has "${LAB}/dev/${GW}" "expression: '\[\]'" "glidepath-api: no storage class is allowed by default"
# glidepath.runShape: Glidepath's cicd-run-shape and cicd-run-no-taskruns bindings (cicdRunAdmission.shapeActions, noTaskRunsActions).
mkdir -p "${GA}/shape-warn" "${GA}/shape-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {runShape: warn}'; } >"${GA}/shape-warn/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {runShape: maybe}'; } >"${GA}/shape-bad/cluster.yaml"
render_ok "${GA}/shape-warn" "dev glidepath.runShape warn"
has "${LAB}/dev/${CPV}" '^  shapeActions: \[Deny\]$' "glidepath control plane: cicd-run-shape Deny by default"
has "${LAB}/dev/${CPV}" '^  noTaskRunsActions: \[Deny\]$' "glidepath control plane: cicd-run-no-taskruns Deny by default"
has "${GA}/shape-warn/${CPV}" '^  shapeActions: \[Warn, Audit\]$' "glidepath.runShape warn: cicd-run-shape warns"
has "${GA}/shape-warn/${CPV}" '^  noTaskRunsActions: \[Warn, Audit\]$' "glidepath.runShape warn: cicd-run-no-taskruns warns"
has "${GA}/shape-warn/${CPV}" '^  sourceIsolationActions: \[Deny\]$' "glidepath.runShape warn leaves source isolation (its own key) at Deny"
if python3 hack/check.py --cluster "${GA}/shape-bad/cluster.yaml" >/dev/null 2>"${GA}/shape-bad/err"; then
  bad "glidepath.runShape: maybe was accepted"
else
  grep -q 'glidepath.runShape' "${GA}/shape-bad/err" && ok "glidepath.runShape: an unknown value is refused by apron check" || bad "runShape refusal: $(cat "${GA}/shape-bad/err")"
fi
# Load reduction (2026-11-15): Kyverno's TTL interval, the platform CronJobs' own minutes, and Argo CD's ignored heartbeat annotation.
KV=30-policy/kyverno/application.yaml
has "${LAB}/dev/${KV}" '^            reconciliationInterval: 5m$' "dev: Kyverno ttlController.reconciliationInterval is 5m"
has "${LAB}/prod/${KV}" '^            reconciliationInterval: 1m$' "prod: Kyverno ttlController.reconciliationInterval stays at the chart's 1m"
has "${LAB}/dev/55-autopilot/agentrun-reaper/reaper.yaml" '^  schedule: "7-59/10 \* \* \* \*"$' "dev: agentrun-reaper runs at minute 7"
has "${LAB}/dev/55-autopilot/agentrun-reaper/reaper.yaml" '^  startingDeadlineSeconds: 300$' "dev: agentrun-reaper has a startingDeadlineSeconds"
has "${LAB}/dev/01-argocd-platform/install.yaml" 'ignoreResourceUpdates.Secret' "dev: Argo CD has an ignoreResourceUpdates rule for Secrets"
# the annotation is ignored on both kinds the observer stamps (ConfigMap heartbeat, Secret canary): one jq path under each rule
BEAT="$(grep -c "^      - '.metadata.annotations.\"observe-k8s.clearance.hangar.io/beat\"'$" "${LAB}/dev/01-argocd-platform/install.yaml")"
[[ "${BEAT}" == 2 ]] && ok "dev: Argo CD ignores the observer's heartbeat annotation on ConfigMaps and Secrets" || bad "heartbeat annotation ignore rules: ${BEAT} (want 2)"
{ cat "${LAB}/dev/cluster.yaml"; echo 'kyverno: {ttlReconciliationInterval: soon}'; } >"${GA}/kv-bad.yaml"
if python3 hack/render.py --cluster "${GA}/kv-bad.yaml" --out "${GA}/kv-bad-out" >/dev/null 2>&1; then
  bad "kyverno.ttlReconciliationInterval: soon was accepted"
else
  ok "kyverno.ttlReconciliationInterval: an unknown duration is refused"
fi
# glidepath.refProtection: the catalog's refProtection.mode (T3's verify-ref-protection task); required unless the cluster says off.
CATV=50-glidepath/glidepath-catalog/application.yaml
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {refProtection: off}'; } >"${GA}/rp-off.yaml"
mkdir -p "${GA}/rp-off" "${GA}/rp-bad"
cp "${GA}/rp-off.yaml" "${GA}/rp-off/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {refProtection: sometimes}'; } >"${GA}/rp-bad/cluster.yaml"
render_ok "${GA}/rp-off" "dev glidepath.refProtection off"
has "${LAB}/dev/${CATV}" '^            mode: "required"$' "glidepath catalog: refProtection.mode is required by default"
has "${GA}/rp-off/${CATV}" '^            mode: "off"$' "glidepath catalog: glidepath.refProtection off renders mode off"
if python3 hack/check.py --cluster "${GA}/rp-bad/cluster.yaml" >/dev/null 2>"${GA}/rp-bad/err"; then
  bad "glidepath.refProtection: sometimes was accepted"
else
  grep -q 'glidepath.refProtection' "${GA}/rp-bad/err" && ok "glidepath.refProtection: an unknown value is refused by apron check" || bad "refProtection refusal: $(cat "${GA}/rp-bad/err")"
fi
# promotion.gateLedger.writer (W-8): who writes the gate ledger. Unset renders no gateLedger key (the catalog's direct stands); api renders it.
mkdir -p "${GA}/glw-api" "${GA}/glw-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'promotion: {gateLedger: {writer: api}}'; } >"${GA}/glw-api/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'promotion: {gateLedger: {writer: pipeline}}'; } >"${GA}/glw-bad/cluster.yaml"
render_ok "${GA}/glw-api" "dev promotion.gateLedger.writer api"
has "${GA}/glw-api/${CATV}" '^          promotion: \{.*"gateLedger": \{"writer": "api"\}' "glidepath catalog: promotion.gateLedger.writer api reaches the catalog values"
if grep -q 'gateLedger' "${LAB}/dev/${CATV}"; then bad "promotion.gateLedger.writer unset: dev still renders a gateLedger key"; else ok "promotion.gateLedger.writer unset: dev renders no gateLedger key (unchanged)"; fi
if python3 hack/check.py --cluster "${GA}/glw-bad/cluster.yaml" >/dev/null 2>"${GA}/glw-bad/err"; then
  bad "promotion.gateLedger.writer: pipeline was accepted"
else
  grep -q 'promotion.gateLedger.writer' "${GA}/glw-bad/err" && ok "promotion.gateLedger.writer: an unknown value is refused by apron check" || bad "gateLedger.writer refusal: $(cat "${GA}/glw-bad/err")"
fi
# glidepath.gateReports.transport (W-8): how api-compat and policy-validation hand over their report. Unset renders no gateReports key
# (the catalog's configmap stands); log renders it as one line; an unknown value is refused by both render and check.
mkdir -p "${GA}/grt-log" "${GA}/grt-bad"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateReports: {transport: log}}'; } >"${GA}/grt-log/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateReports: {transport: pod}}'; } >"${GA}/grt-bad/cluster.yaml"
render_ok "${GA}/grt-log" "dev glidepath.gateReports.transport log"
has "${GA}/grt-log/${CATV}" '^          gateReports: \{"transport": "log"\}' "glidepath catalog: glidepath.gateReports.transport log reaches the catalog values"
if grep -q 'gateReports' "${LAB}/dev/${CATV}"; then bad "glidepath.gateReports.transport unset: dev still renders a gateReports key"; else ok "glidepath.gateReports.transport unset: dev renders no gateReports key (unchanged)"; fi
if [ "$(diff "${LAB}/dev/${CATV}" "${GA}/grt-log/${CATV}" | grep -c '^[<>]')" = 1 ]; then ok "glidepath.gateReports.transport log: the catalog Application differs from unset by one line"; else bad "gateReports log diff: $(diff "${LAB}/dev/${CATV}" "${GA}/grt-log/${CATV}")"; fi
if python3 hack/check.py --cluster "${GA}/grt-bad/cluster.yaml" >/dev/null 2>"${GA}/grt-bad/err"; then
  bad "glidepath.gateReports.transport: pod was accepted by apron check"
else
  grep -q 'glidepath.gateReports.transport' "${GA}/grt-bad/err" && ok "glidepath.gateReports.transport: an unknown value is refused by apron check" || bad "gateReports.transport check refusal: $(cat "${GA}/grt-bad/err")"
fi
if python3 hack/render.py --cluster "${GA}/grt-bad/cluster.yaml" --out "${GA}/grt-bad" >/dev/null 2>"${GA}/grt-bad/rerr"; then
  bad "glidepath.gateReports.transport: pod was rendered"
else
  grep -q 'glidepath.gateReports.transport' "${GA}/grt-bad/rerr" && ok "glidepath.gateReports.transport: an unknown value is refused by apron render" || bad "gateReports.transport render refusal: $(cat "${GA}/grt-bad/rerr")"
fi
# releaseGuardrailOverrides: the catalog's per-cluster `required` of a release gate (glidepath release-guardrails.md "Who sets it"), e.g.
# clearance-gate required on one cluster (docs/admin/clearance-gate.md, G-ARGO-8). Unset renders no key at all, so every other cluster is byte-identical.
mkdir -p "${GA}/gro-on" "${GA}/gro-bad" "${GA}/gro-bad2"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: true}}'; } >"${GA}/gro-on/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: "yes"}}'; } >"${GA}/gro-bad/cluster.yaml"
{ cat "${LAB}/dev/cluster.yaml"; echo 'releaseGuardrailOverrides: [clearance-gate]'; } >"${GA}/gro-bad2/cluster.yaml"
render_ok "${GA}/gro-on" "dev releaseGuardrailOverrides clearance-gate required"
has "${GA}/gro-on/${CATV}" '^          releaseGuardrailOverrides: \{"clearance-gate": \{"required": true\}\}$' "glidepath catalog: releaseGuardrailOverrides carries clearance-gate required: true"
has "${GA}/gro-on/${CATV}" '^          releaseGuardrailOverridesByApp: ' "glidepath catalog: the by-app map is still rendered beside it"
[ -f "${LAB}/dev/${CATV}" ] || bad "releaseGuardrailOverrides: the dev render has no ${CATV} to check"
if grep -q '^          releaseGuardrailOverrides:' "${LAB}/dev/${CATV}"; then bad "releaseGuardrailOverrides unset: dev still renders the key"; else ok "releaseGuardrailOverrides unset: dev renders no key (unchanged)"; fi
# hangar-prod: the key set in its cluster.yaml (a mistake, or a copy of the dev file) reaches nothing, because a prod-profile cluster runs no
# glidepath-catalog Application (components.glidepath is off in profiles/prod.yaml); its unset render is proven byte-identical in the PR's diff.
mkdir -p "${GA}/gro-prod"
{ cat "${LAB}/prod/cluster.yaml"; echo 'releaseGuardrailOverrides: {clearance-gate: {required: true}}'; } >"${GA}/gro-prod/cluster.yaml"
render_ok "${GA}/gro-prod" "prod releaseGuardrailOverrides set"
[ ! -f "${LAB}/prod/${CATV}" ] || bad "releaseGuardrailOverrides: prod renders a glidepath-catalog Application (this assertion needs updating)"
if grep -rq 'releaseGuardrailOverrides' "${GA}/gro-prod"/[0-9][0-9]-*; then bad "releaseGuardrailOverrides: the prod render carries the key"; else ok "releaseGuardrailOverrides: the prod render carries no override (no catalog Application there)"; fi
for b in gro-bad gro-bad2; do
  if python3 hack/check.py --cluster "${GA}/${b}/cluster.yaml" >/dev/null 2>"${GA}/${b}/err"; then
    bad "releaseGuardrailOverrides: ${b} was accepted"
  else
    grep -q 'releaseGuardrailOverrides' "${GA}/${b}/err" && ok "releaseGuardrailOverrides: ${b} is refused by apron check" || bad "releaseGuardrailOverrides ${b} refusal: $(cat "${GA}/${b}/err")"
  fi
done
# versions.glidepath: cluster.yaml overrides versions.yaml (the resolution order), so a cluster can pin its own Glidepath revision.
mkdir -p "${GA}/rev"
{ cat "${LAB}/dev/cluster.yaml"; echo 'versions: {glidepath: v9.9.9}'; } >"${GA}/rev/cluster.yaml"
APRON_GLIDEPATH_CHECK=off python3 hack/render.py --cluster "${GA}/rev/cluster.yaml" >/dev/null 2>&1
has "${GA}/rev/50-glidepath/glidepath-control-plane/application.yaml" 'targetRevision: v9.9.9' "versions.glidepath in cluster.yaml overrides the pin"
if out="$(python3 tests/policy/test_glidepath_api_rerun.py "${LAB}/dev" "${GA}/warn" 2>&1)"; then
  case "${out}" in
    skipped*) echo "  skip glidepath-api rerun policy CEL tests: ${out} (a skip is not a pass)";;
    *) ok "glidepath-api rerun policy CEL: $(grep -E '^Ran ' <<<"${out}"), $(tail -1 <<<"${out}")";;
  esac
else
  bad "glidepath-api rerun policy CEL: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
# The lists must match the pinned Glidepath's values: a render with a task added or dropped is refused, naming it.
gp_drift() { # gp_drift LABEL SED-EXPR WANT-IN-MESSAGE
  local f="${TMP}/gp-values-$((RANDOM)).yaml" out
  sed "$2" "${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml" >"${f}"
  if cmp -s "${f}" "${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml"; then
    bad "glidepath lists drift: ${1}: the sed changed nothing"
    return
  fi
  if out="$(APRON_GLIDEPATH_VALUES="${f}" python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" 2>&1)"; then
    bad "glidepath lists drift: ${1}: render accepted"
  elif grep -q -- "$3" <<<"${out}"; then
    ok "glidepath lists drift: ${1}: refused ($(grep -o "$3" <<<"${out}" | head -1))"
  else
    bad "glidepath lists drift: ${1}: refused for another reason: ${out}"
  fi
}
if [ "${HAVE_YAML}" = true ]; then
  gp_drift "a source task Glidepath added" 's/build: \[build-source,/build: [build-source, lint-source,/' 'sourceTasks.build: missing here: lint-source'
  gp_drift "a source task Glidepath dropped" 's/build-go-binary-artifact\]/build-go-binary-artifactx]/' 'not in Glidepath: build-go-binary-artifact'
  gp_drift "a new pusher task" 's/build: \[push-image\]/build: [push-image, push-sbom]/' 'pusherTasks.build: missing here: push-sbom'
  gp_drift "a new record-writer task" 's/    release: \[open-release-pr\]/    release: [open-release-pr, open-release-x]/' 'recordWriterTasks.release: missing here: open-release-x'
  gp_drift "a new test-runner task" 's/    test: \[run-testworkflow\]/    test: [run-testworkflow, run-more]/' 'testRunnerTasks.test: missing here: run-more'
  gp_drift "a new cloud deployer Pipeline" 's/    deploy: \[deploy-aws-lambda, deploy-aws-ecs\]/    deploy: [deploy-aws-lambda, deploy-aws-ecs]\n    release: [deploy-aws-ecs]/' 'cloudDeployerTasks.release'
  for bad in 'a: [unclosed' '- a list' 'cicdRunAdmission: [x]'; do
    printf '%s\n' "${bad}" >"${TMP}/gp-badvalues.yaml"
    out="$(APRON_GLIDEPATH_VALUES="${TMP}/gp-badvalues.yaml" python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" 2>&1)"
    if grep -q '^error: ' <<<"${out}" && ! grep -q Traceback <<<"${out}"; then
      ok "glidepath lists: a bad values file (${bad}) is a clean error"
    else
      bad "glidepath lists: a bad values file (${bad}): ${out}"
    fi
  done
  if APRON_GLIDEPATH_VALUES=/nonexistent python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" >/dev/null 2>&1; then
    bad "glidepath lists: an unreadable APRON_GLIDEPATH_VALUES was accepted"
  else
    ok "glidepath lists: an unreadable APRON_GLIDEPATH_VALUES is refused, not skipped"
  fi
else
  echo "  skip glidepath lists drift tests: need PyYAML"
fi
mkdir -p "${TMP}/gp-bad-mode"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {sourceIsolation: off}'; } >"${TMP}/gp-bad-mode/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-mode/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-mode/err"; then
  bad "glidepath.sourceIsolation: off was accepted"
else
  grep -q 'deny (default) or warn' "${TMP}/gp-bad-mode/err" && ok "glidepath.sourceIsolation off is refused" || bad "glidepath.sourceIsolation off: $(cat "${TMP}/gp-bad-mode/err")"
fi
mkdir -p "${TMP}/gp-bad-gate"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateConcurrency: 0}'; } >"${TMP}/gp-bad-gate/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-gate/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-gate/err"; then
  bad "glidepath.gateConcurrency: 0 was accepted"
else
  grep -q 'whole number of at least 1' "${TMP}/gp-bad-gate/err" && ok "glidepath.gateConcurrency 0 is refused" || bad "glidepath.gateConcurrency 0: $(cat "${TMP}/gp-bad-gate/err")"
fi

mkdir -p "${TMP}/gp-bad-prov"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: main}'; } >"${TMP}/gp-bad-prov/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-prov/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-prov/err"; then
  bad "glidepath.gitopsRepoProvenance: main was accepted"
else
  grep -q 'default_branch, source, or unset' "${TMP}/gp-bad-prov/err" && ok "glidepath.gitopsRepoProvenance main is refused" || bad "glidepath.gitopsRepoProvenance main: $(cat "${TMP}/gp-bad-prov/err")"
fi

# the key's first name, glidepath.gitopsPipelineProvenance, is still read: alone it is used with a warning, next to a different new key it is an error
mkdir -p "${TMP}/gp-prov-new" "${TMP}/gp-prov-old" "${TMP}/gp-prov-both" "${TMP}/gp-prov-same"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: source}'; } >"${TMP}/gp-prov-new/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-new/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-new/err" || bad "glidepath.gitopsRepoProvenance: source did not render: $(cat "${TMP}/gp-prov-new/err")"
has "${TMP}/gp-prov-new/${CPV}" '^  gitopsRepoProvenance: source$' "glidepath.gitopsRepoProvenance source reaches the control plane values"
if grep -q 'deprecated' "${TMP}/gp-prov-new/err"; then bad "glidepath.gitopsRepoProvenance warned about a deprecated key"; else ok "glidepath.gitopsRepoProvenance prints no deprecation warning"; fi
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source}'; } >"${TMP}/gp-prov-old/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-old/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-old/err" || bad "the old glidepath.gitopsPipelineProvenance: source did not render: $(cat "${TMP}/gp-prov-old/err")"
has "${TMP}/gp-prov-old/${CPV}" '^  gitopsRepoProvenance: source$' "the old key gitopsPipelineProvenance is still read"
grep -q 'glidepath.gitopsPipelineProvenance is deprecated, rename it to glidepath.gitopsRepoProvenance' "${TMP}/gp-prov-old/err" && ok "the old key prints a deprecation warning" || bad "the old key printed no deprecation warning: $(cat "${TMP}/gp-prov-old/err")"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source, gitopsRepoProvenance: default_branch}'; } >"${TMP}/gp-prov-both/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-prov-both/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-both/err"; then
  bad "both provenance keys with different values were accepted"
else
  grep -q 'they are the same setting' "${TMP}/gp-prov-both/err" && ok "both provenance keys with different values are refused" || bad "both provenance keys differing: $(cat "${TMP}/gp-prov-both/err")"
fi
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source, gitopsRepoProvenance: source}'; } >"${TMP}/gp-prov-same/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-same/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-same/err" && ok "both provenance keys with the same value render" || bad "both provenance keys, same value: $(cat "${TMP}/gp-prov-same/err")"

echo "== 1b. the Argo CD gate(clearance.gate.enabled: the plugin sidecar and the ApplicationSet's plugin source)"
GATE_SET=(--set clearance.gate.enabled=true --set 'clearance.protectedEnvironments=[hangar-prod/prod]'
  --set versions.clearance.cmpImage=ghcr.io/acme/clearance-cmp@sha256:aaaa --set versions.clearance.waitImage=ghcr.io/acme/clearance-wait@sha256:bbbb --set versions.clearance.previousWaitImage=)
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
CMPENV="${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml"
has "${CMPENV}" 'name: CLEARANCE_CHART_REPOS, value: "https://github.com/acme/airframe.git"' "gate on: the sidecar's chart allow list is the cluster's airframe repository, set by the platform"
new "${TMP}/gate-more" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'allowedChartRepos=[https://github.com/acme/team-charts.git]'
render_ok "${TMP}/gate-more" "gate on with allowedChartRepos"
has "${TMP}/gate-more/01-argocd-platform/argocd-apps-install/application.yaml" 'name: CLEARANCE_CHART_REPOS, value: "https://github.com/acme/airframe.git,https://github.com/acme/team-charts.git"' "allowedChartRepos: the plugin's list is airframe plus those repositories (the union Argo CD allows)"
has "${TMP}/gate-more/02-argocd-apps/tenant-appprojects/applicationset.yaml" 'allowedChartRepos: \["https://github.com/acme/team-charts.git"\]' "allowedChartRepos: the tenant AppProjects get the same repositories"
has "${TMP}/gate/02-argocd-apps/tenant-appprojects/applicationset.yaml" 'allowedChartRepos: \[\]' "no allowedChartRepos: the AppProjects allow only Airframe's"
new "${TMP}/gate-badrepo" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'allowedChartRepos=["https://x.test/a,b"]'
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-badrepo/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "allowedChartRepos: 'https://x.test/a,b' is a repository URL" <<<"${BADERR}"; then ok "allowedChartRepos entry with a comma is refused with its validation error"; else bad "allowedChartRepos comma entry: rc=${BADRC} ${BADERR}"; fi
for BAD in 'allowedChartRepos={a: b}' 'allowedChartRepos=https://x.test/a'; do
  new "${TMP}/gate-badtype" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-badtype/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -q "allowedChartRepos must be a list of repository URL strings" <<<"${BADERR}"; then ok "${BAD}: refused as not a list of strings"; else bad "${BAD}: rc=${BADRC} ${BADERR}"; fi
done
new "${TMP}/gate-nohost" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'allowedChartRepos=[https:///only/a/path]'
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-nohost/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "has no host name" <<<"${BADERR}"; then ok "allowedChartRepos entry with no host name is refused with its validation error"; else bad "allowedChartRepos no host: rc=${BADRC} ${BADERR}"; fi
DEFREPO="$(sed -n 's/^  repoURL: //p' "${TMP}/gate/cluster-defaults.yaml" | head -1)"
if [ -n "${DEFREPO}" ] && grep -qF "name: CLEARANCE_CHART_REPOS, value: \"${DEFREPO}\"" "${CMPENV}"; then ok "gate on: the allow list names the same repository as cluster-defaults.yaml's defaultChart"; else bad "gate on: allow list differs from defaultChart.repoURL (${DEFREPO})"; fi
if grep -n 'CLEARANCE_CHART_REPOS' "${AS}" | grep -v '^[0-9]*: *#' | grep -q .; then bad "gate on: the allow list is set in the ApplicationSet (a plugin parameter a tenant value could reach)"; else ok "gate on: the allow list is not an ApplicationSet parameter"; fi
for P in chartRepo chartRevision chartPath; do
  has "${AS}" "name: ${P}, string: '\{\{ dig .* \| replace \"'\" \"''\" \}\}'\}" "gate on: plugin parameter ${P} doubles a quote in its value, so identity.yaml cannot add a parameter"
done
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
has "${TMP}/gate-agent/56-clearance-gate/admission.yaml" "variables.waitctr.image == 'ghcr.io/acme/clearance-wait@sha256:bbbb' &&" "gate on, no previousWaitImage: the exemption is the single-image test as before"
if grep -q "waitctr.image in" "${TMP}/gate-agent/56-clearance-gate/admission.yaml"; then bad "no previousWaitImage: the exemption renders a list"; else ok "no previousWaitImage: no list in the exemption"; fi
PREV=ghcr.io/acme/clearance-wait@sha256:1111111111111111111111111111111111111111111111111111111111111111
new "${TMP}/gate-prev" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true \
  --set "versions.clearance.previousWaitImage=${PREV}"
render_ok "${TMP}/gate-prev" "gate on with versions.clearance.previousWaitImage"
has "${TMP}/gate-prev/56-clearance-gate/admission.yaml" "variables.waitctr.image in \\['ghcr.io/acme/clearance-wait@sha256:bbbb', '${PREV}'\\] &&" "previousWaitImage: the gate exemption admits the new and the previous wait image"
has "${TMP}/gate-prev/30-policy/kyverno-policies/flight-images.yaml" "clearance-wait@sha256:bbbb\", \"${PREV}\"" "previousWaitImage: Flight admission's allow-list has both digests"
has "${TMP}/gate-prev/56-clearance-gate/agent/application.yaml" 'image: "ghcr.io/acme/clearance-wait@sha256:bbbb"' "previousWaitImage: the agent's waitJob.image stays the new digest"
new "${TMP}/gate-prev-same" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc \
  --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight --set promotion.promoter.repo=acme-flight/flight-promoter --set admission.flight.enabled=true \
  --set "versions.clearance.previousWaitImage=ghcr.io/acme/clearance-wait@sha256:bbbb"
if python3 hack/render.py --cluster "${TMP}/gate-prev-same/cluster.yaml" >/dev/null 2>&1; then bad "previousWaitImage equal to waitImage was accepted"; else ok "previousWaitImage equal to waitImage is refused"; fi
# The agent's previous wait-image pin (I-59, clearance#218; agent chart 0.56.0): previousWaitImage is passed as waitJob.previousImage.
PWJ=(--fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]'
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc)
new "${TMP}/gate-pwj" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.56.0 --set "versions.clearance.previousWaitImage=${PREV}"
render_ok "${TMP}/gate-pwj" "agent chart 0.56.0 with previousWaitImage"
PWA="${TMP}/gate-pwj/56-clearance-gate/agent/application.yaml"
has "${PWA}" "^          previousImage: \"${PREV}\"$" "agent chart 0.56.0: waitJob.previousImage is previousWaitImage"
has "${PWA}" '^          image: "ghcr.io/acme/clearance-wait@sha256:bbbb"$' "agent chart 0.56.0: waitJob.image stays the new digest"
grep -B1 '^          previousImage:' "${PWA}" | head -1 | grep -q '^          #' && ok "agent chart 0.56.0: previousImage sits in waitJob, after its comment" || bad "agent chart 0.56.0: previousImage is not where waitJob.image is"
new "${TMP}/gate-pwj-none" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.56.0
render_ok "${TMP}/gate-pwj-none" "agent chart 0.56.0 without previousWaitImage"
if grep -q 'previousImage' "${TMP}/gate-pwj-none/56-clearance-gate/agent/application.yaml"; then bad "no previousWaitImage: waitJob.previousImage rendered"; else ok "no previousWaitImage: no waitJob.previousImage"; fi
new "${TMP}/gate-pwj-old" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme "${PWJ[@]}" \
  --set versions.clearance.argocdAgentChart=0.55.0 --set "versions.clearance.previousWaitImage=${PREV}"
out="$(python3 hack/check.py --cluster "${TMP}/gate-pwj-old/cluster.yaml" 2>&1)" && bad "previousWaitImage on an agent chart before 0.56.0 passed check" \
  || { grep -q 'argocdAgentChart 0.56.0 or later' <<<"${out}" && ok "previousWaitImage on an agent chart before 0.56.0 is refused by check" || bad "previousWaitImage, old agent chart: ${out}"; }
if python3 hack/render.py --cluster "${TMP}/gate-pwj-old/cluster.yaml" >/dev/null 2>&1; then bad "previousWaitImage on an agent chart before 0.56.0 rendered"; else ok "previousWaitImage on an agent chart before 0.56.0 does not render"; fi
python3 hack/render.py --no-check --cluster "${TMP}/gate-pwj-old/cluster.yaml" >/dev/null 2>&1 || bad "previousWaitImage, old agent chart, --no-check: render failed"
if grep -q 'previousImage' "${TMP}/gate-pwj-old/56-clearance-gate/agent/application.yaml"; then bad "agent chart 0.55.0: waitJob.previousImage rendered"; else ok "agent chart 0.55.0 (--no-check): no waitJob.previousImage, the chart has none"; fi
has "${TMP}/gate-pwj-old/56-clearance-gate/admission.yaml" "variables.waitctr.image in \\['ghcr.io/acme/clearance-wait@sha256:bbbb', '${PREV}'\\] &&" "agent chart 0.55.0 (--no-check): the exemption still admits both wait images"
# The gate's clients' CA (A-19, plan steps 4 and 5b): off, no CA in the sidecars or the agent; on, each names the ConfigMap.
AGA="${TMP}/gate-agent/56-clearance-gate/agent/application.yaml"
RSA="${TMP}/gate-agent/01-argocd-platform/argocd-apps-install/application.yaml"
if grep -q 'clearance-ca\|CLEARANCE_CA_FILE\|CLEARANCE_WAIT_CA_CONFIGMAP' "${RSA}" || grep -q 'caConfigMap' "${AGA}"; then
  bad "gate CA off: a CA setting rendered"; else ok "gate CA off: no CA in the sidecar or the agent"; fi
new "${TMP}/gate-ca" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=https://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=https://clearance-api.hangar-dev.local \
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.54.0 \
  --set clearance.gate.caConfigMap=hangar-cluster-ca --set clearance.gate.waitCAConfigMap=hangar-cluster-ca --set clearance.gate.waitCAInject=true \
  --set clearance.gate.canary.image=ghcr.io/acme/clearance-cmp@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-ca" "gate on with the clients' CA"
RSC="${TMP}/gate-ca/01-argocd-platform/argocd-apps-install/application.yaml"
AGC="${TMP}/gate-ca/56-clearance-gate/agent/application.yaml"
[ "$(grep -c 'name: CLEARANCE_CA_FILE, value: /etc/clearance-ca/ca.crt' "${RSC}")" = 2 ] && ok "caConfigMap: both sidecars read the CA file" || bad "caConfigMap: CLEARANCE_CA_FILE is not on both sidecars"
[ "$(grep -c 'name: clearance-ca, mountPath: /etc/clearance-ca, readOnly: true' "${RSC}")" = 2 ] && ok "caConfigMap: both sidecars mount the CA read-only" || bad "caConfigMap: the CA mount is not on both sidecars"
[ "$(grep -c 'name: CLEARANCE_WAIT_CA_CONFIGMAP, value: "hangar-cluster-ca"' "${RSC}")" = 2 ] && ok "waitCAInject: both sidecars inject the wait Job's CA" || bad "waitCAInject: CLEARANCE_WAIT_CA_CONFIGMAP is not on both sidecars"
# clearance.gate.fsSandbox (A-24): unset, no CLEARANCE_CMP_FS_SANDBOX renders (gate-agent, gate-ca above); set, both sidecars carry it;
# a value other than try, require or off is refused by render and check.
if grep -q 'CLEARANCE_CMP_FS_SANDBOX' "${RSA}" "${RSC}"; then bad "fsSandbox unset: the env rendered"; else ok "fsSandbox unset: no CLEARANCE_CMP_FS_SANDBOX"; fi
new "${TMP}/gate-fs" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=https://clearance.hangar-dev.local \
  --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local --set 'clearance.gate.apps=[gate-api]' \
  --set clearance.gate.fsSandbox=require \
  --set clearance.gate.canary.image=ghcr.io/acme/clearance-cmp@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-fs" "gate on with fsSandbox require"
[ "$(grep -c 'name: CLEARANCE_CMP_FS_SANDBOX, value: "require"' "${TMP}/gate-fs/01-argocd-platform/argocd-apps-install/application.yaml")" = 2 ] \
  && ok "fsSandbox: both sidecars set CLEARANCE_CMP_FS_SANDBOX" || bad "fsSandbox: CLEARANCE_CMP_FS_SANDBOX is not on both sidecars"
python3 hack/check.py --cluster "${TMP}/gate-fs/cluster.yaml" >/dev/null 2>&1 && ok "fsSandbox: check accepts require" || bad "fsSandbox: check refused require"
mkdir -p "${TMP}/gate-fs-bad"
sed 's/fsSandbox: require/fsSandbox: strict/' "${TMP}/gate-fs/cluster.yaml" >"${TMP}/gate-fs-bad/cluster.yaml"
grep -q 'fsSandbox: strict' "${TMP}/gate-fs-bad/cluster.yaml" || bad "fsSandbox: the bad-value fixture did not take"
out="$(python3 hack/render.py --cluster "${TMP}/gate-fs-bad/cluster.yaml" 2>&1)" && bad "fsSandbox: a bad value rendered" \
  || { grep -q 'clearance.gate.fsSandbox' <<<"${out}" && ok "fsSandbox: a bad value is refused by render" || bad "fsSandbox: bad value refusal text: ${out}"; }
out="$(python3 hack/check.py --cluster "${TMP}/gate-fs-bad/cluster.yaml" 2>&1)" && bad "fsSandbox: check accepted a bad value" \
  || { grep -q 'clearance.gate.fsSandbox' <<<"${out}" && ok "fsSandbox: a bad value is refused by check" || bad "fsSandbox: check refusal text: ${out}"; }
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${RSC}" "${AGC}" <<'PY' && ok "gate CA: the repo-server volume is the ConfigMap's ca.crt only; the agent's tls.caConfigMap and waitJob.caConfigMap name it" || bad "gate CA: the rendered values are wrong"
import sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
vols = app["spec"]["source"]["helm"]["valuesObject"]["repoServer"]["volumes"]
ca = [x for x in vols if x["name"] == "clearance-ca"]
assert ca == [{"name": "clearance-ca", "configMap": {"name": "hangar-cluster-ca", "items": [{"key": "ca.crt", "path": "ca.crt"}]}}], ca
ag = yaml.safe_load(open(sys.argv[2]))["spec"]["source"]["helm"]["valuesObject"]
assert ag["tls"] == {"caConfigMap": "hangar-cluster-ca"}, ag.get("tls")
assert ag["waitJob"]["caConfigMap"] == "hangar-cluster-ca", ag["waitJob"]
PY
fi
new "${TMP}/gate-ca-old" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]' \
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.53.0 \
  --set clearance.gate.caConfigMap=hangar-cluster-ca
out="$(python3 hack/render.py --cluster "${TMP}/gate-ca-old/cluster.yaml" 2>&1)" && bad "gate CA on an agent chart before 0.54.0 rendered" \
  || { grep -q 'argocdAgentChart 0.54.0 or later' <<<"${out}" && ok "gate CA on an agent chart before 0.54.0 is refused" || bad "gate CA, old agent chart: ${out}"; }
new "${TMP}/gate-ca-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'clearance.gate.caConfigMap=Not_A_Name'
out="$(python3 hack/render.py --cluster "${TMP}/gate-ca-bad/cluster.yaml" 2>&1)" && bad "a caConfigMap that is not a ConfigMap name rendered" \
  || { grep -q 'clearance.gate.caConfigMap is' <<<"${out}" && ok "a caConfigMap that is not a ConfigMap name is refused" || bad "bad caConfigMap: ${out}"; }
# The grant-expiry webhook, agent HA, the status heartbeat and the alerts (I-44; agent chart 0.55.0): unset, none renders (gate-agent
# above); set, the agent's values carry them; check refuses a bad value, a missing prerequisite and the chart's gate.enforce rule.
if grep -qE 'grantExpiry|^ *ha:|statusHeartbeat|alerts:|^ *gate:|previousURL' "${AGA}"; then bad "I-44 unset: a setting rendered in the agent"; else ok "I-44 unset: no grantExpiry, ha, statusHeartbeat, alerts or gate in the agent"; fi
AGENT_SET=(--set clearance.gate.url=http://clearance.hangar-dev.local --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local
  --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]'
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.55.0)
i44() { # i44 NAME [more --set flags]: a prod cluster with the gate and its agent
  local d="${TMP}/$1"; shift
  new "${d}" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" "${AGENT_SET[@]}" "$@"
}
i44_refused() { # i44_refused NAME TEXT LABEL: render and check both refuse, naming TEXT
  local out
  out="$(python3 hack/render.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: rendered"; return; }
  grep -qF -- "$2" <<<"${out}" || { bad "$3: render's refusal: ${out}"; return; }
  out="$(python3 hack/check.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: check accepted it"; return; }
  grep -qF -- "$2" <<<"${out}" && ok "$3 is refused" || bad "$3: check's refusal: ${out}"
}
i44 gate-i44 --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.ha.enabled=true \
  --set clearance.gate.agent.statusHeartbeat=5m --set clearance.gate.agent.alerts.enabled=true --set clearance.gate.previousURL=http://clearance-old.hangar-dev.local
render_ok "${TMP}/gate-i44" "gate agent with grantExpiry (audit), ha, statusHeartbeat and alerts"
AGI="${TMP}/gate-i44/56-clearance-gate/agent/application.yaml"
has "${AGI}" '^        grantExpiry: \{"enabled": true, "argocdUser": "system:serviceaccount:argocd-apps:argocd-application-controller"\}$' "grantExpiry: enabled, audit by the chart's default, the policy's controller"
has "${AGI}" '^          previousURL: "http://clearance-old.hangar-dev.local"$' "grantExpiry with previousURL: the webhook exempts the previous URL's wait Job too"
if grep -q '^ *gate:' "${AGI}"; then bad "gate.enforce off: the agent was told the policy enforces"; else ok "gate.enforce off: no gate values in the agent"; fi
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${AGI}" <<'PY' && ok "I-44: the agent's values are the chart's keys" || bad "I-44: the agent's rendered values are wrong"
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["spec"]["source"]["helm"]["valuesObject"]
assert v["ha"] == {"enabled": True}, v.get("ha")
assert v["statusHeartbeat"] == "5m", v.get("statusHeartbeat")
assert v["alerts"] == {"enabled": True, "labels": {"release": "kube-prometheus-stack"}}, v.get("alerts")
assert v["waitJob"]["previousURL"] == "http://clearance-old.hangar-dev.local", v["waitJob"]
PY
fi
i44 gate-i44-enf --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.grantExpiry.mode=enforce \
  --set clearance.gate.enforce=true --set clearance.gate.argocdServiceAccount=argocd-apps:my-controller
render_ok "${TMP}/gate-i44-enf" "gate.enforce with an enforcing grant-expiry webhook"
AGE="${TMP}/gate-i44-enf/56-clearance-gate/agent/application.yaml"
has "${AGE}" '^        grantExpiry: \{"enabled": true, "enforce": true, "argocdUser": "system:serviceaccount:argocd-apps:my-controller"\}$' "grantExpiry mode enforce: the chart's enforce, the named controller"
has "${AGE}" '^          enforce: true$' "gate.enforce: the agent chart is told the policy denies"
if grep -q 'previousURL' "${AGE}"; then bad "no previousURL: one rendered"; else ok "no previousURL: none in the agent"; fi
i44 gate-i44-enf-audit --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.enforce=true
i44_refused gate-i44-enf-audit "clearance.gate.enforce needs clearance.gate.agent.grantExpiry {enabled: true, mode: enforce}" "gate.enforce with the webhook in audit"
i44 gate-i44-enf-none --set clearance.gate.enforce=true
i44_refused gate-i44-enf-none "clearance.gate.enforce needs clearance.gate.agent.grantExpiry" "gate.enforce without the webhook"
i44 gate-i44-risk --set clearance.gate.enforce=true --set clearance.gate.agent.grantExpiry.acceptResidualRisk=true
render_ok "${TMP}/gate-i44-risk" "gate.enforce without the webhook, acceptResidualRisk"
has "${TMP}/gate-i44-risk/56-clearance-gate/agent/application.yaml" '^        grantExpiry: \{"acceptResidualRisk": true\}$' "acceptResidualRisk alone: only the override renders"
i44 gate-i44-enf-old --set clearance.gate.enforce=true --set versions.clearance.argocdAgentChart=0.54.0
render_ok "${TMP}/gate-i44-enf-old" "gate.enforce on an agent chart before 0.55.0 (no webhook to require)"
i44 gate-i44-mode --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.grantExpiry.mode=strict
i44_refused gate-i44-mode "clearance.gate.agent.grantExpiry.mode is 'strict'" "a grantExpiry mode other than audit or enforce"
i44 gate-i44-enf-off --set clearance.gate.agent.grantExpiry.mode=enforce
i44_refused gate-i44-enf-off "mode: enforce needs grantExpiry.enabled: true" "grantExpiry mode enforce without enabled"
i44 gate-i44-typo --set clearance.gate.agent.grantExpiry.enable=true
i44_refused gate-i44-typo "clearance.gate.agent.grantExpiry.enable is not a setting" "an unknown grantExpiry key"
i44 gate-i44-old --set clearance.gate.agent.grantExpiry.enabled=true --set versions.clearance.argocdAgentChart=0.54.0
i44_refused gate-i44-old "need versions.clearance.argocdAgentChart 0.55.0 or later" "grantExpiry on an agent chart before 0.55.0"
i44 gate-i44-nocm --set clearance.gate.agent.grantExpiry.enabled=true --set components.certManager=false
i44_refused gate-i44-nocm "clearance.gate.agent.grantExpiry needs components.certManager" "grantExpiry without cert-manager"
i44 gate-i44-hb --set clearance.gate.agent.statusHeartbeat=5m30s
i44_refused gate-i44-hb "clearance.gate.agent.statusHeartbeat is '5m30s'" "a statusHeartbeat of two units"
i44 gate-i44-al-hb --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-hb "clearance.gate.agent.alerts needs statusHeartbeat" "alerts without statusHeartbeat"
i44 gate-i44-al-ge --set clearance.gate.agent.statusHeartbeat=5m --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-ge "clearance.gate.agent.alerts needs grantExpiry.enabled" "alerts without the webhook"
i44 gate-i44-al-slow --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.statusHeartbeat=15m --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-slow "must be below 15m with alerts" "a statusHeartbeat not below the alert's staleness"
i44 gate-i44-al-obs --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.statusHeartbeat=5m \
  --set clearance.gate.agent.alerts.enabled=true --set components.observability=false
i44_refused gate-i44-al-obs "clearance.gate.agent.alerts needs components.observability" "alerts without kube-prometheus-stack"
has "${TMP}/gate-agent/56-clearance-gate/agent/application.yaml" 'clearance-api.hangar-dev.local' "gate.agent: the agent's host alias names clearance-api"
has "${TMP}/gate-agent/01-argocd-platform/argocd-apps-install/application.yaml" 'hostAliases: \[\{"ip": "192.0.2.1"' "gate.hostAlias: the repo-server gets it"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'value: "http://clearance.hangar-dev.local"' "gate on: the sidecar reaches the core at clearance.gate.url"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'audience: clearance' "gate on: the clearance token is a projected, audience-bound service-account token"
if grep -n 'clearance-cmp\|name: clearance$' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml" "${TMP}/lab/prod/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" | grep -v '^[^:]*:[0-9]*: *#' | grep -q .; then
  bad "gate off: the plugin leaked into a cluster that did not ask for it"
else
  ok "gate off: no sidecar and no plugin source"
fi
if grep -q 'CLEARANCE_CHART_REPOS' "${TMP}/lab/prod/01-argocd-platform/argocd-apps-install/application.yaml"; then bad "gate off: the chart allow list leaked into a cluster that did not ask for it"; else ok "gate off: no chart allow list"; fi
# clearance.gate.canary: a second sidecar from another image, named by the listed apps only. Unset, nothing differs.
CANARY=ghcr.io/acme/clearance-cmp@sha256:2222222222222222222222222222222222222222222222222222222222222222
CMPAPP="${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml"
if grep -q 'clearance-canary\|clearance-cmp-canary\|cmp-tmp-canary' "${CMPAPP}" "${AS}"; then bad "canary unset: a canary sidecar, volume or plugin name rendered"; else ok "canary unset: no canary sidecar, volume or plugin name (the render is today's)"; fi
new "${TMP}/gate-canary" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[gate-api]'
render_ok "${TMP}/gate-canary" "gate on with a canary plugin"
CA="${TMP}/gate-canary/01-argocd-platform/argocd-apps-install/application.yaml"
CAS="${TMP}/gate-canary/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${CA}" "name: clearance-cmp-canary" "canary: a second sidecar"
has "${CA}" "image: ${CANARY}" "canary: it runs the canary image"
has "${CA}" "image: ghcr.io/acme/clearance-cmp@sha256:aaaa" "canary: the first sidecar keeps the default image"
has "${CA}" "command: \[/var/run/argocd/argocd-cmp-server, --config-dir-path, /home/argocd/cmp-server/config-canary\]" "canary: it registers the image's canary plugin.yaml"
has "${CA}" "name: cmp-tmp-canary, emptyDir" "canary: its own /tmp volume, not the first sidecar's"
has "${CAS}" 'name: \{\{ if regexMatch "\^\(gate-api\)\$" .appName \}\}clearance-canary\{\{ else \}\}clearance\{\{ end \}\}' "canary: only the listed apps name clearance-canary"
if [ "$(grep -c 'cmp-tmp-canary' "${CA}")" = 2 ] && [ "$(grep -c 'mountPath: /tmp$' "${CA}")" = 0 ]; then ok "canary: cmp-tmp-canary is declared once and mounted once"; else bad "canary: cmp-tmp-canary is not declared and mounted exactly once"; fi
# the second sidecar has the first's settings and security context: the two blocks are equal once the three canary-only lines are dropped
python3 - "${CA}" <<'PY' && ok "canary: same settings and security context as the first sidecar" || bad "canary: the sidecars differ beyond image, command and tmp volume"
import sys, re
lines = open(sys.argv[1]).read().split("\n")
def block(name):
    i = next(n for n, l in enumerate(lines) if l.strip() == "- name: " + name)
    ind = len(lines[i]) - len(lines[i].lstrip())
    out = []
    for l in lines[i + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) <= ind:
            break
        out.append(l)
    return out
def norm(b, tmp):
    return [l.replace(tmp, "cmp-tmp-X") for l in b if not l.lstrip().startswith(("image:", "command:", "#"))]
a, b = norm(block("clearance-cmp"), "cmp-tmp,"), norm(block("clearance-cmp-canary"), "cmp-tmp-canary,")
sys.exit(0 if a == b and any("readOnlyRootFilesystem: true" in l for l in a) and len(a) > 15 else 1)
PY
for BAD in "clearance.gate.canary.image=ghcr.io/acme/clearance-cmp:latest" "clearance.gate.canary.apps=[]" "clearance.gate.canary.apps=[Bad_App]" "clearance.gate.canary.apps=gate-api"; do
  new "${TMP}/gate-canary-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
    --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[gate-api]' --set "${BAD}"
  if python3 hack/render.py --cluster "${TMP}/gate-canary-bad/cluster.yaml" >/dev/null 2>&1; then bad "canary ${BAD}: accepted"; else ok "canary ${BAD}: refused"; fi
done
new "${TMP}/gate-canary-out" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set "clearance.gate.canary.image=${CANARY}" --set 'clearance.gate.canary.apps=[other-app]' --set 'clearance.gate.apps=[gate-api]'
if python3 hack/render.py --cluster "${TMP}/gate-canary-out/cluster.yaml" >/dev/null 2>&1; then bad "canary app outside clearance.gate.apps: accepted"; else ok "canary app outside clearance.gate.apps: refused (the gate does not cover it)"; fi
# G-ARGO-10c on a lower cluster that runs the core (a rehearsal): the gate stack on a lower zone, no tenant Application on the plugin,
# the agent's annotation opt-in and environment, and the core's NetworkPolicies for the repo-server and the agent. All off by default.
OPT_PROV='clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: [clearance-system/clearance-argocd-agent], protection: ["clearance-system/clearance-argocd-agent=hangar-dev"]}]'
OPT_SET=(--set clearance.gate.enabled=true --set clearance.gate.lowerZone=true --set clearance.gate.tenantPlugin=false
  --set versions.clearance.cmpImage=ghcr.io/acme/clearance-cmp@sha256:aaaa --set versions.clearance.waitImage=ghcr.io/acme/clearance-wait@sha256:bbbb --set versions.clearance.previousWaitImage=
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc
  --set clearance.gate.agent.apiURL=http://clearance-api.clearance-system.svc:8080 --set 'clearance.gate.agent.projects=[rehearsal]'
  --set 'clearance.gate.agent.protectedNamespaces=[rehearsal]' --set clearance.gate.agent.environment=dev --set clearance.gate.agent.optIn=true
  --set "${OPT_PROV}")
new "${TMP}/gate-opt" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}"
render_ok "${TMP}/gate-opt" "lower cluster, gate with the opt-in"
expect "${TMP}/gate-opt" "gate.lowerZone" 56-clearance-gate/admission.yaml 56-clearance-gate/clearancegrant-crd.yaml 56-clearance-gate/agent/application.yaml
OA="${TMP}/gate-opt/56-clearance-gate/agent/application.yaml"
has "${OA}" '^        optIn:$' "gate.agent.optIn: the agent's chart gets optIn"
has "${OA}" '^          enabled: true$' "gate.agent.optIn: enabled"
has "${OA}" '^        environment: "dev"$' "gate.agent.environment: the agent's default environment"
has "${TMP}/gate-opt/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" 'regexMatch "\^\$" .appName' "gate.tenantPlugin false: no app name matches the plugin regex"
# W-43 (clearance.gate.agent.gatedSet, default off): with it off the tenant-onboarding chart is what it was, even with optIn on;
# with it on the chart renders two ApplicationSets (tenant-onboarding, tenant-onboarding-gated) from one template. What the
# controller does with them is tested against the real Argo CD ApplicationSet controller in tests/appset (section 5).
for NOOPT in "${TMP}/gate-opt" "${TMP}/gate-agent" "${TMP}/gate" "${LAB}/prod"; do
  if grep -q 'ignoreApplicationDifferences\|preservedFields\|clearanceGate\|clearance.hangar.io/protect\|__SET_\|_SET_ONLY__\|tenant-onboarding-gated\|applicationsSync' \
      "${NOOPT}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" "${NOOPT}/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml"; then
    bad "no gatedSet (${NOOPT##*/}): the tenant-onboarding chart mentions the gated set"
  else ok "no gatedSet (${NOOPT##*/}): the tenant-onboarding chart is as before (one ApplicationSet, no selector, no ignore rule)"; fi
done
has "${TMP}/gate-opt/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml" '^\{\{- \.Files\.Get "applicationset\.tmpl\.yaml"$' "gatedSet off: render.yaml emits the template once, as before"
GS="${TMP}/gate-set"
new "${GS}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" --set clearance.gate.agent.gatedSet=true
render_ok "${GS}" "gate opt-in with the gated set"
GSA="${GS}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; GSR="${GS}/02-argocd-apps/tenant-onboarding/chart/templates/render.yaml"
has "${GSA}" '^  name: __SET_NAME__$' "gatedSet: the ApplicationSet's name is the set's"
has "${GSA}" '^            operator: __SET_SELECTOR_OPERATOR__$' "gatedSet: the generator selects on clearanceGate"
has "${GSA}" '^  __GATED_SET_ONLY__  - jsonPointers: \[/spec/source, /spec/sources\]$' "gatedSet: the source ignore rule is marked gated-set-only"
has "${GSA}" '^  __GATED_SET_ONLY__  annotations: \[clearance.hangar.io/switched\]$' "gatedSet: preservedFields keeps the agent's switched marker (gated set only)"
has "${GSA}" '^      __TENANT_SET_ONLY__  - resources-finalizer.argocd.argoproj.io$' "gatedSet: the resources finalizer is tenant-onboarding's only"
has "${GSA}" '^    \{\{- if and __SET_STATIC_PLUGIN__ \(regexMatch' "gatedSet: the static plugin source is switched per set"
[ "$(grep -c '^        __GATED_SET_ONLY__- repoURL: "{{.gitopsRepoUrl}}"$' "${GSA}")" = 2 ] && [ "$(grep -c '^        __TENANT_SET_ONLY__- repoURL: "{{.gitopsRepoUrl}}"$' "${GSA}")" = 2 ] \
  && ok "gatedSet: the gated set lists the \$appsrc source first (the agent's carrier), tenant-onboarding after the chart (template and templatePatch)" \
  || bad "gatedSet: the \$appsrc source is not ordered per set in both the template and the templatePatch"
has "${GSR}" '"__SET_NAME__" "tenant-onboarding-gated"' "gatedSet: render.yaml emits tenant-onboarding-gated"
has "${GSR}" '"__SET_SELECTOR_OPERATOR__" "NotIn"' "gatedSet: tenant-onboarding excludes the gated environments"
if grep -q 'applicationsSync' "${GSA}"; then bad "gatedSet without gatedSetHandover: applicationsSync rendered"; else ok "gatedSet without gatedSetHandover: no applicationsSync (both sets delete what they stop generating, as before)"; fi
GSH="${TMP}/gate-set-handover"
new "${GSH}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSet=true --set clearance.gate.agent.gatedSetHandover=true
render_ok "${GSH}" "gate opt-in with the gated set and the handover window"
has "${GSH}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^    applicationsSync: create-update$' "gatedSetHandover: both sets create-update (no deletion)"
# The handover window relies on the controller honouring applicationsSync: no controller-wide policy on argocd-apps' ApplicationSet controller.
if grep -q 'applicationsetcontroller.policy' templates/01-argocd-platform/argocd-apps-install/application.yaml; then bad "argocd-apps-install sets applicationsetcontroller.policy: an ApplicationSet's applicationsSync would be ignored"; else ok "argocd-apps-install sets no controller-wide applicationsetcontroller.policy (applicationsSync is honoured)"; fi
for BADP in "clearance.gate.agent.gatedSet=maybe|agent.gatedSet is true or false" "clearance.gate.agent.gatedSetHandover=yes|gatedSetHandover is true or false" \
            "clearance.gate.agent.optIn=false|gatedSet needs the gate and its agent" "clearance.gate.lowerZone=false|gatedSet needs the gate and its agent" \
            "clearance.gate.tenantPlugin=true|gatedSet needs clearance.gate.tenantPlugin: false"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-set-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
    --set clearance.gate.agent.gatedSet=true --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-set-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "gated set ${BAD}: refused (${WANT})"; else bad "gated set ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
new "${TMP}/gate-set-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSetHandover=true
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-set-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -qF -- "gatedSetHandover is the handover window" <<<"${BADERR}"; then ok "gatedSetHandover without gatedSet: refused"; else bad "gatedSetHandover without gatedSet: rc=${BADRC} ${BADERR}"; fi
# W-42 (clearance.gate.agent.rule, agent chart 0.56.0 gateRule): unset, nothing renders (every agent above is as before); set, it
# is passed through verbatim, and check holds it to the opt-in, the chart, its own shape and the project and namespace ceiling
# (derived from the rule's literal values when unset). ruleOptions is the chart's gateRuleOptions, only the keys set.
for NORULE in "${TMP}/gate-opt" "${TMP}/gate-agent" "${GS}"; do
  if grep -q 'gateRule' "${NORULE}/56-clearance-gate/agent/application.yaml"; then bad "no rule (${NORULE##*/}): gateRule or gateRuleOptions rendered"; else ok "no rule (${NORULE##*/}): no gateRule in the agent (the render is today's)"; fi
done
RULE1='clearance.gate.agent.rule={version: 1, select: [{name: rehearsal, projects: [rehearsal], namespaces: [rehearsal]}, {name: prod-label, projects: [rehearsal], labels: {hangar.io/env: "prod"}}], exempt: [{application: argocd-apps/web-prod, reason: "a migration to the new chart", expires: "2026-12-19", ref: W-45}]}'
rule() { # rule NAME [more --set flags]: the dev opt-in rehearsal (OPT_SET) with more settings
  local d="${TMP}/$1"; shift
  new "${d}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "$@"
}
rule_refused() { # rule_refused NAME TEXT LABEL: check and render both refuse, naming TEXT
  local out
  out="$(python3 hack/check.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: check accepted it"; return; }
  grep -qF -- "$2" <<<"${out}" || { bad "$3: check's refusal: ${out}"; return; }
  out="$(python3 hack/render.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: rendered"; return; }
  grep -qF -- "$2" <<<"${out}" && ok "$3 is refused" || bad "$3: render's refusal: ${out}"
}
rule gate-rule --set "${RULE1}"
render_ok "${TMP}/gate-rule" "gate opt-in with the gate rule"
GRA="${TMP}/gate-rule/56-clearance-gate/agent/application.yaml"
has "${GRA}" '^        gateRule: \{"version": 1, "select": \[\{"name": "rehearsal", ' "rule: the agent chart's gateRule is the rule, as one JSON flow mapping"
has "${GRA}" '^          projects: \["rehearsal"\]$' "rule with projects set: the ceiling is clearance.gate.agent.projects"
if grep -q 'gateRuleOptions' "${GRA}"; then bad "rule without ruleOptions: gateRuleOptions rendered"; else ok "rule without ruleOptions: the chart's own bounds (no gateRuleOptions)"; fi
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${GRA}" "${TMP}/gate-rule/cluster.yaml" <<'PY' && ok "rule: the rendered gateRule is exactly cluster.yaml's rule (verbatim), beside optIn" || bad "rule: the rendered gateRule differs from cluster.yaml's"
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["spec"]["source"]["helm"]["valuesObject"]
want = yaml.safe_load(open(sys.argv[2]))["clearance"]["gate"]["agent"]["rule"]
assert v["gateRule"] == want, (v["gateRule"], want)
assert v["optIn"] == {"enabled": True}, v["optIn"]
assert want["select"][1]["labels"] == {"hangar.io/env": "prod"} and want["exempt"][0]["expires"] == "2026-12-19", want
PY
fi
# The ceiling derived from the rule (projects and protectedNamespaces unset): the literal values, in order, once each.
rule gate-rule-derive --set 'clearance.gate.agent.projects=' --set 'clearance.gate.agent.protectedNamespaces=' \
  --set 'clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a, team-b], namespaces: [app-a-dev]}, {name: b, projects: [team-a], namespaces: [app-b-dev, app-a-dev]}]}' \
  --set 'clearance.gate.agent.ownedProject={create: true}'
render_ok "${TMP}/gate-rule-derive" "gate rule with the ceiling derived from it"
GRD="${TMP}/gate-rule-derive/56-clearance-gate/agent"
has "${GRD}/application.yaml" '^          projects: \["team-a", "team-b"\]$' "rule, projects unset: the ceiling is the rule's literal projects"
has "${GRD}/application.yaml" '^        protectedNamespaces: \["app-a-dev", "app-b-dev"\]$' "rule, protectedNamespaces unset: the rule's literal namespaces"
has "${GRD}/owned.yaml" '^  name: "app-b-dev"$' "rule with ownedProject: the derived namespaces are the ones owned"
rule gate-rule-opts --set "${RULE1}" --set 'clearance.gate.agent.ruleOptions={releaseMax: 1, exemptMax: 720h}'
render_ok "${TMP}/gate-rule-opts" "gate rule with ruleOptions"
has "${TMP}/gate-rule-opts/56-clearance-gate/agent/application.yaml" '^        gateRuleOptions: \{"releaseMax": 1, "exemptMax": "720h"\}$' "ruleOptions: the chart's gateRuleOptions, only the keys set"
# globs: a glob project passes only against "*"; a glob namespace against a listed namespace it matches
rule gate-rule-glob --set 'clearance.gate.agent.projects=["*"]' --set 'clearance.gate.agent.protectedNamespaces=[app-a-prod, app-b-prod]' \
  --set 'clearance.gate.agent.rule={version: 1, select: [{name: prod, projects: ["team-*"], namespaces: ["app-*-prod"]}]}'
render_ok "${TMP}/gate-rule-glob" "gate rule with glob projects and namespaces inside an explicit ceiling"
rule gate-rule-empty --set 'clearance.gate.agent.rule={}'
render_ok "${TMP}/gate-rule-empty" "an empty gate rule"
if grep -q 'gateRule' "${TMP}/gate-rule-empty/56-clearance-gate/agent/application.yaml"; then bad "an empty rule: gateRule rendered"; else ok "an empty rule renders as unset (nothing)"; fi
rule gate-rule-noselect --set 'clearance.gate.agent.rule={version: 1}'
render_ok "${TMP}/gate-rule-noselect" "a rule that selects nothing (the first rollout step)"
has "${TMP}/gate-rule-noselect/56-clearance-gate/agent/application.yaml" '^        gateRule: \{"version": 1\}$' "a rule that selects nothing: gateRule {version: 1}"
# The rule and the gated set: the gated set keeps what the agent asks of a ruled ApplicationSet child (the switched marker preserved,
# the sources ignored), unconditionally; the rule does not change the tenant-onboarding chart.
rule gate-rule-set --set "${RULE1}" --set clearance.gate.agent.gatedSet=true
render_ok "${TMP}/gate-rule-set" "gate rule with the gated set"
diff -r "${GS}/02-argocd-apps" "${TMP}/gate-rule-set/02-argocd-apps" >/dev/null && ok "rule with gatedSet: the tenant-onboarding chart is the gated set's, unchanged" || bad "rule with gatedSet: the rule changed the tenant-onboarding chart"
has "${TMP}/gate-rule-set/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^  __GATED_SET_ONLY__  annotations: \[clearance.hangar.io/switched\]$' "rule with gatedSet: preservedFields keeps clearance.hangar.io/switched"
has "${TMP}/gate-rule-set/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" '^  __GATED_SET_ONLY__  - jsonPointers: \[/spec/source, /spec/sources\]$' "rule with gatedSet: ignoreApplicationDifferences on /spec/source and /spec/sources"
diff -r "${TMP}/gate-opt/02-argocd-apps" "${TMP}/gate-rule/02-argocd-apps" >/dev/null && ok "rule without gatedSet: the tenant-onboarding chart is unchanged" || bad "rule without gatedSet: the tenant-onboarding chart changed"
for BADP in \
    "clearance.gate.agent.optIn=false|rule needs clearance.gate.agent.optIn: true" \
    "versions.clearance.argocdAgentChart=0.55.0|rule needs versions.clearance.argocdAgentChart 0.56.0 or later" \
    "clearance.gate.lowerZone=false|rule and ruleOptions need the gate and its agent on this cluster" \
    "clearance.gate.agent.rule=nope|clearance.gate.agent.rule is a mapping" \
    "clearance.gate.agent.rule={version: 2}|rule.version is 2: it must be 1" \
    "clearance.gate.agent.rule={version: 1, selects: []}|rule.selects is not a setting" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a}]}|names none of projects, namespaces and labels" \
    "clearance.gate.agent.rule={version: 1, select: [{name: Bad_Name, projects: [rehearsal]}]}|needs a name, a DNS label" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal]}, {name: a, projects: [rehearsal]}]}|the name a is used twice" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, project: [rehearsal]}]}|select[0] (a).project is not a setting" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: rehearsal}]}|projects is a non-empty list of globs" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], labels: {tier: 1}}]}|labels is a non-empty mapping of label key to exact value" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [other]}]}|project other is not in clearance.gate.agent.projects" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [\"team-*\"]}]}|is a glob, and clearance.gate.agent.projects does not hold" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], namespaces: [other]}]}|namespace other is not in clearance.gate.agent.protectedNamespaces" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [rehearsal], namespaces: [\"app-*\"]}]}|matches none of clearance.gate.agent.protectedNamespaces" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: short, expires: \"2026-12-19\"}]}|reason is 10 to 500 characters" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"next week\"}]}|expires is 'next week'" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"2026-02-30\"}]}|expires is '2026-02-30'" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd/web, reason: \"a long enough reason\", expires: \"2026-12-19\"}]}|can never match: the agent reads Applications in argocd-apps" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: web, reason: \"a long enough reason\", expires: \"2026-12-19\"}]}|a glob on <namespace>/<name>" \
    "clearance.gate.agent.rule={version: 1, exempt: [{application: argocd-apps/web, reason: \"a long enough reason\", expires: \"2026-12-19\", approvedBy: me}]}|exempt[0].approvedBy is not a setting" \
    "clearance.gate.agent.ruleOptions={releaseMax: 2}|ruleOptions needs clearance.gate.agent.rule" \
    "${RULE1}|clearance.gate.agent.ruleOptions={releaseMax: 0}|releaseMax is 0" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptMax: 2400h}|is over 2160h" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 30s}|exemptionRecheckTimeout must be below exemptionRecheck" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 5 minutes}|exemptionRecheck is '5 minutes'" \
    "${RULE1}|clearance.gate.agent.ruleOptions={releasemax: 1}|ruleOptions.releasemax is not a setting" \
    "${RULE1}|clearance.gate.agent.ruleOptions={exemptionRecheck: 3000000h}|exemptionRecheck is '3000000h'" \
    "${RULE1}|clearance.gate.agent.projects=[\"team-*\"]|the agent compares its projects exactly" \
    "${RULE1}|clearance.gate.agent.protectedNamespaces=[\"app-*\"]|the agent's RBAC is one Role per listed namespace"; do
  WANT="${BADP##*|}"; SETS="${BADP%|*}"
  ARGS=()
  while [ -n "${SETS}" ]; do
    case "${SETS}" in *'|'*) ARGS+=(--set "${SETS%%|*}"); SETS="${SETS#*|}" ;; *) ARGS+=(--set "${SETS}"); SETS="" ;; esac
  done
  case "${BADP}" in clearance.gate.agent.rule=*|clearance.gate.agent.ruleOptions=*|"${RULE1}|"*) ;; *) ARGS=(--set "${RULE1}" "${ARGS[@]}") ;; esac
  rule gate-rule-bad "${ARGS[@]}"
  LBL="${BADP#"${RULE1}|"}"
  rule_refused gate-rule-bad "${WANT}" "gate rule: ${LBL#clearance.gate.agent.}"
done
# Durations at the edge of Go's int64 nanoseconds: 2562047h is in range (accepted), 2562048h is not (above, refused).
rule gate-rule-maxdur --set "${RULE1}" --set 'clearance.gate.agent.ruleOptions={exemptionRecheck: 2562047h, exemptionRecheckTimeout: 30s}'
python3 hack/check.py --cluster "${TMP}/gate-rule-maxdur/cluster.yaml" >/dev/null 2>&1 && ok "ruleOptions: 2562047h, the largest whole-hour Go duration, is accepted" || bad "ruleOptions: 2562047h refused"
# An empty rule with the gate off is unset (nothing to check); a rule that is not a mapping still needs the gate.
new "${TMP}/gate-rule-off-empty" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.rule={}'
render_ok "${TMP}/gate-rule-off-empty" "gate off with an empty rule"
new "${TMP}/gate-rule-off-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.rule=nope'
rule_refused gate-rule-off-bad "rule and ruleOptions need the gate and its agent on this cluster" "gate off with a rule that is not a mapping"
new "${TMP}/gate-rule-off-opts" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set 'clearance.gate.agent.ruleOptions={releaseMax: 2}'
rule_refused gate-rule-off-opts "rule and ruleOptions need the gate and its agent on this cluster" "gate off with ruleOptions and no rule"
# Derivation refusals: with the ceiling unset, an entry that names no project, a glob project, no namespace or a glob namespace
for BADP in \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, namespaces: [app-a-dev]}]}|names no project, so the project ceiling cannot be derived" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [\"team-*\"], namespaces: [app-a-dev]}]}|which the ceiling cannot be derived from" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a]}]}|names no namespace" \
    "clearance.gate.agent.rule={version: 1, select: [{name: a, projects: [team-a], namespaces: [\"app-*-dev\"]}]}|namespace 'app-*-dev' is a glob: list its namespaces" \
    "clearance.gate.agent.rule={version: 1}|clearance.gate.agent needs projects"; do
  rule gate-rule-bad --set 'clearance.gate.agent.projects=' --set 'clearance.gate.agent.protectedNamespaces=' --set "${BADP%%|*}"
  rule_refused gate-rule-bad "${BADP#*|}" "gate rule, ceiling unset: ${BADP%%|*}"
done
# The migration off the static plugin (apron README "Migrating off the static plugin"): tenantOnboarding.syncPaused, a
# per-environment pause of automated sync, and clearance.gate.migration, the window that lets gatedSet sit beside the static
# plugin for the apps it names. Both default off; unset (or empty) the tenant-onboarding chart is byte for byte what it was.
for NOPAUSE in "${TMP}/gate-opt" "${TMP}/gate" "${GS}" "${LAB}/dev" "${LAB}/prod"; do
  if grep -q 'syncPaused\|automated: null\|key: appName\|TENANT_SYNC\|TENANT_WINDOW' "${NOPAUSE}/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then
    bad "no syncPaused or window (${NOPAUSE##*/}): the tenant-onboarding chart mentions them"
  else ok "no syncPaused or window (${NOPAUSE##*/}): the tenant-onboarding chart is as before"; fi
done
new "${TMP}/pause-empty" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'tenantOnboarding.syncPaused={}' --set 'clearance.gate.migration={window: false}'
render_ok "${TMP}/pause-empty" "an empty syncPaused and a closed window"
diff -r "${TMP}/gate/02-argocd-apps" "${TMP}/pause-empty/02-argocd-apps" >/dev/null && ok "an empty syncPaused and a closed window: the render is byte for byte the one without them" \
  || bad "an empty syncPaused or a closed window changed the render"
new "${TMP}/pause-nogate" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set 'tenantOnboarding.syncPaused={shop: [dev, qa]}'
render_ok "${TMP}/pause-nogate" "syncPaused without the gate"
PNA="${TMP}/pause-nogate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${PNA}" '^    \{\{- \$syncPaused := regexMatch "\^\(shop/dev\|shop/qa\)\$" \(printf "%s/%s" \.appName \.env\) \}\}$' "syncPaused: one regex over <appName>/<env>"
[ "$(grep -c '^ *automated: null$' "${PNA}")" = 3 ] && ok "syncPaused without the gate: automated: null in the configMapGenerator branch and both {} branches" \
  || bad "syncPaused without the gate: $(grep -c '^ *automated: null$' "${PNA}") automated: null lines, want 3"
out="$(python3 hack/check.py --cluster "${TMP}/pause-nogate/cluster.yaml" 2>&1)"
grep -qF "warning: tenantOnboarding.syncPaused: automated sync is off for shop/dev, shop/qa" <<<"${out}" \
  && ok "syncPaused: apron check warns while it is set" || bad "syncPaused: no warning from apron check: ${out}"
new "${TMP}/pause-gate" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'tenantOnboarding.syncPaused={gate-api: [prod]}'
render_ok "${TMP}/pause-gate" "syncPaused with the static plugin"
[ "$(grep -c '^ *automated: null$' "${TMP}/pause-gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml")" = 4 ] \
  && ok "syncPaused with the static plugin: the plugin branch is paused too" || bad "syncPaused with the static plugin: the plugin branch has no pause"
# Removing the pause lines gives back the render without it: the pause adds lines and changes none.
python3 - "${TMP}/gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" "${TMP}/pause-gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml" <<'PY' \
  && ok "syncPaused only adds lines (removing them gives the render without it)" || bad "syncPaused changes lines of the render beyond its own"
import re, sys
a, b = open(sys.argv[1]).read(), open(sys.argv[2]).read()
b = re.sub(r"    \{\{- /\* tenantOnboarding\.syncPaused.*?\*/\}\}\n    \{\{- \$syncPaused := [^\n]*\n", "", b, flags=re.S)
b = b.replace("      {{- if $syncPaused }}\n      syncPolicy:\n        automated: null\n      {{- end }}\n", "")
b = b.replace("    {{- if $syncPaused }}\n    spec:\n      syncPolicy:\n        automated: null\n    {{- else }}\n    {}\n    {{- end }}\n", "    {}\n")
sys.exit(0 if a == b else 1)
PY
for BADP in "tenantOnboarding.syncPaused=[shop]|syncPaused is a mapping" "tenantOnboarding.syncPaused={Shop: [prod]}|'Shop' is not an app name" \
            "tenantOnboarding.syncPaused={shop: []}|syncPaused.shop is a non-empty list" "tenantOnboarding.syncPaused={shop: [prod, prod]}|syncPaused.shop is a non-empty list" \
            "tenantOnboarding.syncPaused={shop: prod}|syncPaused.shop is a non-empty list"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/pause-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set "${BAD}"
  out="$(python3 hack/check.py --cluster "${TMP}/pause-bad/cluster.yaml" 2>&1)" && { bad "${BAD}: check accepted it"; continue; }
  grep -qF -- "${WANT}" <<<"${out}" && ok "${BAD}: refused (${WANT})" || bad "${BAD}: ${out}"
done
# The window: the static plugin on for */prod with clearance.gate.apps [shop, pay], the gated set, and the window for shop.
WIN_SET=("${OPT_SET[@]}" --set clearance.gate.tenantPlugin=true --set 'clearance.protectedEnvironments=["*/prod"]' --set 'clearance.gate.apps=[shop, pay]'
  --set 'clearance.gate.agent.projects=[shop, pay]' --set 'clearance.gate.agent.protectedNamespaces=[app-shop-prod, app-pay-prod]' --set clearance.gate.agent.gatedSet=true)
win() { # win NAME [more --set flags]: the window's base cluster (WIN_SET) with more settings
  local d="${TMP}/$1"; shift
  new "${d}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${WIN_SET[@]}" "$@"
}
# Also the render tests/appset runs (TestMigrationWindow): shop/dev, shop/prod, shop/qa and pay/prod paused.
win gate-window --set 'clearance.gate.migration={window: true, apps: [shop]}' --set 'tenantOnboarding.syncPaused={shop: [dev, prod, qa], pay: [prod]}'
render_ok "${TMP}/gate-window" "the migration window with the static plugin and the gated set"
GWA="${TMP}/gate-window/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
[ "$(grep -c '^            values: \["pay"\]$' "${GWA}")" = 1 ] && has "${GWA}" '^          - key: appName$' "window: both sets' main generator leaves out the held app (appName NotIn [pay])" \
  || bad "window: the main generator's appName NotIn [pay] is not in both sets"
if grep -A12 '__TENANT_SET_ONLY__- git:' "${GWA}" | grep -q 'clearanceGate'; then bad "window: the held-app generator reads clearanceGate"
else ok "window: the held-app generator selects on the app name alone"; fi
has "${GWA}" '^    __TENANT_SET_ONLY__- git:$' "window: tenant-onboarding has a second generator for the held apps"
has "${GWA}" '^    __TENANT_SET_ONLY__        values: \["pay"\]$' "window: tenant-onboarding's second generator takes exactly the held apps"
has "${GWA}" 'regexMatch "\^\(shop\|pay\)\$" \.appName' "window: the static plugin's app regex is still clearance.gate.apps"
out="$(python3 hack/check.py --cluster "${TMP}/gate-window/cluster.yaml" 2>&1)"
grep -qF "warning: clearance.gate.migration.window is open for shop (pay held in tenant-onboarding)" <<<"${out}" && ok "window: apron check warns while it is open" || bad "window: no warning: ${out}"
win gate-window-all --set 'clearance.gate.migration={window: true, apps: [shop, pay]}'
render_ok "${TMP}/gate-window-all" "the migration window for every app of clearance.gate.apps"
if grep -q 'key: appName\|__TENANT_SET_ONLY__- git:' "${TMP}/gate-window-all/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then
  bad "window for every app: a held-app selector rendered"
else ok "window for every app: nothing is held (no appName selector, one generator per set)"; fi
for BADP in \
    "clearance.gate.migration={window: true}|window is open with no apps|a window left open with no apps" \
    "clearance.gate.migration={window: true, apps: []}|window is open with no apps|a window with an empty list" \
    "clearance.gate.migration={window: false, apps: [shop]}|names apps but the window is closed|apps listed with the window closed" \
    "clearance.gate.migration={window: true, apps: [other]}|names other, which clearance.gate.apps leaves out|a window app not in clearance.gate.apps" \
    "clearance.gate.migration={window: yes, apps: [shop]}|migration.window is true or false|window: yes" \
    "clearance.gate.migration={window: true, apps: [shop], app: [pay]}|clearance.gate.migration.app is not a setting|an unknown clearance.gate.migration key"; do
  BAD="${BADP%%|*}"; REST="${BADP#*|}"; WANT="${REST%%|*}"; LABEL="${REST#*|}"
  if [ -n "${BAD}" ]; then win gate-window-bad --set "${BAD}"; else win gate-window-bad; fi
  rule_refused gate-window-bad "${WANT}" "${LABEL}"
done
# Outside the window the refusal is render's, as before (apron check never held gatedSet to tenantPlugin).
win gate-window-bad
out="$(python3 hack/render.py --cluster "${TMP}/gate-window-bad/cluster.yaml" 2>&1)" && bad "gatedSet with the static plugin and no window: rendered" \
  || { grep -qF "gatedSet needs clearance.gate.tenantPlugin: false" <<<"${out}" && ok "gatedSet with the static plugin and no window is refused, as before" \
       || bad "gatedSet with the static plugin and no window: ${out}"; }
for BADP in \
    "clearance.gate.agent.projects=[pay]|leave out its project shop|a window app outside the agent's projects" \
    "clearance.gate.agent.protectedNamespaces=[app-pay-prod]|no namespace of the agent's protectedNamespaces is one of its environments|a window app with no protected namespace" \
    "clearance.gate.apps=[]|window needs clearance.gate.apps|a window with clearance.gate.apps empty (every app on the plugin)" \
    "clearance.gate.agent.gatedSet=false|window needs the gate, its agent and clearance.gate.agent.gatedSet|a window without the gated set" \
    "clearance.gate.tenantPlugin=false|window is for a cluster on the static plugin|a window with tenantPlugin: false"; do
  BAD="${BADP%%|*}"; REST="${BADP#*|}"; WANT="${REST%%|*}"; LABEL="${REST#*|}"
  win gate-window-bad --set 'clearance.gate.migration={window: true, apps: [shop]}' --set "${BAD}"
  rule_refused gate-window-bad "${WANT}" "${LABEL}"
done
# W-46 (d) (tenantOnboarding.deleteGuard, default off): off, nothing renders (every cluster's render is as before); on, the
# tenant-onboarding chart renders the ValidatingAdmissionPolicy that refuses the ApplicationSet controller's delete of a
# tenant-onboarding(-gated) Application. It needs no gate. Admission is tested in section 5 (tests/policy/test_tenant_delete_guard.py),
# the controller's behaviour with it in tests/appset (TestDeleteGuard).
DGF=02-argocd-apps/tenant-onboarding/chart/templates/delete-guard.yaml
for NODG in "${LAB}/dev" "${LAB}/prod" "${GS}" "${GSH}" "${TMP}/gate-opt"; do
  [ ! -e "${NODG}/${DGF}" ] && ok "deleteGuard off (${NODG##*/}): no delete guard rendered" || bad "deleteGuard off (${NODG##*/}): ${DGF} rendered"
done
DG="${TMP}/delete-guard"
new "${DG}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tenantOnboarding.deleteGuard.enabled=true
render_ok "${DG}" "deleteGuard on, no gate"
DGP="${DG}/${DGF}"
has "${DGP}" '^  validationActions: \[Audit\]$' "deleteGuard: validationActions defaults to Audit (the first rollout step)"
# The username comparison is the FIRST matchCondition (a CEL error can then only refuse the controller's own deletes), and it
# names the ServiceAccount argocd-apps-install's ApplicationSet controller runs as.
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${DGP}" <<'PY' && ok "deleteGuard: the username condition is first, on argocd-apps' ApplicationSet controller; every field the second reads is has()-guarded" || bad "deleteGuard: matchConditions"
import re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
p = docs[0]["spec"]
c = p["matchConditions"]
assert p["failurePolicy"] == "Fail" and p["matchConstraints"]["resourceRules"][0]["operations"] == ["DELETE"], p
assert c[0]["expression"] == "request.userInfo.username == 'system:serviceaccount:argocd-apps:argocd-applicationset-controller'", c[0]
e = c[1]["expression"]
for field in ("oldObject.metadata.ownerReferences", "r.controller", "r.apiVersion", "r.kind", "r.name"):
    assert f"has({field})" in e, field
    # every read of the field comes after its has() guard
    assert e.index(f"has({field})") < min(m.start() for m in re.finditer(re.escape(field) + r"(?!\))", e)), field
assert docs[1]["spec"]["policyName"] == docs[0]["metadata"]["name"]
PY
fi
# argocd-apps-install leaves the argo-cd chart's ApplicationSet ServiceAccount name (argocd-applicationset-controller) as it is;
# a rename there must come with tenantOnboarding.deleteGuard.controllerServiceAccount, or the guard matches nobody.
if grep -qE '^ +serviceAccount:' templates/01-argocd-platform/argocd-apps-install/application.yaml; then bad "argocd-apps-install sets a serviceAccount: check the delete guard's controllerServiceAccount"; else ok "argocd-apps-install keeps the chart's ApplicationSet ServiceAccount name (the delete guard's default)"; fi
DGD="${TMP}/delete-guard-deny"
new "${DGD}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agent.gatedSet=true --set tenantOnboarding.deleteGuard.enabled=true --set tenantOnboarding.deleteGuard.validationActions=Deny
render_ok "${DGD}" "deleteGuard Deny, with the gated set"
has "${DGD}/${DGF}" '^  validationActions: \[Deny\]$' "deleteGuard: validationActions Deny"
DGS="${TMP}/delete-guard-sa"
mkdir -p "${DGS}"
{ cat "${LAB}/prod/cluster.yaml"; printf 'tenantOnboarding:\n  deleteGuard: {enabled: true, controllerServiceAccount: appset.ctrl}\n'; } >"${DGS}/cluster.yaml"
render_ok "${DGS}" "deleteGuard on prod, another controller ServiceAccount"
has "${DGS}/${DGF}" "username == 'system:serviceaccount:argocd-apps:appset\.ctrl'" "deleteGuard: controllerServiceAccount names the matched user"
# Same cluster.yaml plus the key: only the guard's file is added, the rest of the render is byte for byte what it was.
if diff -r -x cluster.yaml -x .apron-rendered -x delete-guard.yaml "${LAB}/prod" "${DGS}" >/dev/null \
  && [ "$(diff <(sed 1d "${LAB}/prod/.apron-rendered") <(sed 1d "${DGS}/.apron-rendered") | grep -c '^[<>]')" = 1 ]; then
  ok "deleteGuard: turning it on adds only the guard's file"
else bad "deleteGuard: turning it on changes more than the guard's file"; fi
# A trailing newline would end up inside the policy's CEL string literal: refused (fullmatch, not match).
mkdir -p "${TMP}/delete-guard-nl"
{ cat "${LAB}/dev/cluster.yaml"; printf 'tenantOnboarding:\n  deleteGuard: {enabled: true, controllerServiceAccount: "appset-ctrl\\n"}\n'; } >"${TMP}/delete-guard-nl/cluster.yaml"
BADERR="$(python3 hack/render.py --cluster "${TMP}/delete-guard-nl/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -qF -- "controllerServiceAccount is a ServiceAccount name" <<<"${BADERR}"; then ok "delete guard: a controllerServiceAccount with a trailing newline is refused"; else bad "delete guard: trailing newline: rc=${BADRC} ${BADERR}"; fi
for BADP in "tenantOnboarding.deleteGuard.enabled=maybe|deleteGuard.enabled is true or false" \
            "tenantOnboarding.deleteGuard.validationActions=Warn|validationActions is Audit or Deny" \
            "tenantOnboarding.deleteGuard.controllerServiceAccount=x' or true or 'y|controllerServiceAccount is a ServiceAccount name" \
            "tenantOnboarding.deleteGuard.controllerServiceAccount=Appset|controllerServiceAccount is a ServiceAccount name" \
            "tenantOnboarding.deleteGuard=on|tenantOnboarding.deleteGuard is a mapping"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/delete-guard-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/delete-guard-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "delete guard ${BAD}: refused (${WANT})"; else bad "delete guard ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
OC="${TMP}/gate-opt/55-clearance/clearance/application.yaml"
[ "$(grep -c 'app.kubernetes.io/name: argocd-repo-server' "${OC}")" = 1 ] && ok "gate with the core here: the core admits the repo-server" || bad "gate with the core here: the repo-server rule is missing or doubled"
[ "$(grep -c 'app.kubernetes.io/name: clearance-argocd-agent' "${OC}")" = 2 ] && ok "gate with the core here: the core and clearance-api admit the agent" || bad "gate with the core here: the agent rules are not exactly two (core, api)"
has "${TMP}/gate-opt/56-clearance-gate/admission.yaml" 'validationActions: \[Warn, Audit\]' "gate.lowerZone: Warn and Audit by default"
# clearance.gate.agent.ownedProject (W-40): the agent's own Namespaces and AppProjects, as an Application ahead of the agent
OWN_SET=(--set 'clearance.gate.agent.ownedProject={create: true}')
new "${TMP}/gate-own" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "${OWN_SET[@]}"
render_ok "${TMP}/gate-own" "gate agent ownedProject.create"
expect "${TMP}/gate-own" "ownedProject.create" 56-clearance-gate/agent/owned.yaml
OWNF="${TMP}/gate-own/56-clearance-gate/agent/owned.yaml"
has "${OWNF}" '^kind: Namespace$' "ownedProject: a Namespace"
has "${OWNF}" '^  name: "rehearsal"$' "ownedProject: the protected namespace's name"
has "${OWNF}" '^kind: AppProject$' "ownedProject: an AppProject"
has "${OWNF}" '^  namespace: argocd-apps$' "ownedProject: the AppProject is in argocd-apps (where the agent reads)"
has "${OWNF}" '^    - \{server: https://kubernetes.default.svc, namespace: "rehearsal"\}$' "ownedProject: the project deploys only into the protected namespace"
has "${OWNF}" '^    - "https://github.com/acme/gitops-cluster-hangar-dev"$' "ownedProject: sourceRepos defaults to the cluster's gitops repository"
has "${OWNF}" 'sync-options: Prune=false,Delete=false' "ownedProject: never pruned or deleted by Argo CD"
if [ "$(grep -c 'sync-wave: "-1"' "${OWNF}")" = 1 ] && [ "$(grep -c 'sync-wave: "0"' "${OWNF}")" = 1 ]; then ok "ownedProject: Namespace wave -1, AppProject wave 0"; else bad "ownedProject: waves are not Namespace -1, AppProject 0"; fi
OWNA="${TMP}/gate-own/56-clearance-gate/agent/application.yaml"
has "${OWNA}" '^  sources:$' "ownedProject: the agent Application has two sources (one sync, so the wave order holds)"
has "${OWNA}" '^    path: 56-clearance-gate/agent$' "ownedProject: the first source is the agent folder (owned.yaml)"
has "${OWNA}" '^    chart: clearance-argocd-agent$' "ownedProject: the chart is the second source"
if grep -q '^  source:$' "${OWNA}"; then bad "ownedProject: the agent Application still has a single source"; else ok "ownedProject: no single source left beside sources"; fi
if grep -q 'sync-wave' "${OWNA}"; then bad "ownedProject: the agent Application carries a wave itself"; else ok "ownedProject: no wave on the Application (waves order the resources inside one sync)"; fi
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); s=d["spec"]["sources"]; assert len(s)==2 and s[0]["path"]=="56-clearance-gate/agent" and s[1]["chart"]=="clearance-argocd-agent" and s[1]["helm"]["releaseName"]=="clearance-argocd-agent" and "source" not in d["spec"], d["spec"]' "${OWNA}" && ok "ownedProject: the agent Application parses with the git source then the chart" || bad "ownedProject: the agent Application's sources are wrong"; fi
has "${TMP}/gate-opt/56-clearance-gate/agent/application.yaml" '^  source:$' "ownedProject unset: the agent Application keeps its single source"
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=list(yaml.safe_load_all(open(sys.argv[1]))); assert [x["kind"] for x in d]==["Namespace","AppProject"] and d[1]["spec"]["destinations"]==[{"server":"https://kubernetes.default.svc","namespace":"rehearsal"}], d' "${OWNF}" && ok "ownedProject: owned.yaml parses as Namespace then AppProject" || bad "ownedProject: owned.yaml does not parse as Namespace, AppProject"; fi
for F in 56-clearance-gate/application.yaml 56-clearance-gate/admission.yaml 56-clearance-gate/clearancegrant-crd.yaml; do
  cmp -s "${TMP}/gate-own/${F}" "${TMP}/gate-opt/${F}" && ok "ownedProject: ${F} is byte for byte as without it" || bad "ownedProject: ${F} differs from the render without it"
done
new "${TMP}/gate-own-multi" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.gate.agent.ownedProject={create: true, sourceRepos: ["https://github.com/acme/one", "https://github.com/acme/two"]}' \
  --set 'clearance.gate.agent.projects=[p-one, p-two]' --set 'clearance.gate.agent.protectedNamespaces=[ns-one, ns-two]'
render_ok "${TMP}/gate-own-multi" "ownedProject, two projects and two namespaces"
OWNM="${TMP}/gate-own-multi/56-clearance-gate/agent/owned.yaml"
[ "$(grep -c '^kind: Namespace$' "${OWNM}")" = 2 ] && [ "$(grep -c '^kind: AppProject$' "${OWNM}")" = 2 ] && ok "ownedProject: a Namespace per namespace, an AppProject per project" || bad "ownedProject: wrong object counts"
[ "$(grep -c 'namespace: "ns-two"}' "${OWNM}")" = 2 ] && ok "ownedProject: each project may deploy into every protected namespace" || bad "ownedProject: destinations are not every namespace for each project"
has "${OWNM}" '^    - "https://github.com/acme/two"$' "ownedProject: sourceRepos as given"
new "${TMP}/gate-own-null" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "${OWN_SET[@]}" \
  --set 'clearance.gate.agent.projects=["null"]' --set 'clearance.gate.agent.protectedNamespaces=["true"]'
render_ok "${TMP}/gate-own-null" "ownedProject with names YAML would read as null and true"
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=list(yaml.safe_load_all(open(sys.argv[1]))); assert d[0]["metadata"]["name"]=="true" and d[1]["metadata"]["name"]=="null" and d[1]["spec"]["destinations"][0]["namespace"]=="true", d' "${TMP}/gate-own-null/56-clearance-gate/agent/owned.yaml" && ok "ownedProject: names are quoted, so null and true stay strings" || bad "ownedProject: a name was read as a non-string"; fi
new "${TMP}/gate-own-off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.gate.agent.ownedProject={create: false}'
render_ok "${TMP}/gate-own-off" "ownedProject create false"
expect "${TMP}/gate-own-off" "ownedProject.create false" '!56-clearance-gate/agent/owned.yaml'
expect "${TMP}/gate-opt" "ownedProject unset" '!56-clearance-gate/agent/owned.yaml'
diff -r "${TMP}/gate-own-off/56-clearance-gate" "${TMP}/gate-opt/56-clearance-gate" >/dev/null 2>&1 && cmp -s "${TMP}/gate-own-off/.apron-rendered" "${TMP}/gate-opt/.apron-rendered" && ok "ownedProject create false renders byte for byte what unset does (the gate files and the rendered list; generated passwords elsewhere differ per new_cluster)" || bad "ownedProject create false differs from unset"
for BADP in "clearance.gate.agent.ownedProject=yes|ownedProject is a map" "clearance.gate.agent.ownedProject={create: maybe}|ownedProject.create is true or false" \
            "clearance.gate.agent.ownedProject={create: true, typo: 1}|ownedProject.typo is not a setting" \
            "clearance.gate.agent.ownedProject={create: true, sourceRepos: []}|ownedProject.sourceRepos is a non-empty list" \
            "clearance.gate.agent.projects=[default]|would own the AppProject 'default'" \
            "clearance.gate.agent.protectedNamespaces=[Bad_NS]|needs clearance.gate.agent.protectedNamespaces to be a list of DNS labels"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-own-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
    --set 'clearance.gate.agent.ownedProject={create: true}' --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-own-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "ownedProject ${BAD}: refused (${WANT})"; else bad "ownedProject ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
# default off: the agent of an ordinary gate render has no opt-in and no environment, a cluster without the gate has no agent rule
if grep -q 'optIn:\|environment:' "${TMP}/gate-agent/56-clearance-gate/agent/application.yaml"; then bad "gate.agent without optIn: optIn or environment rendered"; else ok "gate.agent without optIn: no optIn and no environment (the render is today's)"; fi
if grep -q 'regexMatch "\^\$"' "${TMP}/gate-agent/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"; then bad "tenantPlugin unset: the plugin regex matches no app"; else ok "tenantPlugin unset: the plugin regex is as before"; fi
if grep -q 'argocd-repo-server\|clearance-argocd-agent' "${LAB}/dev/55-clearance/clearance/application.yaml"; then bad "gate off: the core's NetworkPolicy names the repo-server or the agent"; else ok "gate off: the core's NetworkPolicy is as before"; fi
new "${TMP}/gate-lower-off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  "${OPT_SET[@]}" --set clearance.gate.lowerZone=false
render_ok "${TMP}/gate-lower-off" "lower cluster, gate with lowerZone false"
expect "${TMP}/gate-lower-off" "gate.lowerZone false" '!56-clearance-gate/admission.yaml' '!56-clearance-gate/agent/application.yaml'
for BADP in "clearance.gate.agent.optIn=maybe|agent.optIn is true or false" "clearance.gate.agent.environment=Bad_Env|agent.environment is a DNS label" \
            "clearance.gate.tenantPlugin=maybe|tenantPlugin is true or false" "clearance.gate.lowerZone=maybe|lowerZone is true or false" \
            "versions.clearance.argocdAgentChart=0.48.0|needs versions.clearance.argocdAgentChart 0.49.0" "clearance.extraProviders=[]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: argocd-agent-dev, version: '1', principals: [a/b], protection: ['a/b=hangar-prod']}]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: other, version: '1', principals: [other/sa], protection: ['other/sa=hangar-dev']}]|needs a clearance.extraProviders entry with protection" \
            "clearance.extraProviders=[{name: other, version: '1', principals: [other/sa], protection: ['clearance-system/clearance-argocd-agent=hangar-dev']}]|needs a clearance.extraProviders entry with protection"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-opt-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-opt-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "gate opt-in ${BAD}: refused (${WANT})"; else bad "gate opt-in ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
# a glob entry that covers the agent's principal is accepted; so is a renamed agent account, when the entry names it
new "${TMP}/gate-opt-glob" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: ["clearance-system/*"], protection: ["clearance-system/*=hangar-dev"]}]'
render_ok "${TMP}/gate-opt-glob" "gate opt-in: a protection glob that covers the agent's principal"
new "${TMP}/gate-opt-sa" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agentServiceAccount=clearance-system:the-agent \
  --set 'clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: ["clearance-system/the-agent"], protection: ["clearance-system/the-agent=hangar-dev"]}]'
render_ok "${TMP}/gate-opt-sa" "gate opt-in: a renamed agent account named by its entry"
has "${TMP}/gate-opt-sa/56-clearance-gate/agent/application.yaml" '^          name: "the-agent"$' "gate opt-in: the renamed account is the agent chart's serviceAccount.name"
has "${TMP}/gate-opt-sa/56-clearance-gate/admission.yaml" "== 'system:serviceaccount:clearance-system:the-agent'" "gate opt-in: the policy names the same account as the only grant writer"
if grep -q 'serviceAccount:' "${TMP}/gate-opt/56-clearance-gate/agent/application.yaml"; then bad "agentServiceAccount unset: the agent chart's serviceAccount is set"; else ok "agentServiceAccount unset: the agent chart's own account name (the render is today's)"; fi
new "${TMP}/gate-opt-sa-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set clearance.gate.agentServiceAccount=other-ns:the-agent
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-opt-sa-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "agentServiceAccount is clearance-system:<name>" <<<"${BADERR}"; then ok "gate.agentServiceAccount outside clearance-system with the agent is refused"; else bad "gate.agentServiceAccount other-ns: rc=${BADRC} ${BADERR}"; fi
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

echo "== 1c-4b. clearance-api's coverage cache (clearance.api.coverageCacheSeconds, off by default)"
new "${TMP}/cov-on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set clearance.api.coverageCacheSeconds=30
render_ok "${TMP}/cov-on" "coverage cache on"
python3 hack/check.py --cluster "${TMP}/cov-on/cluster.yaml" >/dev/null && ok "coverage cache on passes check" || bad "coverage cache on fails check"
has "${TMP}/cov-on/${CA}" '^          coverageCacheSeconds: 30$' "coverage cache on: the chart's api.coverageCacheSeconds is 30"
if grep -rq 'coverageCacheSeconds' "${LAB}/dev" "${LAB}/prod"; then bad "coverage cache default: coverageCacheSeconds rendered"; else ok "coverage cache default: not rendered (chart default, off)"; fi
mkdir -p "${TMP}/cov-offdev"
cp "${LAB}/dev/cluster.yaml" "${TMP}/cov-offdev/cluster.yaml"
printf 'clearance:\n  api: {coverageCacheSeconds: 0}\n' >>"${TMP}/cov-offdev/cluster.yaml"
render_ok "${TMP}/cov-offdev" "coverage cache explicitly 0"
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/cov-offdev" >/dev/null; then ok "coverage cache 0 == absent, byte for byte"; else bad "coverage cache 0 differs from absent"; fi

echo "== 1c-5. Clearance Slack (clearance.slack.enabled)"
SLACK_COMMON=(--set versions.clearance.chart=0.47.1 --set 'clearance.people=[alice]' --set clearance.slack.enabled=true
  --set clearance.slack.publicUrl=https://slack.clearance.example.com --set clearance.slack.slackClientId=1234.5678
  --set 'clearance.slack.routes={groups: {"group:default/payments": C0123456789}, security: C0SECURITY, ops: C0OPSOPSOPS}')
SLACK_DNS=(--set clearance.slack.tls.mode=dns01-route53 --set clearance.slack.tls.dns01.hostedZoneID=Z0123456789ABC
  --set clearance.slack.tls.dns01.email=ops@example.com --set clearance.slack.tls.dns01.roleARN=arn:aws:iam::111122223333:role/dns01
  --set clearance.slack.idp.hostAlias=192.0.2.10)
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
has "${SL}/${CA}" 'digest: "sha256:44f6663d' "slack on: the image is pinned by digest"
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
has "${SE}/${CA}" 'webUrl: "https://clearance\.hangar-dev\.local/changes/\{id\}"' "slack + web UI: tier 3 links to the web UI by default"
has "${SE}/${CA}" 'port: 443' "slack on an https gateway: IdP egress on 443"
if grep -q 'trustedPeers: \["clearance-web"\]' "${SE}/55-identity/people-dex/dex.yaml" && grep -q 'id: clearance-slack$' "${SE}/55-identity/people-dex/dex.yaml"; then ok "slack + web UI: both Dex clients"; else bad "slack + web UI: Dex clients missing"; fi

if grep -rniE 'clearance-slack|clearance_slack|slack\.' "${LAB}/dev" "${LAB}/prod" --exclude=cluster.yaml >/dev/null; then bad "slack off: something of the Slack service rendered"; else ok "slack off: nothing of the Slack service renders"; fi
mkdir -p "${TMP}/slack-offdev"
cp "${LAB}/dev/cluster.yaml" "${TMP}/slack-offdev/cluster.yaml"
printf 'clearance:\n  slack: {enabled: false}\n' >>"${TMP}/slack-offdev/cluster.yaml"
render_ok "${TMP}/slack-offdev" "slack explicitly off"
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/slack-offdev" >/dev/null; then ok "slack key off == absent, byte for byte"; else bad "slack off differs from absent"; fi

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
  local d="${TMP}/slack-refuse-$((RANDOM))" base=("${SLACK_COMMON[@]}" "${SLACK_DNS[@]}")
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

echo "== 3a. lab-only networking (runtime.labNetworking: kiac and kind only; docs/lab-networking.md)"
# EKS: no hostAlias entry, no *.local host, no RFC1918 literal from a lab knob, in any rendered file.
labscan() { # labscan DIR: prints one line per violation
  python3 - "$1" <<'PY'
import os, re, sys
try:
    import yaml
except ImportError:
    yaml = None
rfc = re.compile(r"(?<![0-9.])(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)(?![0-9.])")
def walk(o, p, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "hostAliases" and isinstance(v, list) and any(isinstance(e, dict) and "ip" in e for e in v):
                out.append(f"{p}: hostAliases entry")
            walk(v, p, out)
    elif isinstance(o, list):
        for e in o:
            walk(e, p, out)
out = []
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        p = os.path.join(d, f)
        if f == "cluster.yaml" or not f.endswith((".yaml", ".yml", ".sh", ".md")):
            continue
        text = open(p).read()
        code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
        if re.search(r"(?<!cluster)(?<!svc)\.local\b", code):
            out.append(f"{p}: .local host")
        if rfc.search(code) and "networkpolicy" not in p.lower() and "install.yaml" not in p and "kubeadm" not in p:
            out.append(f"{p}: RFC1918 literal {rfc.search(code).group(1)}")
        if yaml and f.endswith((".yaml", ".yml")) and "/chart/templates/" not in p and not f.endswith(".tmpl.yaml"):
            try:
                for doc in yaml.safe_load_all(text):
                    walk(doc, p, out)
            except Exception:
                pass
        if re.search(r'^\s*(- )?ip: "?\d', text, re.M) and "install.yaml" not in p:
            out.append(f"{p}: ip: literal")
print("\n".join(out))
PY
}
for c in dev prod man; do
  [ -d "${K}/${c}" ] || continue
  r="$(labscan "${K}/${c}")"
  [ -z "${r}" ] && ok "eks-${c}: no hostAliases, .local host or lab address rendered" || bad "eks-${c}: lab plumbing rendered: $(head -3 <<<"${r}")"
done
# the lab renders keep them (the knobs are set in the ledger fixtures above)
grep -rqE 'hostAliases: \[\{' "${TMP}/led-dev" && ok "lab (kiac): the host alias knobs still render" || bad "lab: host alias knobs no longer render"
# a non-lab runtime refuses every lab-only knob by name, and (--no-check) still renders none of them
for knob in tower.hostAliasIP=192.0.2.5 fleet.hubAddress=192.0.2.6 clearance.gate.hostAlias=192.0.2.1=clearance.example.dev \
            clearance.ledger.hostAlias=192.0.2.9=witness.example.dev clearance.slack.idp.hostAlias=192.0.2.10; do
  key="${knob%%=*}"
  rm -rf "${TMP}/eks-knob"
  new "${TMP}/eks-knob" dev eks-knob eks --repo-url https://github.com/acme/gitops-eks-knob --scm-owner acme \
    --domain eks-knob.aws.example.dev --set infisical.host=false --set infisical.url="${INF}" --set "issuer=${ISS}/DDD4" \
    --tower-cluster eks-man --set tower.domain=eks-man.aws.example.dev --set "${knob}"
  cp "${TMP}/eks-knob/cluster.yaml" "${TMP}/eks-knob.yaml"
  err="$(python3 hack/check.py --cluster "${TMP}/eks-knob.yaml" 2>&1 >/dev/null)"
  grep -q "${key} is lab-only networking" <<<"${err}" && ok "eks: ${key} refused by name" || bad "eks: ${key} not refused (${err})"
  python3 hack/render.py --cluster "${TMP}/eks-knob/cluster.yaml" --no-check >/dev/null 2>&1
  r="$(labscan "${TMP}/eks-knob")"
  [ -f "${TMP}/eks-knob/root-app-of-apps.yaml" ] && [ -z "${r}" ] && ok "eks: ${key} set, check bypassed: still no lab plumbing rendered" || bad "eks: ${key} rendered anyway: $(head -2 <<<"${r}")"
done
# Clearance Slack off a lab: gateway-existing only; dns01-route53 and idp.hostAlias are the lab path
EKS_SLACK=(--repo-url https://github.com/acme/gitops-eks-knob --scm-owner acme
  --domain eks-knob.aws.example.dev --set infisical.host=false --set infisical.url="${INF}" --set "issuer=${ISS}/DDD4"
  --tower-cluster eks-man --set tower.domain=eks-man.aws.example.dev --set "tower.issuer=${ISS}/DDD5" "${SLACK_COMMON[@]}")
rm -rf "${TMP}/eks-slack"
new "${TMP}/eks-slack" dev eks-knob eks "${EKS_SLACK[@]}"
python3 hack/check.py --cluster "${TMP}/eks-slack/cluster.yaml" >/dev/null 2>"${TMP}/eks-slack.err" && ok "eks: slack on with gateway-existing passes check" || bad "eks: slack gateway-existing refused: $(head -1 "${TMP}/eks-slack.err")"
render_ok "${TMP}/eks-slack" "eks slack (gateway-existing)"
r="$(labscan "${TMP}/eks-slack")"
[ -z "${r}" ] && ok "eks slack: no lab plumbing rendered" || bad "eks slack: lab plumbing rendered: $(head -2 <<<"${r}")"
for extra in "clearance.slack.tls.mode=dns01-route53 clearance.slack.tls.dns01.hostedZoneID=Z0123456789ABC clearance.slack.tls.dns01.email=ops@example.com clearance.slack.tls.dns01.roleARN=arn:aws:iam::111122223333:role/x"; do
  rm -rf "${TMP}/eks-slack-dns"
  new "${TMP}/eks-slack-dns" dev eks-knob eks "${EKS_SLACK[@]}" $(printf -- '--set %s ' ${extra})
  err="$(python3 hack/check.py --cluster "${TMP}/eks-slack-dns/cluster.yaml" 2>&1 >/dev/null)"
  grep -q "is the lab path" <<<"${err}" && ok "eks: slack dns01-route53 refused as the lab path" || bad "eks: slack dns01 not refused (${err})"
done
rm -rf "${TMP}/eks-slack-alias"
new "${TMP}/eks-slack-alias" dev eks-knob eks "${EKS_SLACK[@]}" --set clearance.slack.idp.hostAlias=192.0.2.10
python3 hack/render.py --cluster "${TMP}/eks-slack-alias/cluster.yaml" --no-check >/dev/null 2>&1
r="$(labscan "${TMP}/eks-slack-alias")"
[ -f "${TMP}/eks-slack-alias/root-app-of-apps.yaml" ] && [ -z "${r}" ] && ok "eks slack: idp.hostAlias set, check bypassed: not rendered" || bad "eks slack: idp.hostAlias rendered: $(head -2 <<<"${r}")"
# real DNS is required where there is no lab: no <name>.local defaults
python3 hack/new_cluster.py --profile dev --name eks-nodns --runtime eks --repo-url https://github.com/acme/g --scm-owner acme >"${TMP}/nodns.yaml"
err="$(python3 hack/check.py --cluster "${TMP}/nodns.yaml" 2>&1 >/dev/null)"
grep -q "domain is required on runtime eks" <<<"${err}" && ok "eks: no domain is refused (no <name>.local default)" || bad "eks: no domain accepted (${err})"
python3 hack/new_cluster.py --profile dev --name eks-local --runtime eks --repo-url https://github.com/acme/g --scm-owner acme --domain eks-local.local >"${TMP}/localdns.yaml"
err="$(python3 hack/check.py --cluster "${TMP}/localdns.yaml" 2>&1 >/dev/null)"
grep -q "domain 'eks-local.local' is a .local name" <<<"${err}" && ok "eks: a .local domain is refused" || bad "eks: .local domain accepted (${err})"
# an existing cluster that IS a lab opts in explicitly, and then gets the lab defaults
python3 hack/new_cluster.py --profile dev --name lab-existing --runtime existing --repo-url https://github.com/acme/g --scm-owner acme \
  --tower-cluster hangar-prod --set runtime.labNetworking=true --set tower.hostAliasIP=192.0.2.5 >"${TMP}/existing-lab.yaml"
python3 hack/check.py --cluster "${TMP}/existing-lab.yaml" >/dev/null 2>&1 && ok "existing + runtime.labNetworking: true: lab knobs accepted" || bad "existing lab opt-in refused"
for rt in kiac kind; do
  has "runtimes/${rt}.yaml" '^  labNetworking: true' "runtime ${rt}: labNetworking is true"
done
for rt in eks existing; do
  has "runtimes/${rt}.yaml" '^  labNetworking: false' "runtime ${rt}: labNetworking is false"
done

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
# the production profile renders none of it (the lab-only Go files are named only by a cluster that sets the keys)
PX="${TMP}/prodx"; mkdir -p "${PX}"
cp "${LAB}/prod/cluster.yaml" "${PX}/cluster.yaml"
render_ok "${PX}" "prod profile, no gateway keys"
[ -n "$(find "${PX}/55-autopilot" -type f 2>/dev/null | head -1)" ] && ok "prod profile: the Autopilot files render (the check below is not vacuous)" || ok "prod profile: no Autopilot files (nothing to switch)"
if grep -rq 'autopilot-gateway-go\|gateway-go-v\|autopilot-gateway-migrate' "${PX}" --exclude=cluster.yaml; then bad "prod profile: renders something of the Go gateway or the migrate Job"; else ok "prod profile: nothing of the Go gateway or migrate Job renders"; fi

# A-9 S9 step 2 ("switch") on a lab: the Go gateway serves, the Python Deployments are gone, the lab alias is the one the Python gateway had,
# the migrate Job runs as the PreSync step before the switch, and no egress policy renders (egress.enabled: false, as the Python gateway has none)
LG="${TMP}/labgo"; mkdir -p "${LG}/py" "${LG}/go"
new "${LG}/py" dev lab-go kiac --repo-url https://github.com/acme/g --scm-owner acme --tower-cluster lab-prod \
  --set tower.hostAliasIP=192.0.2.5 --set components.autopilot=true --set components.serviceCatalog.enabled=true --set components.serviceCatalog.scope=full
printf '%s\n' 'autopilot:' '  people: [alice]' >>"${LG}/py/cluster.yaml"
cp "${LG}/py/cluster.yaml" "${LG}/go/cluster.yaml"
printf '%s\n' '  gateway:' '    implementation: go' '    go:' '      tag: gateway-go-v0.1.0' \
  '      digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' '      migrateJob: true' '      registeredVersion: held' \
  '      brokerUrl: http://broker.platform-system.svc:8080' '      githubOwners: [acme]' '      airframeUpperClusters: [lab-prod]' \
  '      agentXRs: {namespaces: [app-agents], names: {reader: app-agents}}' \
  '      plainHttp: {glidepath: true, broker: true, logs: true, catalog: true, jwks: true, clearanceApi: true}' '      egress: {enabled: false}' >>"${LG}/go/cluster.yaml"
python3 hack/check.py --cluster "${LG}/go/cluster.yaml" >/dev/null 2>"${TMP}/lg-check" && ok "lab go: passes check" || bad "lab go: check: $(cat "${TMP}/lg-check")"
render_ok "${LG}/py" "lab (Python gateway)"
render_ok "${LG}/go" "lab (Go gateway, step 2)"
expect "${LG}/go" "lab step 2" 55-autopilot/gateway/gateway-go.yaml 55-autopilot/gateway/autopilot-api-go.yaml 55-autopilot/gateway/gateway-go-extras.yaml \
  55-autopilot/gateway/gateway-go-migrate.yaml '!55-autopilot/gateway/gateway.yaml' '!55-autopilot/gateway/autopilot-api.yaml' '!55-autopilot/gateway/gateway-go-egress.yaml'
LGG="${LG}/go/55-autopilot/gateway"
has "${LGG}/gateway-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "lab step 2: the Go gateway is in wave 2, after the migrate Job (wave 1)"
has "${LGG}/autopilot-api-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "lab step 2: the Go read API is in wave 2, after the migrate Job (wave 1)"
has "${LGG}/gateway-go-migrate.yaml" 'name: autopilot-gateway-migrate-v0-1-0-dddddddd' "lab step 2: the migrate Job is named for the image and stays in the render (it ran in step 1; a new image would run it again)"
if grep -q 'argocd\.argoproj\.io/hook' "${LGG}/gateway-go-migrate.yaml" "${LGG}/gateway-go.yaml" "${LGG}/autopilot-api-go.yaml"; then bad "lab step 2: an Argo CD hook annotation rendered"; else ok "lab step 2: no hooks (nothing relies on a hook running)"; fi
has "${LGG}/gateway-go.yaml" 'strategy: \{type: Recreate\}' "lab step 2: the gateway Deployment is Recreate (the writer lock is released before the next pod starts)"
has "${LGG}/gateway-go.yaml" 'replicas: 1' "lab step 2: one gateway replica"
has "${LGG}/autopilot-api-go.yaml" 'replicas: 2' "lab step 2: two read API replicas"
has "${LGG}/gateway-go.yaml" 'ip: "192\.0\.2\.5"' "lab step 2: the Go gateway gets the lab alias the Python gateway had (tower.hostAliasIP)"
has "${LG}/py/55-autopilot/gateway/gateway.yaml" 'ip: "192\.0\.2\.5"' "lab: the Python gateway has the same alias"
has "${LGG}/gateway-go.yaml" 'image: [^ ]*/autopilot-gateway-go:gateway-go-v0\.1\.0@sha256:d{64}$' "lab step 2: the Go gateway pins tag and digest"
has "${LG}/go/55-clearance/clearance/application.yaml" '"version": "held"' "lab step 2: go.registeredVersion holds the registration (the core's CLEARANCE_PROVIDERS)"
if grep -q 'gateway-go-v0.1.0' "${LG}/go/55-clearance/clearance/application.yaml"; then bad "lab step 2: the Go tag reached the Clearance Application despite registeredVersion"; else ok "lab step 2: the Go tag is not in the Clearance Application"; fi
sed 's/"version": "held"/"version": "PY"/' "${LG}/go/55-clearance/clearance/application.yaml" >"${TMP}/lg-go-app"
V="$(grep -o '"name": "autopilot-gateway", "version": "[^"]*"' "${LG}/py/55-clearance/clearance/application.yaml" | sed 's/.*"version": "\([^"]*\)"/\1/')"
sed "s/\"version\": \"PY\"/\"version\": \"${V}\"/" "${TMP}/lg-go-app" | diff -q - "${LG}/py/55-clearance/clearance/application.yaml" >/dev/null \
  && ok "lab step 2: apart from that held value the Clearance Application is the Python render's (the switch does not touch the core)" || bad "lab step 2: the Clearance Application differs from the Python render"
refuse "an empty registeredVersion" "${K}/go" '      registeredVersion: ""'
for e in EVENTS_RABBITMQ_ENABLED AUTOPILOT_EPHEMERAL CLEARANCE_EPHEMERAL CLEARANCE_DSN CLEARANCE_VERIFIERS AGENT_LOGINS CLEARANCE_GITHUB GATEWAY_API_TABLES; do
  if grep -q "name: ${e}" "${LGG}/gateway-go.yaml" "${LGG}/autopilot-api-go.yaml"; then bad "lab step 2: ${e} is set, and the Go gateway refuses it"; else ok "lab step 2: ${e} (refused by the Go gateway) is not set"; fi
done

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
if out="$(python3 tests/policy/test_tenant_delete_guard.py "${TMP}/delete-guard-deny" "${TMP}/delete-guard" 2>&1)"; then
  ok "tenant-onboarding delete guard: $(tail -1 <<<"${out}")"
else
  bad "tenant-onboarding delete guard: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi

# W-43: the gated set's two ApplicationSets (rendered above as gate-set and gate-set-handover) run by the real Argo CD
# ApplicationSet controller (tests/appset, the Argo CD Go module argocd-apps runs) against envtest: one set per environment,
# the ignore rule and preservedFields only in the gated set, and the handover in both directions keeping the Application.
# W-46 (d): the same with the delete guard in Deny (delete-guard-deny), the controller running as the user it names
# (TestDeleteGuard): bare flips and a removed identity keep the Application, the handovers still pass.
# The migration window (gate-window, TestMigrationWindow): only the window's apps reach the gated set, the held app stays in
# tenant-onboarding on the plugin, and a paused environment has no automated sync in every templatePatch branch.
if ! command -v go >/dev/null 2>&1; then
  if [ "${APRON_REQUIRE_ENVTEST:-}" = 1 ]; then bad "tenant-onboarding gated set: go is not installed"; else echo "  skip tenant-onboarding gated set (tests/appset): go is not installed"; fi
elif out="$(cd tests/appset && APRON_GATED_RENDER="${TMP}/gate-set" APRON_GATED_HANDOVER_RENDER="${TMP}/gate-set-handover" APRON_DELETE_GUARD_RENDER="${TMP}/delete-guard-deny" APRON_WINDOW_RENDER="${TMP}/gate-window" go test -count=1 -v -run 'TestGatedSet|TestDeleteGuard|TestMigrationWindow' ./... 2>&1)"; then
  if grep -q -- '--- SKIP' <<<"${out}"; then echo "  skip tenant-onboarding gated set (tests/appset): $(grep -m1 -A1 -- '--- SKIP' <<<"${out}" | tail -1 | sed 's/^ *//')"
  else ok "tenant-onboarding gated set against Argo CD's ApplicationSet controller: $(grep -c -- '^    --- PASS' <<<"${out}") cases"; fi
else
  bad "tenant-onboarding gated set: $(grep -E -- '--- FAIL|gatedset_test.go:[0-9]+:' <<<"${out}" | head -8)"
fi

echo "== 6. agentrun-reaper (the script in its ConfigMap, against a fake API)"
if out="$(python3 tests/reaper/test_reaper.py 2>&1)"; then
  ok "agentrun-reaper: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "agentrun-reaper: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi

echo "== 7. clearance-targets publisher (the script in its ConfigMap: retry on a dropped connection, none on a refusal)"
if out="$(python3 tests/targets/test_publisher.py 2>&1)"; then
  ok "clearance-targets publisher: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "clearance-targets publisher: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi

echo
echo "${PASS} passed, ${FAIL} failed$( [ "${HAVE_YAML}" = true ] || echo ' (YAML parse skipped: no PyYAML)')"
[ "${FAIL}" -eq 0 ]
