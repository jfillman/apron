#!/usr/bin/env bash
# hack/observe-audit.sh
#
# Turn on the kube-apiserver audit webhook that feeds Clearance's Kubernetes audit collector (clearance
# docs/observe-k8s-runbook.md explains the what and why). API-server flags and node files, so none of it can be an
# Argo CD Application; this is the same shape as hack/cluster-identity.sh.
#
#   prepare  --dir DIR --service-ip IP --namespaces a,b --clearance-src REPO --clearance-ref TAG
#            On this machine only: make the two CAs and two certificates in DIR (keys 0600, never printed), render the
#            audit policy from the Clearance source at TAG, hold it to `policy check`, write webhook.kubeconfig.
#   secret   --context CTX --dir DIR
#            Create or replace the collector's TLS Secret. Restart the collector afterwards if it was already running.
#   install  --context CTX --node-exec "CMD" --dir DIR [--max-load N] [--dry-run]
#            Live cluster: check the node is CTX's, the collector is up and reachable from the node with the real
#            client certificate, then install the files and flags. Backs up the manifest, waits, rolls back on failure.
#   verify   --context CTX
#            API server ready, flags live, no batch refused. It cannot see delivery: the collector logs no line per
#            batch. Delivery is the k8s-audit-webhook source in the core's GET /v1/coverage.
#   rollback --context CTX --node-exec "CMD"
#            Take the audit flags and mount back out of the manifest. The files stay on the node.
#
# --node-exec is the command prefix that runs one command inside the control-plane node, with stdin, e.g.
#   "container exec -i <name>-control-plane"                          (kiac)
#   "ssh <host> /opt/podman/bin/podman exec -i <name>-control-plane"  (kind on another machine)
#   "docker exec -i <name>-control-plane"                             (kind)
#
# The node's filesystem survives node restarts. A recreated cluster loses this: run install again.

set -euo pipefail

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "  \033[1;32mok\033[0m $*"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }
die()  { echo -e "\033[1;31merror: $*\033[0m" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

NS="clearance-system"
SERVICE="clearance-observe-k8s"
TLS_SECRET="clearance-observe-k8s-tls"
PORT="8443"
MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
AUDIT_DIR="/etc/kubernetes/audit"
BACKUP_DIR="/etc/kubernetes/hangar-backup"
VOLUME="hangar-audit"
WANT_FLAG="--audit-webhook-config-file=${AUDIT_DIR}/webhook.kubeconfig"
WAIT_SECONDS="${WAIT_SECONDS:-240}"
LEAF_DAYS="365"
CA_DAYS="825"

CMD="${1:-}"; [ -n "${CMD}" ] || die "usage: $0 prepare|secret|install|verify|rollback [flags] (see the header)"
shift

DIR=""; SERVICE_IP=""; NAMESPACES=""; SRC=""; REF=""; CONTEXT=""; NODE_EXEC=""; MAX_LOAD=""; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --service-ip) SERVICE_IP="$2"; shift 2 ;;
    --namespaces) NAMESPACES="$2"; shift 2 ;;
    --clearance-src) SRC="$2"; shift 2 ;;
    --clearance-ref) REF="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --node-exec) NODE_EXEC="$2"; shift 2 ;;
    --max-load) MAX_LOAD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
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

kc() { kubectl --context "${CONTEXT}" "$@"; }

# --- node helpers (see hack/cluster-identity.sh for why stdin is /dev/null) -------------------------------------------
node_exec() { local -a pre; read -r -a pre <<<"${NODE_EXEC}"; "${pre[@]}" "$@"; }
node() { node_exec "$@" </dev/null; }
node_write() { node_exec tee "$2" <"$1" >/dev/null; }   # node_write LOCALFILE NODEPATH

# The key's mode is set before any of its bytes arrive.
node_write_private() { node touch "$2"; node chmod 600 "$2"; node_write "$1" "$2"; }

apiserver_ready() { kc get --raw /readyz >/dev/null 2>&1; }
apiserver_command() {
  kc -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null || true
}

