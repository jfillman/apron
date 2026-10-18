#!/usr/bin/env bash
# Offline tests for ./apron: fake kubectl/kiac/kind/gh/docker on PATH, stub hack/{render,check,new_cluster}.py.
# APRON_IMPL_ROOT=DIR uses DIR's real hack/*.py instead of tests/stubs (integration with the other branch).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=fakebin.sh
. "${HERE}/fakebin.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*"; [ -z "${OUTPUT:-}" ] || sed 's/^/     | /' <<<"${OUTPUT}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
ROOT="${WORK}/apron-root"; mkdir -p "${ROOT}/hack" "${ROOT}/docs"
cp "${REPO}/apron" "${ROOT}/"; cp "${REPO}/hack/cluster-identity.sh" "${REPO}/hack/apron_fleet.py" "${ROOT}/hack/"
cp "${REPO}/docs/after-up.md" "${ROOT}/docs/"
cp "${APRON_IMPL_ROOT:-${REPO}/tests/stubs}/hack/"{render,check,new_cluster}.py "${ROOT}/hack/"
# Integration: the real implementation's whole tree (templates etc.), with this branch's CLI on top.
if [ -n "${APRON_IMPL_ROOT:-}" ]; then
  tar -C "${APRON_IMPL_ROOT}" --exclude=.git --exclude=./apron -cf - . | tar -C "${ROOT}" -xf -
  cp "${REPO}/apron" "${REPO}/hack/apron_fleet.py" "${ROOT}/" && mv "${ROOT}/apron_fleet.py" "${ROOT}/hack/"
fi
export PATH="${WORK}/bin:${PATH}"; make_fakes "${WORK}/bin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OWNER="example-org"   # a test fixture, not a default

reset() { export FAKE_STATE="${WORK}/state-$1" FAKE_LOG="${WORK}/log-$1"; rm -rf "${FAKE_STATE}"; mkdir -p "${FAKE_STATE}"; : >"${FAKE_LOG}"; }
apron() { "${ROOT}/apron" "$@"; }
# fleet_args PROFILE: the inputs check.py requires (prod clusters join the fleet of a dev hub; Tower runs on "tw").
fleet_args() {
  FLEET=(--tower-cluster tw)
  [ "$1" = dev ] || FLEET+=(--fleet-hub hub --fleet-repo-url "https://example.test/${OWNER}/gitops-hub.git")
}
# init_cluster ID PROFILE RUNTIME NAME [EXTRA...]
init_cluster() {
  local id="$1" profile="$2" runtime="$3" name="$4"; shift 4; fleet_args "${profile}"
  # Workaround (apron-up dc14b00): render.py needs Traefik NodePorts on runtime existing too, though it uses LoadBalancer.
  [ "${runtime}" != existing ] || FLEET+=(--set traefik.httpNodePort=30080 --set traefik.httpsNodePort=30443)
  OUTPUT="$(apron init "${profile}" --name "${name}" --runtime "${runtime}" --out "${WORK}/${id}" \
    --repo-url "https://example.test/${OWNER}/gitops-${name}.git" --scm-owner "${OWNER}" "${FLEET[@]}" "$@" 2>&1)" \
    || { fail "init ${id}"; return 1; }
}
apron_values() { python3 "${ROOT}/hack/render.py" --cluster "${WORK}/$1/cluster.yaml" --print-values | jq -r "$2"; }
has()    { grep -qF -- "$2" <<<"$1"; }
logged() { grep -qxF -- "$1" "${FAKE_LOG}"; }

# --- dry runs: the exact commands per runtime x profile ----------------------------------------------------------
dry_case() {   # ID PROFILE RUNTIME NAME EXPECTED-LINE...
  local id="$1" profile="$2" runtime="$3" name="$4"; shift 4
  reset "${id}"; init_cluster "${id}" "${profile}" "${runtime}" "${name}" || return 0
  : >"${FAKE_LOG}"
  OUTPUT="$(apron up --out "${WORK}/${id}" --dry-run 2>&1)" || { fail "up --dry-run ${id} exited non-zero"; return 0; }
  local want missing=""
  local cni; cni="$(apron_values "${id}" '.cni.manifest // ""')"
  for want in "$@"; do want="${want//@CNI@/${cni}}"; has "${OUTPUT}" "${want}" || missing+=" [${want}]"; done
  has "${OUTPUT}" "--gateway" && missing+=" [no --gateway]"
  if grep -vE '^kubectl config get-contexts|^(kiac|kind) get clusters' "${FAKE_LOG}" | grep -q .; then missing+=" [touched: $(tr '\n' ';' <"${FAKE_LOG}")]"; fi
  [ -z "${missing}" ] && pass "up --dry-run ${id}" || fail "up --dry-run ${id}: missing${missing}"
}
D="${WORK}"
dry_case existingprod prod existing ep \
  "+ kubectl --context ep get --raw /readyz" \
  "+ kubectl --context ep create namespace argocd" \
  "+ kubectl --context ep apply --server-side -n argocd -f ${D}/existingprod/01-argocd-platform/install.yaml" \
  "+ kubectl --context ep -n crossplane-system get secret provider-infisical-creds" \
  "+ kubectl --context ep apply -f ${D}/existingprod/root-app-of-apps.yaml"
