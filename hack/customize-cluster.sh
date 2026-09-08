#!/usr/bin/env bash
# hack/customize-cluster.sh
#
# Turns this template repo into a real gitops-cluster-<name> repo: reads cluster.yaml
# (copy cluster.yaml.example first, see that file's own header), validates it,
# deletes whichever optional component directories weren't selected, and substitutes
# this template's own literal identity strings (repo name, cluster name, Infisical
# project slug) with the new cluster's real values throughout every remaining file.
#
# Same conventions as platform-cicd/hack/bootstrap-upper-cluster.sh and
# hack/generate-cluster-values.sh: require()/log()/warn() helpers, refuses rather
# than guesses on ambiguous or invalid input, idempotent is NOT claimed here (unlike
# those two) — this script is meant to run exactly once, against a fresh clone of
# this template, never against an already-customized repo. Re-running it against a
# repo it already customized will not find its own source literals anymore and is a
# no-op at best, a source of confusing partial-double-substitution at worst if you've
# since introduced a real reference to "kind-dev" or "gitops-cluster-dev" of your own
# (e.g. a cross-cluster relay URL comment). Re-clone the template for a second cluster
# instead of reusing a customized checkout.
#
# See idp/docs/cluster-provisioning.md for the full design.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONFIG="${1:-cluster.yaml}"

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }
die() { echo -e "\033[1;31merror: $*\033[0m" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

require yq
require git

[ -f "${CONFIG}" ] || die "${CONFIG} not found. Copy cluster.yaml.example to cluster.yaml and edit it first — there is no silent default."

# --- 1. Read config -----------------------------------------------------------

CLUSTER_NAME="$(yq -r '.clusterName' "${CONFIG}")"
CLUSTER_REPO_NAME="$(yq -r '.clusterRepoName' "${CONFIG}")"
TYPE="$(yq -r '.type' "${CONFIG}")"
TENANTS_REPO="$(yq -r '.tenantsRepo' "${CONFIG}")"

[ "${CLUSTER_NAME}" != "null" ] && [ -n "${CLUSTER_NAME}" ] || die "clusterName is required in ${CONFIG}."
[ "${CLUSTER_REPO_NAME}" != "null" ] && [ -n "${CLUSTER_REPO_NAME}" ] || die "clusterRepoName is required in ${CONFIG}."
case "${TYPE}" in
  dev|upper) ;;
  *) die "type must be 'dev' or 'upper' in ${CONFIG} (got '${TYPE}')." ;;
esac
[ "${TENANTS_REPO}" != "null" ] && [ -n "${TENANTS_REPO}" ] || die "tenantsRepo is required in ${CONFIG}."

SCM_HOST="$(yq -r '.scm.host' "${CONFIG}")"
SCM_OWNER="$(yq -r '.scm.owner' "${CONFIG}")"
REGISTRY_HOST="$(yq -r '.registry.host' "${CONFIG}")"
REGISTRY_OWNER="$(yq -r '.registry.owner' "${CONFIG}")"
[ "${SCM_HOST}" != "null" ] && [ -n "${SCM_HOST}" ] || die "scm.host is required in ${CONFIG}."
[ "${SCM_OWNER}" != "null" ] && [ -n "${SCM_OWNER}" ] || die "scm.owner is required in ${CONFIG}."
[ "${REGISTRY_HOST}" != "null" ] && [ -n "${REGISTRY_HOST}" ] || die "registry.host is required in ${CONFIG}."
[ "${REGISTRY_OWNER}" != "null" ] && [ -n "${REGISTRY_OWNER}" ] || die "registry.owner is required in ${CONFIG}."

yq_bool() { yq -r "$1" "${CONFIG}"; }

