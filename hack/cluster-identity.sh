#!/usr/bin/env bash
# hack/cluster-identity.sh
#
# Cluster identity: give a cluster its own ServiceAccount token issuer, publish that issuer's discovery document and
# keys, and let other clusters' API servers trust it. The point is cross-cluster calls with short-lived, audience-bound
# ServiceAccount tokens instead of long-lived token Secrets (docs/cluster-identity.md; first user: Tower,
# ~/tech/SPEC-tower-cluster-credentials.md). Everything here is API-server flags and node files, so none of it can be
# an Argo CD Application.
#
#   render     --config cluster.yaml --out DIR
#              Write DIR/authentication-config.yaml from components.clusterIdentity.trust (the trusting side).
#   kind-patch --config cluster.yaml --kind-config FILE --authn-dir DIR
#              Add the issuer flags (and, with trust entries, --authentication-config plus its mount) to a kind config
#              before `kind create cluster`.
#   publish    --context CTX --issuer URL --out DIR
#              Write DIR/.well-known/openid-configuration and DIR/jwks.json for CTX's current signing key. Host DIR at
#              URL (public keys only). Safe before or after `issuer`: the key does not change with the issuer.
#   issuer     --context CTX --node-exec "CMD" --issuer URL [--dry-run]
#              Live cluster: make URL the first --service-account-issuer, keep every existing issuer as accepted, and
#              set --api-audiences to all of them. Backs up the manifest, waits, rolls back on failure, then checks.
#   trust      --context CTX --node-exec "CMD" --authn-config FILE [--dry-run]
#              Live cluster: install FILE as /etc/kubernetes/authn/config.yaml and point the API server at it.
#              Checks first that the node can fetch every trusted issuer's discovery document.
#   verify     --from-context CTX --namespace NS --service-account SA --audience AUD --to-context CTX2
#              Mint a 10-minute token on CTX and present it to CTX2 with no other credential: expect
#              hangar:<cluster>:<SA>. Then the refusals: wrong audience, a 20-minute token.
#
# --node-exec is the command prefix that runs one command inside the control-plane node, with stdin, e.g.
#   "container exec -i kiac-dev-control-plane"
#   "ssh laptop /opt/podman/bin/podman exec -i kind-prod-control-plane"
#   "docker exec -i kind-staging-control-plane"
# Only plain argv commands (cat, cp, mkdir, tee, curl) run in the node, so a remote shell in between is fine.
#
# Live edits change /etc/kubernetes/manifests/kube-apiserver.yaml; the kubelet restarts the API server (~30-90 s).
# The old manifest is kept as /etc/kubernetes/hangar-backup/kube-apiserver.yaml.<timestamp> (outside manifests/, where
# the kubelet would run it). The node's filesystem survives node restarts; a recreated cluster needs kind-patch (or
# its equivalent) instead.

set -euo pipefail

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "  \033[1;32mok\033[0m $*"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }
die()  { echo -e "\033[1;31merror: $*\033[0m" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

DEFAULT_ISSUER="https://kubernetes.default.svc.cluster.local"
MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUTHN_DIR="/etc/kubernetes/authn"
AUTHN_FILE="${AUTHN_DIR}/config.yaml"
BACKUP_DIR="/etc/kubernetes/hangar-backup"
WAIT_SECONDS="${WAIT_SECONDS:-240}"

CMD="${1:-}"; [ -n "${CMD}" ] || die "usage: $0 render|kind-patch|publish|issuer|trust|verify [flags] (see the header)"
shift

CONFIG=""; OUT=""; KIND_CONFIG=""; AUTHN_SRC_DIR=""; CONTEXT=""; ISSUER=""; NODE_EXEC=""; AUTHN_CONFIG=""
DRY_RUN=false; FROM_CONTEXT=""; TO_CONTEXT=""; NAMESPACE=""; SA=""; AUDIENCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --kind-config) KIND_CONFIG="$2"; shift 2 ;;
    --authn-dir) AUTHN_SRC_DIR="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --issuer) ISSUER="$2"; shift 2 ;;
    --node-exec) NODE_EXEC="$2"; shift 2 ;;
    --authn-config) AUTHN_CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --from-context) FROM_CONTEXT="$2"; shift 2 ;;
    --to-context) TO_CONTEXT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --service-account) SA="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    *) die "unknown flag $1" ;;
  esac