dry_case kiacdev dev kiac kd \
  "+ kiac create cluster --name kd --workers 0 --cni cilium --kernel full --cpus 10 --cp-memory 32G" \
  "+ kubectl config rename-context kiac-kd kd" \
  "CNI: provided by the runtime" \
  "+ kubectl --context kd -n infisical get secret infisical-secrets" \
  "+ kubectl --context kd -n infisical get secret infisical-bootstrap-credentials" \
  "+ kubectl --context kd apply -f ${D}/kiacdev/root-app-of-apps.yaml"
dry_case kindprod prod kind kp \
  "+ kind create cluster --name kp --config ${D}/kindprod/hack/kind-config.yaml" \
  "+ kubectl config rename-context kind-kp kp" \
  "+ kubectl --context kp apply --server-side -f @CNI@" \
  "+ kubectl --context kp apply --server-side -n argocd -f ${D}/kindprod/01-argocd-platform/install.yaml"

# --- real run (fakes): kiac+dev creates, renames the context, stops on missing secrets, then completes -------------
reset kiac-run; init_cluster kiac-run dev kiac kr && {
  OUTPUT="$(apron up --out "${WORK}/kiac-run" --yes 2>&1)"; rc=$?
  if [ ${rc} -eq 0 ] && logged "kiac create cluster --name kr --workers 0 --cni cilium --kernel full --cpus 10 --cp-memory 32G" \
     && logged "kubectl config rename-context kiac-kr kr" && grep -qx kr "${FAKE_STATE}/contexts" \
     && has "${OUTPUT}" "re-run apron up to continue" && has "${OUTPUT}" "create secret generic infisical-secrets" \
     && ! grep -q "apply -f .*root-app-of-apps" "${FAKE_LOG}"; then
    pass "up kiac+dev: creates, renames context, stops (exit 0) on missing Secrets"
  else fail "up kiac+dev first run (rc=${rc})"; fi
  ! grep -qE "get secret [^ ]+ .*-o (yaml|json|jsonpath)" "${FAKE_LOG}" && pass "secret check never reads data" || fail "secret data read"
  printf '%s\n' argocd/argocd-repo-creds-${OWNER} infisical/infisical-secrets infisical/infisical-bootstrap-credentials >"${FAKE_STATE}/secrets"
  : >"${FAKE_LOG}"
  OUTPUT="$(apron up --out "${WORK}/kiac-run" --yes 2>&1)" && ! grep -q "kiac create" "${FAKE_LOG}" \
    && ! grep -q "rename-context" "${FAKE_LOG}" && logged "kubectl --context kr apply -f ${WORK}/kiac-run/root-app-of-apps.yaml" \
    && has "${OUTPUT}" "Manual syncs" \
    && pass "up kiac+dev re-run: skips create and rename, applies root, prints next steps" || fail "up kiac+dev re-run"
}

# --- existing: context must equal the name -------------------------------------------------------------------------
reset ex; init_cluster ex dev existing exc && {
  echo some-admin@corp >"${FAKE_STATE}/contexts"
  OUTPUT="$(apron up --out "${WORK}/ex" --yes 2>&1)" && fail "existing without context should fail" \
    || { has "${OUTPUT}" "--rename-context" && pass "existing: refuses when context != name" || fail "existing refusal message"; }
  OUTPUT="$(apron up --out "${WORK}/ex" --yes --rename-context some-admin@corp 2>&1)" \
    && logged "kubectl config rename-context some-admin@corp exc" && pass "existing: --rename-context renames" || fail "existing rename"
}
reset ex2; init_cluster ex2 prod existing exp --context corp-admin && {
  echo corp-admin >"${FAKE_STATE}/contexts"
  OUTPUT="$(apron up --out "${WORK}/ex2" --yes 2>&1)" && logged "kubectl config rename-context corp-admin exp" \
    && has "${OUTPUT}" "re-run apron up to continue" && pass "existing: init --context is adopted and renamed by up" || fail "existing init --context"
}