PROVIDER_GITHUB="$(yq_bool '.components.crossplane.providerGithub')"
PLATFORM_CICD="$(yq_bool '.components.platformCicd')"
CERT_MANAGER="$(yq_bool '.components.certManager')"
EXTERNAL_SECRETS="$(yq_bool '.components.externalSecrets')"
INFISICAL_HOST="$(yq_bool '.components.secrets.infisicalHost')"
ARGO_ROLLOUTS="$(yq_bool '.components.argoRollouts')"
CONTOUR="$(yq_bool '.components.contour')"
SLOTH="$(yq_bool '.components.sloth')"
SERVICE_CATALOG_ENABLED="$(yq_bool '.components.serviceCatalog.enabled')"
SERVICE_CATALOG_SCOPE="$(yq -r '.components.serviceCatalog.scope' "${CONFIG}")"
OBSERVABILITY="$(yq_bool '.components.observability')"
POLICY="$(yq_bool '.components.policy')"
BACKSTAGE="$(yq_bool '.components.backstage')"

log "0/5 - target cluster: ${CLUSTER_NAME} (type: ${TYPE})"

# --- 2. Hard invariants — refuse, don't silently correct ----------------------
#
# Bootstrap-tier XRDs (provider-github) and platform-cicd's own control plane are
# permanently centralized on the fleet's one dev cluster (idp/docs/
# service-catalog-design.md §0). A type: upper cluster requesting either is a real
# misconfiguration, not a style choice — refuse rather than proceed and produce a
# cluster that quietly violates an architectural invariant the rest of this platform
# assumes holds everywhere.

if [ "${TYPE}" = "upper" ] && [ "${PROVIDER_GITHUB}" = "true" ]; then
  die "type: upper cannot set components.crossplane.providerGithub: true — Bootstrap-tier XRDs (NodeJSApplication/ApplicationEnvironment) stay dev-cluster-only permanently. See idp/docs/service-catalog-design.md §0."
fi
if [ "${TYPE}" = "upper" ] && [ "${PLATFORM_CICD}" = "true" ]; then
  die "type: upper cannot set components.platformCicd: true — platform-cicd's control plane runs on the fleet's one dev cluster only."
fi
if [ "${TYPE}" = "upper" ] && [ "${SERVICE_CATALOG_SCOPE}" = "full" ]; then
  die "type: upper should not set components.serviceCatalog.scope: full — that includes Bootstrap-tier XRDs, which require providerGithub (refused above). Use scope: attached-tier-only."
fi

log "1/5 - pruning components not selected in ${CONFIG}"

prune() {
  local path="$1"
  if [ -e "${path}" ]; then
    rm -r "${path}"
    echo "  removed ${path}"
  fi
}

[ "${PROVIDER_GITHUB}" = "true" ] || {
  prune "10-crds-operators/crossplane/provider-github.yaml"
  prune "10-crds-operators/crossplane/provider-github-config.yaml"
}
[ "${CERT_MANAGER}" = "true" ]     || prune "10-crds-operators/cert-manager"
[ "${ARGO_ROLLOUTS}" = "true" ]    || prune "10-crds-operators/argo-rollouts"
[ "${CONTOUR}" = "true" ]          || prune "10-crds-operators/contour"
[ "${SLOTH}" = "true" ]            || prune "10-crds-operators/sloth"
[ "${POLICY}" = "true" ]           || prune "30-policy"
[ "${OBSERVABILITY}" = "true" ]    || prune "40-observability"
[ "${PLATFORM_CICD}" = "true" ]    || prune "50-platform-cicd"
[ "${BACKSTAGE}" = "true" ]        || prune "60-backstage"

if [ "${TYPE}" = "upper" ]; then
  # Lower/ephemeral environments are a dev-cluster-only self-service tier by design —
  # a real security boundary, not just an unused feature (idp/docs/gitops-strategy.md
  # §10: the whole point is that a staging/prod namespace can never be mistaken for
  # one). Real precedent: gitops-cluster-kind-prod never carried these two files.
  prune "02-argocd-apps/tenant-appprojects/chart/templates/appproject-lower.yaml"
  prune "02-argocd-apps/tenant-appprojects/chart/templates/lower-envs-applicationset.yaml"
fi