done

need() { [ -n "${!1}" ] || die "--$2 is required for $CMD"; }

python_yaml() {
  require python3
  python3 -c 'import yaml' 2>/dev/null || die "python3 with PyYAML is required (pip install pyyaml)."
}

TMP="$(mktemp -d)"
trap 'rm -r "${TMP}"' EXIT

# --- node helpers ---------------------------------------------------------------------------------------------------
# stdin is /dev/null except for node_write: ssh (and podman/docker exec -i) put the descriptors they inherit into
# non-blocking mode, and a terminal stdin left that way breaks the next `read` in a calling script (EAGAIN).
node_exec() { local -a pre; read -r -a pre <<<"${NODE_EXEC}"; "${pre[@]}" "$@"; }
node() { node_exec "$@" </dev/null; }
node_read() { node cat "$1"; }
node_write() { node_exec tee "$2" <"$1" >/dev/null; }   # node_write LOCALFILE NODEPATH

apiserver_ready() { kubectl --context "${CONTEXT}" get --raw /readyz >/dev/null 2>&1; }
apiserver_command() {
  kubectl --context "${CONTEXT}" -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null || true
}

# Wait until the API server answers /readyz and its mirror pod carries $1 (a flag string from the new manifest).
wait_for_apiserver() {
  local want="$1" deadline=$((SECONDS + WAIT_SECONDS))
  sleep 10
  while [ ${SECONDS} -lt ${deadline} ]; do
    if apiserver_ready && apiserver_command | grep -qF -- "${want}"; then return 0; fi
    sleep 5
  done
  return 1
}

# Install a new manifest, wait for it, and put the backup back if the API server does not come up with it.
apply_manifest() {
  local new="$1" want="$2" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  node mkdir -p "${BACKUP_DIR}"
  node cp "${MANIFEST}" "${BACKUP_DIR}/kube-apiserver.yaml.${stamp}"
  ok "backup: ${BACKUP_DIR}/kube-apiserver.yaml.${stamp}"
  node_write "${new}" "${MANIFEST}"
  echo "  manifest written; waiting up to ${WAIT_SECONDS}s for the API server to restart with it"
  if wait_for_apiserver "${want}"; then
    ok "API server is ready with ${want}"
    return 0
  fi
  warn "API server not ready with ${want} after ${WAIT_SECONDS}s - restoring the backup"
  node cp "${BACKUP_DIR}/kube-apiserver.yaml.${stamp}" "${MANIFEST}"
  WAIT_SECONDS=300 wait_for_apiserver "--secure-port" && echo "  restored; the API server is back on the old manifest" \
    || warn "the API server is not back yet either: check the node (crictl ps -a; the kubelet log)"
  die "change rolled back"
}

show_diff() { diff -u "$1" "$2" | sed -n '3,$p' || true; }