wait_for_flag() {   # wait_for_flag present|absent
  local mode="$1" deadline=$((SECONDS + WAIT_SECONDS)) cmdline
  sleep 10
  while [ ${SECONDS} -lt ${deadline} ]; do
    if apiserver_ready; then
      cmdline="$(apiserver_command)"
      if [ -n "${cmdline}" ]; then
        if [ "${mode}" = present ] && grep -qF -- "${WANT_FLAG}" <<<"${cmdline}"; then return 0; fi
        if [ "${mode}" = absent ] && ! grep -qF -- "${WANT_FLAG}" <<<"${cmdline}"; then return 0; fi
      fi
    fi
    sleep 5
  done
  return 1
}

# Replace the manifest in one rename, so the kubelet can never read half of it.
swap_manifest() {
  local src="$1" staged="${BACKUP_DIR}/kube-apiserver.yaml.staged"
  node_write "${src}" "${staged}"
  node mv "${staged}" "${MANIFEST}"
}

apply_manifest() {
  local new="$1" stamp backup
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${BACKUP_DIR}/kube-apiserver.yaml.${stamp}"
  node mkdir -p "${BACKUP_DIR}"
  node cp "${MANIFEST}" "${backup}"
  ok "backup: ${backup}"
  swap_manifest "${new}"
  echo "  manifest written; waiting up to ${WAIT_SECONDS}s for the API server to restart with the audit flags"
  if wait_for_flag present; then
    ok "API server is ready with the audit flags"
    return 0
  fi
  warn "API server not ready with the audit flags after ${WAIT_SECONDS}s - restoring the backup"
  node cp "${backup}" "${BACKUP_DIR}/kube-apiserver.yaml.staged"
  node mv "${BACKUP_DIR}/kube-apiserver.yaml.staged" "${MANIFEST}"
  WAIT_SECONDS=300 wait_for_flag absent && echo "  restored; the API server is back on the old manifest" \
    || warn "the API server is not back yet either: check the node (crictl ps -a; the kubelet log)"
  die "change rolled back"
}

same_yaml() {
  cmp -s <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "$1") \
         <(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1])))' "$2")
}

show_diff() { diff -u "$1" "$2" | sed -n '3,$p' || true; }

# Exits non-zero unless the kubectl context and the node reached by --node-exec are the same machine.
check_same_cluster() {
  local want got
  want="$(kc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  [ -n "${want}" ] || die "${CONTEXT} reports no control-plane node address"
  got="$(node cat "${MANIFEST}" | sed -n 's/.*--advertise-address=//p' | head -1)"
  [ "${got}" = "${want}" ] || die "--node-exec reaches a node advertising '${got}', but ${CONTEXT}'s control plane is ${want}: wrong node?"
  ok "--node-exec reaches ${CONTEXT}'s control plane (${want})"
}

check_load() {
  [ -n "${MAX_LOAD}" ] || return 0
  local load
  load="$(node cat /proc/loadavg | cut -d' ' -f1)"
  awk -v l="${load}" -v m="${MAX_LOAD}" 'BEGIN{exit !(l<m)}' \
    || die "node load is ${load} (limit ${MAX_LOAD}): an API server restart now could spiral. Try again when it settles."
  ok "node load ${load} is under ${MAX_LOAD}"
}