# --- validation ----------------------------------------------------------------------------------------------------
reset val
OUTPUT="$(apron init dev --name Bad_Name --runtime kiac --out "${WORK}/v1" --repo-url https://example.test/${OWNER}/r --scm-owner "${OWNER}" 2>&1)" \
  && fail "bad name accepted" || { has "${OUTPUT}" "DNS-1123" && pass "rejects a non-DNS-1123 name" || fail "bad name message"; }
OUTPUT="$(apron init dev --name ok --runtime kiac --out "${WORK}/v2" --repo-url https://example.test/${OWNER}/r 2>&1)" \
  && fail "missing owner accepted" || { has "${OUTPUT}" "no default owner" && pass "requires --scm-owner" || fail "owner message"; }
OUTPUT="$(apron init dev --name ok --runtime kiac --out "${WORK}/v3" --repo-url https://example.test/${OWNER}/r --scm-owner "-bad-" 2>&1)" \
  && fail "bad owner accepted" || pass "rejects an invalid owner"
OUTPUT="$(apron init dev --name ok --runtime kiac --out "${WORK}/v4" --repo-url https://example.test/${OWNER}/r --scm-owner "${OWNER}" --context other 2>&1)" \
  && fail "context != name accepted" || pass "rejects --context different from --name"

# --- init --create-repos --push ------------------------------------------------------------------------------------
reset repos; echo "${OWNER}/gitops-pr-tenants" >"${FAKE_STATE}/repos"
git init -q --bare "${WORK}/remote/${OWNER}/gitops-pr.git"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.${WORK}/remote/.insteadOf" GIT_CONFIG_VALUE_0="https://example.test/"
fleet_args prod
OUTPUT="$(apron init prod --name pr --runtime kind --out "${WORK}/pr" --repo-url "https://example.test/${OWNER}/gitops-pr.git" \
  --scm-owner "${OWNER}" "${FLEET[@]}" --create-repos --push 2>&1)" \
  && logged "gh repo create ${OWNER}/gitops-pr --private" && ! grep -q "repo create ${OWNER}/gitops-pr-tenants" "${FAKE_LOG}" \
  && has "${OUTPUT}" "skipped ${OWNER}/gitops-pr-tenants" \
  && git -C "${WORK}/remote/${OWNER}/gitops-pr.git" rev-parse -q --verify main >/dev/null \
  && pass "init --create-repos --push: creates only missing repos, pushes main" || fail "init --create-repos --push"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
OUTPUT="$(apron render --out "${WORK}/pr" 2>&1)" && has "${OUTPUT}" "no changes" && pass "render: re-render is clean" || fail "render"

# --- fleet ---------------------------------------------------------------------------------------------------------
reset fleet
OUTPUT="$(apron fleet add --from "${WORK}/kiac-run" --fleet "${WORK}/clusters.yaml" 2>&1 \
  && apron fleet add --from "${WORK}/pr" --fleet "${WORK}/clusters.yaml" 2>&1 \
  && apron fleet set-infisical --fleet "${WORK}/clusters.yaml" --org-id ORG --url http://i.example/api --in-cluster-url http://i.svc/api 2>&1)" \
  && [ "$(yq -r '.clusters | length' "${WORK}/clusters.yaml")" = 2 ] && [ "$(yq -r .scm.owner "${WORK}/clusters.yaml")" = "${OWNER}" ] \
  && [ "$(yq -r '.clusters[0].airframe.cicdReady' "${WORK}/clusters.yaml")" = false ] \
  && [ "$(yq -r '.clusters[1].serviceAccountIssuer' "${WORK}/clusters.yaml")" = "$(apron_values pr .issuer)" ] \
  && [ "$(yq -r .infisical.orgId "${WORK}/clusters.yaml")" = ORG ] \
  && pass "fleet add / set-infisical" || fail "fleet"

# --- no hardcoded cluster names or owners (pattern assembled so this file does not match itself) ---
BANNED="jfill""man|kiac""-dev|kind""-(prod|dev)|hangar""-(dev|prod)"
# ----------------------------------------------------------------------------
hits="$(grep -nE "${BANNED}" "${REPO}/apron" "${REPO}/hack/apron_fleet.py" "${REPO}/docs/cli.md" "${REPO}/docs/after-up.md" "${HERE}"/*.sh || true)"
[ -z "${hits}" ] && pass "no hardcoded cluster names or owners in the CLI, its docs and tests" || { OUTPUT="${hits}"; fail "hardcoded names"; }

echo; echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