# --- render ---------------------------------------------------------------------------------------------------------
cmd_render() {
  need CONFIG config; need OUT out; python_yaml
  mkdir -p "${OUT}"
  python3 - "${CONFIG}" "${OUT}/authentication-config.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
ci = (cfg.get("components") or {}).get("clusterIdentity") or {}
trust = ci.get("trust") or []
if not trust:
    sys.exit("components.clusterIdentity.trust is empty: nothing to render")
own = ci.get("issuer")
jwt = []
for t in trust:
    for k in ("cluster", "issuer", "audience", "namespace", "serviceAccounts"):
        if not t.get(k):
            sys.exit(f"trust entry {t!r} is missing {k}")
    if not str(t["issuer"]).startswith("https://"):
        sys.exit(f"trusted issuer {t['issuer']} must be https")
    if t["issuer"] == own:
        sys.exit("a cluster cannot list its own issuer under trust")
    # CEL string literals in double quotes: the YAML then needs no doubled single quotes.
    sas = ", ".join(f'"{s}"' for s in t["serviceAccounts"])
    max_life = int(t.get("maxLifetimeSeconds", 600))
    ns, cl = t["namespace"], t["cluster"]
    jwt.append({
        "issuer": {"url": t["issuer"], "audiences": [t["audience"]]},
        "claimValidationRules": [
            {"expression": f'claims["kubernetes.io"].namespace == "{ns}"',
             "message": f"only {cl}'s {ns} namespace"},
            {"expression": f'claims["kubernetes.io"].serviceaccount.name in [{sas}]',
             "message": "only the listed ServiceAccounts"},
            {"expression": f"int(claims.exp) - int(claims.iat) <= {max_life}",
             "message": f"tokens longer than {max_life}s are refused"},
        ],
        "claimMappings": {
            "username": {"expression": f'"hangar:{cl}:" + claims["kubernetes.io"].serviceaccount.name'},
            "groups": {"expression": f'["hangar:{cl}"]'},
            "uid": {"expression": "claims.sub"},
            "extra": [{"key": "hangar.io/pod",
                       "valueExpression": 'has(claims["kubernetes.io"].pod) ? claims["kubernetes.io"].pod.name : ""'}],
        },
        "userValidationRules": [{"expression": '!user.username.startsWith("system:")', "message": "reserved prefix"}],
    })
doc = {"apiVersion": "apiserver.config.k8s.io/v1", "kind": "AuthenticationConfiguration", "jwt": jwt}
header = ("# Generated by apron hack/cluster-identity.sh render from components.clusterIdentity.trust.\n"
          "# Installed on the control-plane node as /etc/kubernetes/authn/config.yaml (hack/cluster-identity.sh trust,\n"
          "# or kind-patch at create time). The API server reloads it on change. Not an Argo CD manifest.\n")
open(sys.argv[2], "w").write(header + yaml.safe_dump(doc, sort_keys=False, width=120))
PY
  ok "wrote ${OUT}/authentication-config.yaml"
}

# --- kind-patch -----------------------------------------------------------------------------------------------------
cmd_kind_patch() {
  need CONFIG config; need KIND_CONFIG kind-config; require yq
  local issuer trust_count patch
  issuer="$(yq -r '.components.clusterIdentity.issuer' "${CONFIG}")"
  trust_count="$(yq -r '.components.clusterIdentity.trust // [] | length' "${CONFIG}")"
  case "${issuer}" in https://*) ;; *) die "components.clusterIdentity.issuer must be an https URL unique to this cluster" ;; esac
  [ "${issuer}" != "${DEFAULT_ISSUER}" ] || die "components.clusterIdentity.issuer must not be the default issuer"
  # kubeadm v1beta4 extraArgs is a list, so --service-account-issuer can appear twice (new first: it signs).
  patch="kind: ClusterConfiguration
apiServer:
  extraArgs:
    - name: service-account-issuer
      value: ${issuer}
    - name: service-account-issuer
      value: ${DEFAULT_ISSUER}
    - name: api-audiences
      value: ${issuer},${DEFAULT_ISSUER}"
  if [ "${trust_count}" -gt 0 ]; then
    [ -n "${AUTHN_SRC_DIR}" ] && [ -f "${AUTHN_SRC_DIR}/authentication-config.yaml" ] \
      || die "--authn-dir must hold authentication-config.yaml (render it first) when trust entries are set"
    patch="${patch}
    - name: authentication-config
      value: ${AUTHN_FILE}
  extraVolumes:
    - name: hangar-authn
      hostPath: ${AUTHN_DIR}
      mountPath: ${AUTHN_DIR}
      readOnly: true
      pathType: DirectoryOrCreate"
    # kind bind-mounts the rendered file into the node container as the file the API server reads (absolute path:
    # this kind config is a local bootstrap file, run from this checkout).
    MOUNT_SRC="$(cd "${AUTHN_SRC_DIR}" && pwd)/authentication-config.yaml" MOUNT_DST="${AUTHN_FILE}" yq -i \
      '(.nodes[] | select(.role == "control-plane") | .extraMounts) += [{"hostPath": strenv(MOUNT_SRC), "containerPath": strenv(MOUNT_DST), "readOnly": true}]' \
      "${KIND_CONFIG}"
  fi
  PATCH="${patch}" yq -i \
    '(.nodes[] | select(.role == "control-plane") | .kubeadmConfigPatches) += [strenv(PATCH) | . style="literal"]' \
    "${KIND_CONFIG}"
  ok "patched ${KIND_CONFIG}: issuer ${issuer}$( [ "${trust_count}" -gt 0 ] && echo ", ${trust_count} trusted issuer(s)" )"
}