if [ "${EXTERNAL_SECRETS}" = "true" ]; then
  if [ "${INFISICAL_HOST}" = "true" ]; then
    # This cluster runs the real Infisical server — the other clusters' "remote
    # consumer" files don't apply here.
    prune "10-crds-operators/external-secrets/cluster-secret-store.yaml"
    prune "10-crds-operators/external-secrets/infisical-project.yaml"
    prune "10-crds-operators/external-secrets/registry-credentials-cluster-external-secret.yaml"
    prune "10-crds-operators/external-secrets/packages-application.yaml"
    prune "10-crds-operators/infisical-secretstore-operator/deployment.remote-consumer.yaml"
  else
    # Remote consumer — this cluster doesn't run its own Infisical server, so it also
    # doesn't need the NodePort that exposes it cross-cluster or the ServiceAccount
    # Infisical's own Kubernetes Auth uses to TokenReview against THIS cluster's API
    # (only the host cluster's Infisical instance validates Kubernetes Auth requests
    # at all — every other cluster, including a hypothetical second dev cluster, uses
    # Universal Auth instead, per gitops-cluster-dev's own cluster-registry
    # infisicalHost note).
    prune "10-crds-operators/infisical"
    prune "10-crds-operators/infisical-secretstore-operator/infisical-nodeport.yaml"
    prune "10-crds-operators/infisical-secretstore-operator/token-reviewer-rbac.yaml"
    # Swap in the remote-consumer variant of the operator's own Deployment - same
    # full/attached-tier-only swap pattern as idp-service-catalog/application.yaml
    # below. Real bug this closes: the host-variant deployment.yaml (still the
    # unconditional default before this swap existed) references
    # infisical-token-reviewer-token, a Secret that token-reviewer-rbac.yaml (just
    # pruned above) is the only thing that ever creates - CreateContainerConfigError
    # on every remote-consumer cluster, caught live on kind-man 2026-08-26.
    prune "10-crds-operators/infisical-secretstore-operator/deployment.yaml"
    mv "10-crds-operators/infisical-secretstore-operator/deployment.remote-consumer.yaml" \
       "10-crds-operators/infisical-secretstore-operator/deployment.yaml"
  fi
else
  prune "10-crds-operators/external-secrets"
  prune "10-crds-operators/infisical"
fi

if [ "${SERVICE_CATALOG_ENABLED}" = "true" ]; then
  case "${SERVICE_CATALOG_SCOPE}" in
    full)
      prune "20-service-catalog/idp-service-catalog/application.attached-tier-only.yaml"
      ;;
    attached-tier-only)
      prune "20-service-catalog/idp-service-catalog/application.yaml"
      mv "20-service-catalog/idp-service-catalog/application.attached-tier-only.yaml" \
         "20-service-catalog/idp-service-catalog/application.yaml"
      ;;
    *)
      die "components.serviceCatalog.scope must be 'full' or 'attached-tier-only' (got '${SERVICE_CATALOG_SCOPE}')."
      ;;
  esac
else
  prune "20-service-catalog"
  prune "02-argocd-apps/xr-requests"
fi

log "2/5 - generating fresh per-cluster secret material (never copied from another cluster)"
INFISICAL_PG_PASSWORD=""
INFISICAL_REDIS_PASSWORD=""
if [ "${INFISICAL_HOST}" = "true" ]; then
  require openssl
  INFISICAL_PG_PASSWORD="$(openssl rand -hex 20)"
  INFISICAL_REDIS_PASSWORD="$(openssl rand -hex 20)"
fi
REKOR_MYSQL_PASSWORD=""
REKOR_MYSQL_ROOT_PASSWORD=""
if [ "${PLATFORM_CICD}" = "true" ]; then
  # Low-stakes internal DB auth, not real crypto material - see
  # 50-platform-cicd/rekor/values-secrets.yaml's own header for why a committed value
  # is fine here (unlike Fulcio's signing key, which this script never touches at all -
  # hooks/fulcio-bootstrap-job.yaml generates that one live, inside the cluster).
  require openssl
  REKOR_MYSQL_PASSWORD="$(openssl rand -hex 20)"
  REKOR_MYSQL_ROOT_PASSWORD="$(openssl rand -hex 20)"
fi