# --- prepare --------------------------------------------------------------------------------------------------------
cmd_prepare() {
  need DIR dir; need SERVICE_IP service-ip; need NAMESPACES namespaces; need SRC clearance-src; need REF clearance-ref
  require openssl; require go; require git; require tar
  [ ! -e "${DIR}/collector.key" ] || die "${DIR} already holds keys. Use a new --dir to rotate; nothing was changed."
  ( umask 077; mkdir -p "${DIR}" )
  chmod 700 "${DIR}"
  DIR="$(cd "${DIR}" && pwd)"
  log "prepare: ${DIR} (service IP ${SERVICE_IP})"

  ( umask 077; cd "${DIR}"
    cat >openssl.cnf <<EOF
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
[client]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = IP:${SERVICE_IP},DNS:${SERVICE}.${NS}.svc
EOF
    mkca() {  # mkca NAME COMMON_NAME
      openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
      openssl req -x509 -new -sha256 -key "$1.key" -days "${CA_DAYS}" -subj "/CN=$2" -config openssl.cnf -extensions ca -out "$1.crt"
    }
    mkleaf() {  # mkleaf NAME COMMON_NAME CA SECTION
      openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
      openssl req -new -sha256 -key "$1.key" -subj "/CN=$2" -config openssl.cnf -out "$1.csr"
      openssl x509 -req -sha256 -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAserial "$3.srl" -CAcreateserial -days "${LEAF_DAYS}" \
        -extfile openssl.cnf -extensions "$4" -out "$1.crt" 2>/dev/null
      rm "$1.csr"
    }
    # Two CAs: one is what the collector trusts for clients, the other what the API server trusts for the collector.
    mkca audit-client-ca observe-audit-client-ca
    mkca collector-server-ca observe-collector-server-ca
    mkleaf apiserver-audit-client kube-apiserver audit-client-ca client
    mkleaf collector "${SERVICE}" collector-server-ca server
    openssl verify -CAfile audit-client-ca.crt apiserver-audit-client.crt >/dev/null
    openssl verify -CAfile collector-server-ca.crt collector.crt >/dev/null
    chmod 600 ./*.key
    printf '%s\n' "${SERVICE_IP}" >service-ip
  )
  ok "certificates written; keys are 0600 in ${DIR}"

  git -C "${SRC}" rev-parse -q --verify "${REF}^{commit}" >/dev/null || die "${SRC} has no ref ${REF} (git fetch --tags?)"
  mkdir "${TMP}/src"
  git -C "${SRC}" archive "${REF}" | tar -x -C "${TMP}/src"
  ( cd "${TMP}/src"
    go run ./providers/observe-k8s/cmd/observe-k8s policy render --namespaces "${NAMESPACES}" >"${DIR}/audit-policy.yaml"
    go run ./providers/observe-k8s/cmd/observe-k8s policy check "${DIR}/audit-policy.yaml" >"${TMP}/check" )
  grep -q "never records a Secret body" "${TMP}/check" || die "policy check did not pass: $(cat "${TMP}/check")"
  ok "audit policy rendered from ${REF} for ${NAMESPACES}: $(cat "${TMP}/check")"

  cat >"${DIR}/webhook.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: observe-k8s
    cluster:
      certificate-authority: ${AUDIT_DIR}/collector-server-ca.crt
      server: https://${SERVICE_IP}:${PORT}/audit
users:
  - name: kube-apiserver
    user:
      client-certificate: ${AUDIT_DIR}/apiserver-audit-client.crt
      client-key: ${AUDIT_DIR}/apiserver-audit-client.key
contexts:
  - name: default
    context: {cluster: observe-k8s, user: kube-apiserver}
current-context: default
EOF
  ok "webhook.kubeconfig points at https://${SERVICE_IP}:${PORT}/audit"
}

# --- secret ---------------------------------------------------------------------------------------------------------
cmd_secret() {
  need CONTEXT context; need DIR dir; require kubectl
  for f in collector.crt collector.key audit-client-ca.crt; do [ -s "${DIR}/${f}" ] || die "${DIR}/${f} is missing: run prepare"; done
  kc create namespace "${NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  # Server-side apply, so the key is not copied into a last-applied annotation.
  kc -n "${NS}" create secret generic "${TLS_SECRET}" \
    --from-file=tls.crt="${DIR}/collector.crt" --from-file=tls.key="${DIR}/collector.key" \
    --from-file=ca.crt="${DIR}/audit-client-ca.crt" --dry-run=client -o json \
    | kc apply --server-side --field-manager=observe-audit -f - >/dev/null
  ok "${NS}/${TLS_SECRET} is set on ${CONTEXT}"
}

# --- install --------------------------------------------------------------------------------------------------------
cmd_install() {
  need CONTEXT context; need NODE_EXEC node-exec; need DIR dir; require kubectl; require openssl; python_yaml
  local f ip svc_ip ready code
  for f in audit-policy.yaml webhook.kubeconfig collector-server-ca.crt apiserver-audit-client.crt apiserver-audit-client.key service-ip; do
    [ -s "${DIR}/${f}" ] || die "${DIR}/${f} is missing: run prepare"
  done
  ip="$(cat "${DIR}/service-ip")"
  log "install: ${CONTEXT}"

  check_same_cluster
  apiserver_ready || die "${CONTEXT} is not ready before the change; fix that first"
  check_load
  openssl x509 -checkend 2592000 -noout -in "${DIR}/apiserver-audit-client.crt" >/dev/null \
    || die "the API server's client certificate expires within 30 days: prepare a new --dir"

  svc_ip="$(kc -n "${NS}" get svc "${SERVICE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [ -n "${svc_ip}" ] || die "no Service ${NS}/${SERVICE} on ${CONTEXT}: deploy the collector first (webhook.service.clusterIP=${ip})"
  [ "${svc_ip}" = "${ip}" ] || die "Service ${NS}/${SERVICE} has ClusterIP ${svc_ip}, the certificate was made for ${ip}"
  ready="$(kc -n "${NS}" get deploy "${SERVICE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [ "${ready:-0}" -ge 1 ] || die "the collector on ${CONTEXT} has no ready replica"
  ok "collector is ready at ${svc_ip}"

  node cat "${MANIFEST}" >"${TMP}/old.yaml"
  python3 - "${TMP}/old.yaml" "${TMP}/new.yaml" "${AUDIT_DIR}" "${VOLUME}" <<'PY'
import sys, yaml
src, dst, d, vol = sys.argv[1:5]
m = yaml.safe_load(open(src))
c = m["spec"]["containers"][0]
flags = [
    f"--audit-policy-file={d}/audit-policy.yaml",
    f"--audit-webhook-config-file={d}/webhook.kubeconfig",
    "--audit-webhook-mode=batch",
    "--audit-webhook-version=audit.k8s.io/v1",
    "--audit-webhook-batch-max-wait=5s",
    "--audit-webhook-batch-max-size=100",
    "--audit-webhook-batch-buffer-size=50000",
    "--audit-webhook-initial-backoff=5s",
    "--audit-webhook-truncate-enabled=true",
]
keep = [a for a in c["command"] if not a.startswith(("--audit-policy-file=", "--audit-webhook-"))]
c["command"] = keep + flags
mounts = c.setdefault("volumeMounts", [])
if not any(v.get("name") == vol for v in mounts):
    mounts.append({"name": vol, "mountPath": d, "readOnly": True})
vols = m["spec"].setdefault("volumes", [])
if not any(v.get("name") == vol for v in vols):
    vols.append({"name": vol, "hostPath": {"path": d, "type": "DirectoryOrCreate"}})
open(dst, "w").write(yaml.safe_dump(m, sort_keys=False))
PY
  show_diff <(python3 -c 'import sys,yaml;print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))))' "${TMP}/old.yaml") \
            <(python3 -c 'import sys,yaml;print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))))' "${TMP}/new.yaml")
  if [ "${DRY_RUN}" = true ]; then ok "dry run: nothing written"; return 0; fi

  node mkdir -p "${AUDIT_DIR}"
  node chmod 700 "${AUDIT_DIR}"
  for f in audit-policy.yaml webhook.kubeconfig collector-server-ca.crt apiserver-audit-client.crt; do
    node_write "${DIR}/${f}" "${AUDIT_DIR}/${f}"
  done
  node_write_private "${DIR}/apiserver-audit-client.key" "${AUDIT_DIR}/apiserver-audit-client.key"
  ok "files installed in ${AUDIT_DIR}"

  # The real path with the real identity, before the API server depends on it: 405 means the node reached the
  # collector over the ClusterIP, the server certificate verified, and the client certificate was accepted.
  code="$(node curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    --cacert "${AUDIT_DIR}/collector-server-ca.crt" \
    --cert "${AUDIT_DIR}/apiserver-audit-client.crt" --key "${AUDIT_DIR}/apiserver-audit-client.key" \
    "https://${ip}:${PORT}/audit" || true)"
  [ "${code}" = "405" ] || die "the node could not complete mTLS to the collector (HTTP '${code}', want 405); the manifest is unchanged. Check NetworkPolicy and the Secret."
  ok "node -> collector mTLS works (HTTP 405 to GET, as expected)"

  # Before the flags, so that creating the mirror is not itself reported as an operation on monitoring.
  kc -n kube-system create configmap audit-policy --from-file=audit-policy.yaml="${DIR}/audit-policy.yaml" --dry-run=client -o yaml \
    | kc apply --server-side --field-manager=observe-audit -f - >/dev/null
  ok "kube-system/audit-policy mirrors the policy"

  if same_yaml "${TMP}/old.yaml" "${TMP}/new.yaml"; then
    ok "manifest already carries the flags"
  else
    apply_manifest "${TMP}/new.yaml"
  fi
  echo "  next: verify"
}

# --- verify ---------------------------------------------------------------------------------------------------------
cmd_verify() {
  need CONTEXT context; require kubectl
  log "verify: ${CONTEXT}"
  apiserver_ready || die "/readyz is not ok"
  ok "/readyz ok"
  grep -qF -- "${WANT_FLAG}" <<<"$(apiserver_command)" || die "the API server is not running with the audit flags"
  ok "audit flags are live"
  kc -n "${NS}" logs "deploy/${SERVICE}" --since=10m >"${TMP}/log" || die "cannot read the collector's log"
  [ -s "${TMP}/log" ] || die "the collector logged nothing in 10 minutes"
  local refused
  refused="$(grep -c "audit batch refused" "${TMP}/log" || true)"
  [ "${refused}" = "0" ] || die "${refused} audit batches refused in the last 10 minutes; read the collector log (401: no certificate, 403: wrong name)"
  ok "no audit batch refused in the last 10 minutes"
  echo "  this does not prove delivery. Check GET /v1/coverage?scope=<cluster> on the core: source k8s-audit-webhook, now: healthy."
}

# --- rollback -------------------------------------------------------------------------------------------------------
cmd_rollback() {
  need CONTEXT context; need NODE_EXEC node-exec; require kubectl; python_yaml
  log "rollback: ${CONTEXT}"
  check_same_cluster
  node cat "${MANIFEST}" >"${TMP}/old.yaml"
  python3 - "${TMP}/old.yaml" "${TMP}/new.yaml" "${VOLUME}" <<'PY'
import sys, yaml
src, dst, vol = sys.argv[1:4]
m = yaml.safe_load(open(src))
c = m["spec"]["containers"][0]
c["command"] = [a for a in c["command"] if not a.startswith(("--audit-policy-file=", "--audit-webhook-"))]
c["volumeMounts"] = [v for v in c.get("volumeMounts", []) if v.get("name") != vol]
m["spec"]["volumes"] = [v for v in m["spec"].get("volumes", []) if v.get("name") != vol]
open(dst, "w").write(yaml.safe_dump(m, sort_keys=False))
PY
  if same_yaml "${TMP}/old.yaml" "${TMP}/new.yaml"; then ok "no audit flags in the manifest; nothing to do"; return 0; fi
  node mkdir -p "${BACKUP_DIR}"
  node cp "${MANIFEST}" "${BACKUP_DIR}/kube-apiserver.yaml.$(date -u +%Y%m%dT%H%M%SZ)"
  swap_manifest "${TMP}/new.yaml"
  wait_for_flag absent || die "the API server did not come back without the flags: check the node (crictl ps -a; the kubelet log)"
  ok "audit flags removed; the collector now reports blind, which is the truth"
}

case "${CMD}" in
  prepare) cmd_prepare ;;
  secret) cmd_secret ;;
  install) cmd_install ;;
  verify) cmd_verify ;;
  rollback) cmd_rollback ;;
  *) die "unknown command ${CMD}" ;;
esac