# --- publish --------------------------------------------------------------------------------------------------------
cmd_publish() {
  need CONTEXT context; need ISSUER issuer; need OUT out; require kubectl; require jq
  case "${ISSUER}" in https://*) ;; *) die "--issuer must be https" ;; esac
  mkdir -p "${OUT}/.well-known"
  kubectl --context "${CONTEXT}" get --raw /openid/v1/jwks | jq . >"${OUT}/jwks.json"
  [ "$(jq '.keys | length' "${OUT}/jwks.json")" -gt 0 ] || die "${CONTEXT} returned no signing keys"
  jq -n --arg iss "${ISSUER}" '{
      issuer: $iss,
      jwks_uri: ($iss + "/jwks.json"),
      response_types_supported: ["id_token"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"]
    }' >"${OUT}/.well-known/openid-configuration"
  ok "wrote ${OUT}/.well-known/openid-configuration and ${OUT}/jwks.json ($(jq -r '[.keys[].kid] | join(", ")' "${OUT}/jwks.json"))"
  echo "  host ${OUT} at ${ISSUER} so that ${ISSUER}/.well-known/openid-configuration resolves"
}

# --- issuer ---------------------------------------------------------------------------------------------------------
cmd_issuer() {
  need CONTEXT context; need NODE_EXEC node-exec; need ISSUER issuer; require kubectl; require jq; python_yaml
  case "${ISSUER}" in https://*) ;; *) die "--issuer must be https" ;; esac
  [ "${ISSUER}" != "${DEFAULT_ISSUER}" ] || die "--issuer must not be the default issuer"
  log "issuer: ${CONTEXT} -> ${ISSUER}"
  node_read "${MANIFEST}" >"${TMP}/old.yaml"
  python3 - "${TMP}/old.yaml" "${TMP}/new.yaml" "${ISSUER}" "${DEFAULT_ISSUER}" <<'PY'
import sys, yaml
src, dst, issuer, default = sys.argv[1:5]
m = yaml.safe_load(open(src))
cmd = m["spec"]["containers"][0]["command"]
issuers = [a.split("=", 1)[1] for a in cmd if a.startswith("--service-account-issuer=")]
auds = [x for a in cmd if a.startswith("--api-audiences=") for x in a.split("=", 1)[1].split(",") if x]
at = next((i for i, a in enumerate(cmd) if a.startswith("--service-account-issuer=")), len(cmd))
keep = [a for a in cmd if not a.startswith(("--service-account-issuer=", "--api-audiences="))]
at = min(at, len(keep))
order = [issuer] + [x for x in issuers if x != issuer]
if default not in order:
    order.append(default)
# api-audiences: every issuer (in-cluster tokens carry the issuer that was first when they were minted) plus any
# audience already configured.
audiences = list(dict.fromkeys(order + auds))
new = [f"--service-account-issuer={x}" for x in order] + [f"--api-audiences={','.join(audiences)}"]
m["spec"]["containers"][0]["command"] = keep[:at] + new + keep[at:]
open(dst, "w").write(yaml.safe_dump(m, sort_keys=False))
PY
  show_diff <(grep -- '- --' "${TMP}/old.yaml" | sort) <(grep -- '- --' "${TMP}/new.yaml" | sort)
  if cmp -s <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "${TMP}/old.yaml") \
            <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "${TMP}/new.yaml"); then
    ok "already set; nothing to change"
  elif [ "${DRY_RUN}" = true ]; then
    ok "dry run: nothing written"; return 0
  else
    apply_manifest "${TMP}/new.yaml" "--service-account-issuer=${ISSUER}"
  fi

  log "checking ${CONTEXT}"
  local got
  got="$(kubectl --context "${CONTEXT}" get --raw /.well-known/openid-configuration | jq -r .issuer)"
  [ "${got}" = "${ISSUER}" ] || die "discovery reports issuer ${got}, expected ${ISSUER}"
  ok "discovery issuer is ${got}"
  local tok aud
  for aud in "${ISSUER}" "${DEFAULT_ISSUER}"; do
    tok="$(kubectl --context "${CONTEXT}" -n default create token default --audience "${aud}" --duration 10m)"
    jq -n --arg t "${tok}" --arg a "${aud}" '{apiVersion:"authentication.k8s.io/v1",kind:"TokenReview",spec:{token:$t,audiences:[$a]}}' \
      | kubectl --context "${CONTEXT}" create -f - -o json | jq -e '.status.authenticated == true' >/dev/null \
      || die "a fresh token for audience ${aud} does not authenticate on ${CONTEXT}"
    ok "a fresh token for audience ${aud} authenticates"
  done
  echo "  existing in-cluster tokens still validate: the old issuer stays accepted and is in --api-audiences."
  echo "  next: publish this cluster's keys at ${ISSUER} (publish), if not done yet."
}