log "3/5 - substituting identity strings"
# Longest/most-specific literal first — gitops-cluster-dev-tenants is a superstring of
# gitops-cluster-dev, so it must be replaced before the bare form or it would already
# be partially consumed by that rule. Two source-cluster literals exist in this
# template's own fileset (kind-dev, from most files; kind-prod, from the files copied
# in from gitops-cluster-kind-prod for the attached-tier-only/remote-consumer variants)
# — both map to this cluster's real name. This is a known, closed list of literal
# strings this specific curated template happens to contain, not a general templating
# engine — if this repo ever grows a genuine cross-cluster reference by name (the way
# gitops-cluster-dev's own values-kind-dev.yaml lists kind-prod in its clusters:
# list), a blanket replace here would be wrong; there is none today; see
# idp/docs/cluster-provisioning.md.
substitute() {
  local from="$1" to="$2"
  # Excludes hack/ entirely — this script must never rewrite itself while running
  # (undefined, and confirmed live to actually corrupt itself: a still-running bash
  # process doesn't necessarily re-read edited-on-disk portions of its own script the
  # same way twice, and a second substitute() call can then match text a first call
  # already rewrote, e.g. "gitops-cluster-dev-tenants" in this file's own comments
  # becoming "gitops-cluster-dev22-tenants"). hack/'s own literal example strings
  # (cluster names used in comments/log messages) are meant to stay as written.
  grep -rl --null -F "${from}" . --exclude-dir=.git --exclude-dir=hack --exclude=cluster.yaml --exclude=cluster.yaml.example 2>/dev/null \
    | xargs -0 sed -i '' "s|${from}|${to}|g"
}

# SCM/registry host+owner, longest/most-specific literal first (same reasoning as
# below): the full https:// repoURL prefix, then the bare no-protocol prose form
# (functions.yaml's own "(github.com/jfillman)" comment), then the registry form,
# then a bare-owner catch-all for what's left (argocd-repo-creds-jfillman's own
# resource name, provider-github-config.yaml's credential-JSON example comment).
# Deliberately NOT a bare "github.com" replace — this repo also vendors real,
# unrelated third-party repoURLs (10-crds-operators/sloth/application.yaml's
# https://github.com/slok/sloth.git) that must stay exactly as they are.
substitute "https://github.com/jfillman/" "https://${SCM_HOST}/${SCM_OWNER}/"
substitute "github.com/jfillman" "${SCM_HOST}/${SCM_OWNER}"
substitute "ghcr.io/jfillman/" "${REGISTRY_HOST}/${REGISTRY_OWNER}/"
substitute "jfillman" "${SCM_OWNER}"

substitute "gitops-cluster-dev-tenants" "${TENANTS_REPO}"
substitute "gitops-cluster-dev" "${CLUSTER_REPO_NAME}"
substitute "gitops-cluster-kind-prod" "${CLUSTER_REPO_NAME}"
substitute "kind-dev" "${CLUSTER_NAME}"
substitute "kind-prod" "${CLUSTER_NAME}"
[ -z "${INFISICAL_PG_PASSWORD}" ]    || substitute "__INFISICAL_PG_PASSWORD__" "${INFISICAL_PG_PASSWORD}"
[ -z "${INFISICAL_REDIS_PASSWORD}" ] || substitute "__INFISICAL_REDIS_PASSWORD__" "${INFISICAL_REDIS_PASSWORD}"
[ -z "${REKOR_MYSQL_PASSWORD}" ]      || substitute "__REKOR_MYSQL_PASSWORD__" "${REKOR_MYSQL_PASSWORD}"
[ -z "${REKOR_MYSQL_ROOT_PASSWORD}" ] || substitute "__REKOR_MYSQL_ROOT_PASSWORD__" "${REKOR_MYSQL_ROOT_PASSWORD}"

# hack/kind-config.yaml is excluded from the sweep above (all of hack/ is), but it
# carries one real per-cluster field of its own — handled directly, not via
# substitute(), same self-mutation reason.
if [ -f "hack/kind-config.yaml" ]; then
  case "${CLUSTER_NAME}" in
    kind-*)
      sed -i '' "s|__KIND_SHORT_NAME__|${CLUSTER_NAME#kind-}|g" hack/kind-config.yaml
      ;;
    *)
      warn "clusterName '${CLUSTER_NAME}' doesn't start with kind- — hack/kind-config.yaml's name: field left as __KIND_SHORT_NAME__, edit it by hand (or delete the file if this isn't a local kind cluster)."
      ;;
  esac
fi

