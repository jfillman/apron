#!/usr/bin/env bash
# tests/run.sh - offline tests for Apron's renderer and checks. No cluster, no network.
#
#   1. render: the lab pair (dev on kiac as hangar-dev, prod on kind as hangar-prod), the cross pair (dev on kind,
#      prod on kiac) and both profiles on an existing cluster with another SCM host/owner. Each must leave no @@, no
#      old cluster name, no hardcoded owner; every YAML must parse (if python3 has PyYAML) and every script `bash -n`.
#   2. re-render: a second render changes nothing; removing a component removes its files; cluster.yaml survives.
#   3. check: each invariant violation is refused.
#   4. TOKENS.md lists exactly the tokens templates use.
#   5. the AgentRun confinement policy admits a run's objects and refuses everything D15 forbids (skipped without
#      envtest binaries in KUBEBUILDER_ASSETS: tests/policy/test_agentrun_grants.py).
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
refuse "an invalid name" "${D}" 'name: Hangar_Dev'
refuse "a name longer than 63" "${D}" "name: $(printf 'a%.0s' {1..64})"
refuse "no scm owner" "${P}" 'scm: {owner: ""}'
refuse "an unknown runtime" "${P}" 'runtime: {type: minikube}'
refuse "providerGithub off the control plane" "${P}" 'components: {crossplane: {providerGithub: true}}'
refuse "glidepath off the control plane" "${P}" 'components: {glidepath: true}'
refuse "autopilot off the control plane" "${P}" 'components: {autopilot: true}'
refuse "scope full off the control plane" "${P}" 'components: {serviceCatalog: {enabled: true, scope: full}}'
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

echo "== 5. policy (55-autopilot/agentrun-grants against a real kube-apiserver; needs KUBEBUILDER_ASSETS)"
if out="$(python3 tests/policy/test_agentrun_grants.py 2>&1)"; then
  ok "agentrun-grants: $(tail -1 <<<"${out}")"
else
  bad "agentrun-grants: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
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