# --- trust ----------------------------------------------------------------------------------------------------------
cmd_trust() {
  need CONTEXT context; need NODE_EXEC node-exec; need AUTHN_CONFIG authn-config; require kubectl; require jq; python_yaml
  [ -f "${AUTHN_CONFIG}" ] || die "${AUTHN_CONFIG} not found"
  log "trust: ${CONTEXT} <- ${AUTHN_CONFIG}"
  python3 - "${AUTHN_CONFIG}" >"${TMP}/issuers" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d.get("kind") == "AuthenticationConfiguration", "not an AuthenticationConfiguration"
for j in d.get("jwt") or []:
    print(j["issuer"]["url"])
PY
  local iss own
  own="$(kubectl --context "${CONTEXT}" get --raw /.well-known/openid-configuration | jq -r .issuer)"
  while read -r iss; do
    [ "${iss}" != "${own}" ] || die "${AUTHN_CONFIG} trusts ${iss}, which is ${CONTEXT}'s own --service-account-issuer: the API server refuses that. Give this cluster its own issuer first (issuer)."
    node curl -fsS --max-time 10 "${iss}/.well-known/openid-configuration" -o /dev/null \
      || die "the node cannot fetch ${iss}/.well-known/openid-configuration: publish it (or fix egress) first"
    ok "node can fetch ${iss}/.well-known/openid-configuration"
  done <"${TMP}/issuers"

  node_read "${MANIFEST}" >"${TMP}/old.yaml"
  python3 - "${TMP}/old.yaml" "${TMP}/new.yaml" "${AUTHN_FILE}" "${AUTHN_DIR}" <<'PY'
import sys, yaml
src, dst, file, d = sys.argv[1:5]
m = yaml.safe_load(open(src))
c = m["spec"]["containers"][0]
if any(a.startswith("--oidc-") for a in c["command"]):
    sys.exit("the API server has --oidc-* flags, which cannot be combined with --authentication-config: move them into the file first")
c["command"] = [a for a in c["command"] if not a.startswith("--authentication-config=")] + [f"--authentication-config={file}"]
mounts = c.setdefault("volumeMounts", [])
if not any(v.get("mountPath") == d for v in mounts):
    mounts.append({"name": "hangar-authn", "mountPath": d, "readOnly": True})
vols = m["spec"].setdefault("volumes", [])
if not any(v.get("name") == "hangar-authn" for v in vols):
    vols.append({"name": "hangar-authn", "hostPath": {"path": d, "type": "DirectoryOrCreate"}})
open(dst, "w").write(yaml.safe_dump(m, sort_keys=False))
PY
  show_diff "${TMP}/old.yaml" "${TMP}/new.yaml"
  if [ "${DRY_RUN}" = true ]; then ok "dry run: nothing written"; return 0; fi

  node mkdir -p "${AUTHN_DIR}"
  node_write "${AUTHN_CONFIG}" "${AUTHN_FILE}"
  ok "installed ${AUTHN_FILE} (the API server reloads it on change from now on)"
  if cmp -s <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "${TMP}/old.yaml") \
            <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "${TMP}/new.yaml"); then
    ok "manifest already points at it"
  else
    apply_manifest "${TMP}/new.yaml" "--authentication-config=${AUTHN_FILE}"
  fi
  echo "  next: verify with a real token from the trusted cluster (verify)."
}