# values-kind-dev.yaml's own CONTENT already got "kind-dev" -> "${CLUSTER_NAME}"
# rewritten by the substitute() pass above (its own clusterName: field included) - only
# the FILENAME itself (and application.yaml's $ref to it, also content-rewritten
# already) needs a separate rename to match.
if [ "${PLATFORM_CICD}" = "true" ] && [ -f "50-platform-cicd/platform-cicd-control-plane/values-kind-dev.yaml" ]; then
  mv "50-platform-cicd/platform-cicd-control-plane/values-kind-dev.yaml" \
     "50-platform-cicd/platform-cicd-control-plane/values-${CLUSTER_NAME}.yaml"
fi

log "4/5 - cleanup"
rm -f "${CONFIG}"
echo "  removed ${CONFIG} (the substituted manifests are now the record, not a second copy of the same choices)"

log "5/5 - next steps (not automated by this script — each is a reviewed action)"
cat <<EOF
1. Review the diff, then commit + push this repo as a new GitHub repo named
   ${CLUSTER_REPO_NAME}.

2. Open a PR against gitops-cluster-dev adding
   00-bootstrap/cluster-registry/${CLUSTER_NAME}.yaml:

     apiVersion: v1
     kind: ConfigMap
     metadata:
       name: ${CLUSTER_NAME}
       namespace: crossplane-system
       labels:
         hangar.io/cluster-registry: "true"
     data:
       type: ${TYPE}
       cicdReady: "false"
       crossplaneReady: "false"
       tenantsRepo: ${TENANTS_REPO}

   Flip cicdReady/crossplaneReady to "true" only after live-verifying each
   (idp/docs/service-catalog-design.md §0) — this registry entry is what every
   NodeJSApplication.spec.devCluster / ApplicationEnvironment.spec.cluster gate reads.
   The registry is centralized on kind-dev by design (the only place it's read from);
   this script does not push to that repo itself.

$( [ "${INFISICAL_HOST}" = "true" ] && echo "3. Create infisical-secrets / infisical-bootstrap-credentials by hand before 10-crds-operators/infisical/application.yaml's first sync — see that file's own header for the exact kubectl create secret commands. Never paste these into chat." )
$( [ "${INFISICAL_HOST}" = "true" ] && echo "3b. Once Infisical's autoBootstrap Job has run, fill in the real org id in place of __INFISICAL_ORG_ID__ in 10-crds-operators/infisical-secretstore-operator/deployment.yaml — see that file's own header for the exact lookup command. Nothing reads InfisicalProject/InfisicalEnvironment CRs correctly until this is a real value." )
$( [ "${EXTERNAL_SECRETS}" = "true" ] && [ "${INFISICAL_HOST}" = "false" ] && echo "3c. Copy infisical-bootstrap-secret from kind-dev's infisical namespace into this cluster's own infisical namespace (kubectl-to-kubectl pipe, never pasted/displayed — see 10-crds-operators/infisical-secretstore-operator/deployment.yaml's own header) before the infisical-secretstore-operator Deployment can start. Also verify that file's INFISICAL_API_URL still matches kind-dev's live NodePort address — it drifts on kind-dev restarts/rebuilds and the committed value can be stale." )
$( [ "${PLATFORM_CICD}" = "true" ] && echo "4. Nothing to run by hand for Fulcio/Rekor - hooks/fulcio-bootstrap-job.yaml generates this cluster's own Fulcio root live on first sync (values-${CLUSTER_NAME}.yaml deliberately carries no Fulcio material, ADR-0006), and 50-platform-cicd/rekor/ deploys Rekor/Trillian/MySQL from the real upstream chart with the credentials already generated into values-secrets.yaml above. Only ever run platform-cicd/hack/generate-cluster-values.sh FORCE=1 by hand later, and only to deliberately rotate the Fulcio root." )

5. Run the real cluster bootstrap sequence (kind create cluster / Calico / apply
   01-argocd-platform/install.yaml --server-side / restore argocd-repo-creds-* /
   apply root-app-of-apps.yaml) — see this repo's own README.md, which mirrors
   gitops-cluster-kind-prod/README.md's already-proven "Bootstrap steps, in order".
EOF