# --- verify ---------------------------------------------------------------------------------------------------------
cmd_verify() {
  need FROM_CONTEXT from-context; need TO_CONTEXT to-context; need NAMESPACE namespace; need SA service-account
  need AUDIENCE audience; require kubectl; require jq
  log "verify: ${FROM_CONTEXT} ${NAMESPACE}/${SA} -> ${TO_CONTEXT} (audience ${AUDIENCE})"
  local server ca
  server="$(kubectl config view --minify --context "${TO_CONTEXT}" -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(kubectl config view --raw --minify --context "${TO_CONTEXT}" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  [ -n "${server}" ] && [ -n "${ca}" ] || die "cannot read ${TO_CONTEXT}'s server and CA from kubeconfig"
  # A kubeconfig with no credential but the token, so a client certificate cannot answer for it.
  whoami() {
    local kc="${TMP}/kubeconfig"
    cat >"${kc}" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: target, cluster: {server: "${server}", certificate-authority-data: "${ca}"}}]
users: [{name: token, user: {token: "$1"}}]
contexts: [{name: target, context: {cluster: target, user: token}}]
current-context: target
EOF
    KUBECONFIG="${kc}" kubectl auth whoami -o json 2>&1
  }
  local tok out
  tok="$(kubectl --context "${FROM_CONTEXT}" -n "${NAMESPACE}" create token "${SA}" --audience "${AUDIENCE}" --duration 10m)"
  out="$(whoami "${tok}")"
  echo "${out}" | jq -e --arg u "hangar:" '.status.userInfo.username | startswith($u)' >/dev/null \
    || die "a 10-minute ${SA} token was not accepted: ${out}"
  ok "accepted as $(echo "${out}" | jq -r '.status.userInfo.username') groups=$(echo "${out}" | jq -c '.status.userInfo.groups')"

  tok="$(kubectl --context "${FROM_CONTEXT}" -n "${NAMESPACE}" create token "${SA}" --audience "not-${AUDIENCE}" --duration 10m)"
  whoami "${tok}" | grep -q "Unauthorized\|must be logged in" && ok "wrong audience refused" || die "a wrong-audience token was accepted"
  tok="$(kubectl --context "${FROM_CONTEXT}" -n "${NAMESPACE}" create token "${SA}" --audience "${AUDIENCE}" --duration 20m)"
  whoami "${tok}" | grep -q "Unauthorized\|must be logged in" && ok "20-minute token refused" || die "a 20-minute token was accepted"
  echo "  RBAC for the accepted user is separate: until a binding names it, every request it makes is forbidden."
}

case "${CMD}" in
  render) cmd_render ;;
  kind-patch) cmd_kind_patch ;;
  publish) cmd_publish ;;
  issuer) cmd_issuer ;;
  trust) cmd_trust ;;
  verify) cmd_verify ;;
  *) die "unknown command ${CMD}" ;;
esac
