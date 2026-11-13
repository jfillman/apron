#!/usr/bin/env bash
# hack/control-plane-tuning.sh
#
# Control-plane tuning for a single-node kiac/kind cluster whose API server and etcd are slow: stretch the leader-election
# timings of kube-controller-manager and kube-scheduler so one slow lease call stops being fatal. Both components exit
# when they cannot renew their lease within --leader-elect-renew-deadline (default 10 s); the kubelet restarts them; each
# restart re-lists everything from the API server, which is slower still (hangar-dev, 2026-11: 362 and 348 restarts).
# Everything here is static-pod flags on the node, so none of it can be an Argo CD Application (docs/control-plane-tuning.md).
#
#   render   [--cluster-dir DIR] [LEASE FLAGS]
#              Print the flags and the kubeadm ClusterConfiguration patch that gives a NEW cluster the same values.
#   plan     --cluster NAME [--node-exec "CMD"] [--cluster-dir DIR] [LEASE FLAGS]       (the default command)
#              READ-ONLY. Print the exact diff of /etc/kubernetes/manifests/kube-{scheduler,controller-manager}.yaml
#              (read with `cat` on the node) and refuse the same cases apply refuses. Writes nothing.
#   apply    --cluster NAME ... --yes
#              One component at a time (scheduler, then controller-manager): back up, edit in place, wait for the static
#              pod to be Ready with the new flags and its lease taken at the new duration, hold it for HOLD_MINUTES
#              (default 5) with no restart and no lost lease; on any failure restore that component's backup. Without
#              --yes it prints the plan and stops.
#   verify   --cluster NAME ...      Read-only: flags in the manifests, pods Ready, restart counts, lease durations and holders.
#   rollback --cluster NAME ... [--component scheduler|controller-manager] [--backup STAMP] --yes
#              Put the newest (or STAMP's) backup back, per component, and wait for the pod.
#
# LEASE FLAGS: --lease-duration 60s --renew-deadline 40s --retry-period 10s (Ns form; lease > renew > 1.2 x retry, the
# leader-election rule). Defaults are those values; with --cluster-dir they come from the cluster's resolved
# runtime.controlPlane.leaderElection (hack/render.py --print-values).
#
# --cluster NAME is the kubectl context. Identity check (as cluster-identity.sh does for its target): the context must
# exist, have exactly one control-plane node, and that node's own /etc/hostname (read through --node-exec) must equal the
# node's name, so a --node-exec aimed at another cluster's node is refused. --node-exec is the command prefix that runs one
# command in the node, with stdin; default "container exec -i <node>" (kiac). kind: "docker exec -i <node>" or
# "ssh HOST podman exec -i <node>". Only plain argv commands (cat, cp, mv, mkdir, chmod, tee, ls) run in the node.
#
# Safety: the old manifest is kept as /etc/kubernetes/hangar-backup/<component>.yaml.<UTC stamp> (outside manifests/,
# where the kubelet would run it); the new one is written beside it and moved into place (atomic, so the kubelet never
# reads a half-written file) with mode 0600. Never touches kube-apiserver.yaml or etcd.yaml. Idempotent: values already
# set the same are left alone; a flag set to a DIFFERENT value is refused (roll back first, or edit it by hand).
# The node's filesystem survives node restarts; a recreated cluster needs `render`'s patch instead.
#
# Environment: HOLD_MINUTES=5, WAIT_SECONDS=300 (pod Ready with the new flags), ACQUIRE_SECONDS=240 (new lease taken),
# POLL_SECONDS=15.

set -euo pipefail

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "  \033[1;32mok\033[0m $*"; }
warn() { echo -e "\033[1;33mwarning: $*\033[0m" >&2; }
die()  { echo -e "\033[1;31merror: $*\033[0m" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="/etc/kubernetes/manifests"
BACKUP_DIR="/etc/kubernetes/hangar-backup"
HOLD_MINUTES="${HOLD_MINUTES:-5}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
ACQUIRE_SECONDS="${ACQUIRE_SECONDS:-240}"
POLL_SECONDS="${POLL_SECONDS:-15}"
COMPONENTS="scheduler controller-manager"   # apply order: the scheduler is the less critical one

CMD="${1:-plan}"
case "${CMD}" in -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;; -*) CMD=plan ;; *) shift ;; esac

CLUSTER=""; NODE_EXEC=""; CLUSTER_DIR=""; LEASE=""; RENEW=""; RETRY=""; YES=false; ONLY=""; STAMP_WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --node-exec) NODE_EXEC="$2"; shift 2 ;;
    --cluster-dir) CLUSTER_DIR="$2"; shift 2 ;;
    --lease-duration) LEASE="$2"; shift 2 ;;
    --renew-deadline) RENEW="$2"; shift 2 ;;
    --retry-period) RETRY="$2"; shift 2 ;;
    --component) ONLY="$2"; shift 2 ;;
    --backup) STAMP_WANT="$2"; shift 2 ;;
    --yes) YES=true; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag $1" ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- values ---------------------------------------------------------------------------------------------------------
if [ -n "${CLUSTER_DIR}" ]; then
  require jq
  vals="$(python3 "${HERE}/render.py" --cluster "${CLUSTER_DIR%/}/cluster.yaml" --print-values)" \
    || die "render.py --print-values failed for ${CLUSTER_DIR}"
  le() { jq -r ".runtime.controlPlane.leaderElection.$1 // empty" <<<"${vals}"; }
  LEASE="${LEASE:-$(le leaseDuration)}"; RENEW="${RENEW:-$(le renewDeadline)}"; RETRY="${RETRY:-$(le retryPeriod)}"
fi
LEASE="${LEASE:-60s}"; RENEW="${RENEW:-40s}"; RETRY="${RETRY:-10s}"
secs() { [[ "$1" =~ ^[0-9]+s$ ]] || die "'$1' must be whole seconds like 60s"; echo "${1%s}"; }
LEASE_S="$(secs "${LEASE}")"; RENEW_S="$(secs "${RENEW}")"; RETRY_S="$(secs "${RETRY}")"
# client-go's rule: leaseDuration > renewDeadline > JitterFactor (1.2) x retryPeriod.
[ "${LEASE_S}" -gt "${RENEW_S}" ] || die "lease duration (${LEASE}) must be greater than the renew deadline (${RENEW})"
[ $((RENEW_S * 10)) -gt $((RETRY_S * 12)) ] || die "renew deadline (${RENEW}) must be greater than 1.2 x the retry period (${RETRY})"
FLAGS="--leader-elect-lease-duration=${LEASE} --leader-elect-renew-deadline=${RENEW} --leader-elect-retry-period=${RETRY}"

pod_base() { echo "kube-$1"; }   # scheduler -> kube-scheduler
valid_component() { case "$1" in scheduler|controller-manager) ;; *) die "--component must be scheduler or controller-manager" ;; esac; }
[ -z "${ONLY}" ] || valid_component "${ONLY}"
components() { if [ -n "${ONLY}" ]; then echo "${ONLY}"; else echo "${COMPONENTS}"; fi; }

# --- render ---------------------------------------------------------------------------------------------------------
cmd_render() {
  echo "# kube-controller-manager and kube-scheduler flags: ${FLAGS}"
  echo "# kubeadm ClusterConfiguration patch (templates/hack/kind-config.yaml renders the same):"
  cat <<PATCH
kind: ClusterConfiguration
controllerManager:
  extraArgs:
    - name: leader-elect-lease-duration
      value: "${LEASE}"
    - name: leader-elect-renew-deadline
      value: "${RENEW}"
    - name: leader-elect-retry-period
      value: "${RETRY}"
scheduler:
  extraArgs:
    - name: leader-elect-lease-duration
      value: "${LEASE}"
    - name: leader-elect-renew-deadline
      value: "${RENEW}"
    - name: leader-elect-retry-period
      value: "${RETRY}"
PATCH
}

# --- node helpers ---------------------------------------------------------------------------------------------------
# stdin is /dev/null except for node_write (ssh and container exec -i leave a terminal stdin non-blocking).
node_exec() { local -a pre; read -r -a pre <<<"${NODE_EXEC}"; "${pre[@]}" "$@"; }
node() { node_exec "$@" </dev/null; }
node_read() { node cat "$1"; }
node_write() { node_exec tee "$2" <"$1" >/dev/null; }   # node_write LOCALFILE NODEPATH
kc() { kubectl --context "${CLUSTER}" --request-timeout=20s "$@"; }

NODE=""
confirm_identity() {
  [ -n "${CLUSTER}" ] || die "--cluster NAME (the kubectl context) is required for ${CMD}"
  require kubectl; require jq; require python3
  python3 -c 'import yaml' 2>/dev/null || die "python3 with PyYAML is required (pip install pyyaml)."
  kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "${CLUSTER}" || die "no kubectl context named ${CLUSTER}"
  local nodes
  nodes="$(kc get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null)" || die "cannot list ${CLUSTER}'s control-plane nodes"
  [ "$(grep -c . <<<"${nodes}")" -eq 1 ] || die "${CLUSTER} has $(grep -c . <<<"${nodes}") control-plane nodes; this script handles exactly one"
  NODE="${nodes#node/}"
  [ -n "${NODE_EXEC}" ] || NODE_EXEC="container exec -i ${NODE}"
  local host
  host="$(node_read /etc/hostname | tr -d '[:space:]')" || die "cannot read /etc/hostname through --node-exec '${NODE_EXEC}'"
  [ "${host}" = "${NODE}" ] || die "identity mismatch: ${CLUSTER}'s control-plane node is ${NODE}, but --node-exec '${NODE_EXEC}' reaches ${host}"
  ok "${CLUSTER}: control-plane node ${NODE}, reached through '${NODE_EXEC}'"
}

# --- the edit -------------------------------------------------------------------------------------------------------
# edit_manifest OLD NEW: add the three flags to the container's command list, in place (lines inserted after the last
# command item; nothing else in the file is touched or re-formatted). Exit 0 = changed, 10 = already set, other = refused.
edit_manifest() {
  python3 - "$1" "$2" "${LEASE}" "${RENEW}" "${RETRY}" <<'PY'
import re, sys, yaml
src, dst, lease, renew, retry = sys.argv[1:6]
want = {"leader-elect-lease-duration": lease, "leader-elect-renew-deadline": renew, "leader-elect-retry-period": retry}
text = open(src).read()
doc = yaml.safe_load(text)
c = doc["spec"]["containers"][0]
cmd = c["command"]
def fail(msg): print("refused: " + msg, file=sys.stderr); sys.exit(2)
if "--leader-elect=false" in cmd:
    fail("leader election is disabled in this manifest (--leader-elect=false): the lease flags would do nothing")
missing = []
for name, value in want.items():
    have = [a for a in cmd if a == f"--{name}" or a.startswith(f"--{name}=")]
    if not have:
        missing.append(f"--{name}={value}")
    elif have != [f"--{name}={value}"]:
        fail(f"--{name} is already set to {have[0]!r}, not {value}: refusing to override it (roll back first, or edit by hand)")
if not missing:
    sys.exit(10)
lines = text.splitlines(keepends=True)
start = next((i for i, l in enumerate(lines) if re.match(r"^\s*- command:\s*$", l)), None)
if start is None:
    fail("the container's `- command:` block was not found in the expected block style")
first = start + 1
indent = re.match(r"^(\s*)- ", lines[first]).group(1)
last = first
while last + 1 < len(lines) and re.match(rf"^{indent}- ", lines[last + 1]):
    last += 1
if last - first + 1 != len(cmd):
    fail(f"found {last - first + 1} command lines but the manifest has {len(cmd)} arguments")
out = lines[: last + 1] + [f"{indent}- {m}\n" for m in missing] + lines[last + 1:]
open(dst, "w").write("".join(out))
# The edit must be exactly the added arguments and nothing else.
new = yaml.safe_load("".join(out))
want_doc = yaml.safe_load(text)
want_doc["spec"]["containers"][0]["command"] = cmd + missing
if new != want_doc:
    fail("internal check: the edited manifest differs from the original by more than the new flags")
PY
}

# prepare COMP: read the manifest, write TMP/COMP.old and TMP/COMP.new; sets STATE_<comp> to changed|same.
prepare() {
  local comp="$1" file rc=0
  file="${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
  node_read "${file}" >"${TMP}/${comp}.old" || die "cannot read ${file} on ${NODE}"
  [ -s "${TMP}/${comp}.old" ] || die "${file} on ${NODE} is empty"
  edit_manifest "${TMP}/${comp}.old" "${TMP}/${comp}.new" || rc=$?
  case "${rc}" in
    0) echo changed >"${TMP}/${comp}.state" ;;
    10) cp "${TMP}/${comp}.old" "${TMP}/${comp}.new"; echo same >"${TMP}/${comp}.state" ;;
    *) return 1 ;;
  esac
}
state() { cat "${TMP}/$1.state"; }

show_plan() {
  local comp file
  for comp in $(components); do
    file="${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
    echo
    if [ "$(state "${comp}")" = same ]; then
      ok "${comp}: ${FLAGS} already set in ${file}; nothing to change"
    else
      echo "--- ${comp}: ${NODE}:${file}"
      diff -u -L "${file} (current)" -L "${file} (planned)" "${TMP}/${comp}.old" "${TMP}/${comp}.new" || true
    fi
  done
}

cmd_plan() {
  log "plan: ${CLUSTER} leader election lease ${LEASE} / renew ${RENEW} / retry ${RETRY} (read-only)"
  confirm_identity
  local comp; for comp in $(components); do prepare "${comp}" || die "${comp}: refused (see above); nothing was changed"; done
  show_plan
  echo; ok "plan only: nothing written. To apply: $0 apply --cluster ${CLUSTER} --yes"
}

# --- waiting --------------------------------------------------------------------------------------------------------
pod_json() { kc -n kube-system get pod "$(pod_base "$1")-${NODE}" -o json 2>/dev/null; }
lease_json() { kc -n kube-system get lease "$(pod_base "$1")" -o json 2>/dev/null; }

# Ready, has the flags, and its container started after $2 (a UTC timestamp).
pod_up_with_flags() {
  local comp="$1" since="$2"
  pod_json "${comp}" | jq -e --arg f "--leader-elect-lease-duration=${LEASE}" --arg s "${since}" '
    (.spec.containers[0].command | index($f)) != null
    and ((.status.conditions // []) | any(.type == "Ready" and .status == "True"))
    and ((.status.containerStatuses[0].state.running.startedAt // "") > $s)' >/dev/null 2>&1
}
restarts() { pod_json "$1" | jq -r '.status.containerStatuses[0].restartCount // empty' 2>/dev/null; }

# Lease facts as "duration holder transitions age_seconds".
lease_facts() {
  lease_json "$1" | jq -r '[.spec.leaseDurationSeconds, (.spec.holderIdentity // "-"), (.spec.leaseTransitions // 0),
    (now - ((.spec.renewTime // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | floor)] | @tsv' 2>/dev/null
}

# After a restart: wait for the new instance to take the lease at the new duration, then hold it.
wait_and_hold() {
  local comp="$1" since="$2" deadline facts dur holder trans age base_restarts base_trans base_holder fails=0 t_end
  deadline=$((SECONDS + WAIT_SECONDS))
  while ! pod_up_with_flags "${comp}" "${since}"; do
    [ ${SECONDS} -lt ${deadline} ] || { warn "${comp}: pod not Ready with the new flags after ${WAIT_SECONDS}s"; return 1; }
    sleep "${POLL_SECONDS}"
  done
  ok "${comp}: pod Ready with the new flags"
  base_restarts="$(restarts "${comp}")"
  deadline=$((SECONDS + ACQUIRE_SECONDS))
  while :; do
    facts="$(lease_facts "${comp}")" || facts=""
    if [ -n "${facts}" ]; then
      read -r dur holder trans age <<<"${facts}"
      if [ "${dur}" = "${LEASE_S}" ] && [[ "${holder}" == "${NODE}_"* ]] && [ "${age}" -lt "${LEASE_S}" ]; then break; fi
    fi
    [ ${SECONDS} -lt ${deadline} ] || { warn "${comp}: lease not taken at ${LEASE_S}s within ${ACQUIRE_SECONDS}s (last: ${facts:-unreadable})"; return 1; }
    sleep "${POLL_SECONDS}"
  done
  base_trans="${trans}"; base_holder="${holder}"
  ok "${comp}: lease held by ${holder} at ${dur}s (transitions ${trans})"
  echo "  holding for ${HOLD_MINUTES} min: no restart, no lost lease"
  t_end=$((SECONDS + HOLD_MINUTES * 60))
  while [ ${SECONDS} -lt ${t_end} ]; do
    sleep "${POLL_SECONDS}"
    facts="$(lease_facts "${comp}")" || facts=""
    if [ -z "${facts}" ] || [ "$(restarts "${comp}")" = "" ]; then
      fails=$((fails + 1))
      [ ${fails} -lt 3 ] || { warn "${comp}: API unreadable 3 times in a row during the hold"; return 1; }
      continue
    fi
    fails=0
    read -r dur holder trans age <<<"${facts}"
    [ "$(restarts "${comp}")" = "${base_restarts}" ] || { warn "${comp}: restarted during the hold (restartCount ${base_restarts} -> $(restarts "${comp}"))"; return 1; }
    [ "${holder}" = "${base_holder}" ] && [ "${trans}" = "${base_trans}" ] || { warn "${comp}: lease lost during the hold (holder ${holder}, transitions ${trans})"; return 1; }
    [ "${age}" -lt "${LEASE_S}" ] || { warn "${comp}: lease not renewed for ${age}s (lease is ${LEASE_S}s)"; return 1; }
  done
  ok "${comp}: held the lease for ${HOLD_MINUTES} min, restartCount ${base_restarts}"
}

# --- apply / rollback -----------------------------------------------------------------------------------------------
# Install LOCALFILE as the component's manifest: write beside the backups, then mv (atomic) into manifests/, mode 0600.
install_manifest() {
  local comp="$1" local_file="$2" file tmpn
  file="${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
  tmpn="${BACKUP_DIR}/.$(pod_base "${comp}").yaml.incoming"
  node_write "${local_file}" "${tmpn}"
  node chmod 600 "${tmpn}"
  node_read "${tmpn}" | cmp -s - "${local_file}" || { node rm -f "${tmpn}" 2>/dev/null || true; die "the copy staged on the node differs from the local file; nothing installed"; }
  node mv "${tmpn}" "${file}"
}

restore() {   # restore COMP BACKUPPATH
  local comp="$1" backup="$2"
  node_read "${backup}" >"${TMP}/${comp}.restore"
  [ -s "${TMP}/${comp}.restore" ] || die "backup ${backup} is empty or unreadable; restore it by hand: cp ${backup} ${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
  install_manifest "${comp}" "${TMP}/${comp}.restore"
}

wait_old_pod() {   # best effort after a restore: pod Ready again
  local comp="$1" deadline=$((SECONDS + WAIT_SECONDS))
  sleep "${POLL_SECONDS}"
  while [ ${SECONDS} -lt ${deadline} ]; do
    pod_json "${comp}" | jq -e '(.status.conditions // []) | any(.type == "Ready" and .status == "True")' >/dev/null 2>&1 && return 0
    sleep "${POLL_SECONDS}"
  done
  return 1
}

apply_one() {
  local comp="$1" stamp since backup file
  file="${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; backup="${BACKUP_DIR}/$(pod_base "${comp}").yaml.${stamp}"
  log "${comp}: ${file}"
  node mkdir -p "${BACKUP_DIR}"
  node cp -p "${file}" "${backup}"
  node_read "${backup}" | cmp -s - "${TMP}/${comp}.old" || die "backup ${backup} does not match the manifest just read; nothing changed"
  ok "backup: ${backup}"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  install_manifest "${comp}" "${TMP}/${comp}.new"
  echo "  manifest installed; the kubelet restarts the static pod (up to ${WAIT_SECONDS}s wait, then ${ACQUIRE_SECONDS}s for the lease)"
  if wait_and_hold "${comp}" "${since}"; then return 0; fi
  warn "${comp}: restoring ${backup}"
  restore "${comp}" "${backup}"
  wait_old_pod "${comp}" && echo "  restored; ${comp} is Ready on the old manifest" \
    || warn "${comp} is not Ready yet on the old manifest either: check the node (crictl ps -a; the kubelet log)"
  die "${comp}: change rolled back"
}

cmd_apply() {
  log "apply: ${CLUSTER} leader election lease ${LEASE} / renew ${RENEW} / retry ${RETRY}"
  confirm_identity
  local comp pending=false
  for comp in $(components); do
    prepare "${comp}" || die "${comp}: refused (see above); nothing was changed on any component"
    if [ "$(state "${comp}")" = changed ]; then pending=true; fi
  done
  show_plan
  if [ "${pending}" = false ]; then echo; ok "already set everywhere; nothing to do"; return 0; fi
  [ "${YES}" = true ] || { echo; ok "plan only: re-run with --yes to apply"; return 0; }
  for comp in $(components); do
    [ "$(state "${comp}")" = changed ] || continue
    apply_one "${comp}"
  done
  echo; ok "applied. Re-check any time: $0 verify --cluster ${CLUSTER}"
}

cmd_rollback() {
  log "rollback: ${CLUSTER}"
  confirm_identity
  local comp backup list now
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  for comp in $(components); do
    list="$(node ls -1 "${BACKUP_DIR}" | grep -E "^$(pod_base "${comp}")\.yaml\.[0-9]{8}T[0-9]{6}Z\$" | sort || true)"
    [ -n "${list}" ] || die "no backups of $(pod_base "${comp}").yaml in ${BACKUP_DIR}"
    if [ -n "${STAMP_WANT}" ]; then
      backup="$(grep -F -- ".${STAMP_WANT}" <<<"${list}" | tail -n1 || true)"
      [ -n "${backup}" ] || die "no backup ${STAMP_WANT} of ${comp}; have: $(tr '\n' ' ' <<<"${list}")"
    else
      backup="$(tail -n1 <<<"${list}")"
    fi
    backup="${BACKUP_DIR}/${backup}"
    node_read "${backup}" >"${TMP}/${comp}.restore"
    echo "--- ${comp}: ${backup} -> ${MANIFEST_DIR}/$(pod_base "${comp}").yaml"
    node_read "${MANIFEST_DIR}/$(pod_base "${comp}").yaml" >"${TMP}/${comp}.cur"
    diff -u -L "current" -L "${backup##*/}" "${TMP}/${comp}.cur" "${TMP}/${comp}.restore" || true
    [ "${YES}" = true ] || continue
    node cp -p "${MANIFEST_DIR}/$(pod_base "${comp}").yaml" "${BACKUP_DIR}/$(pod_base "${comp}").yaml.pre-rollback-${now}"
    restore "${comp}" "${backup}"
    wait_old_pod "${comp}" && ok "${comp}: restored and Ready" || warn "${comp} is not Ready yet: check the node (crictl ps -a; the kubelet log)"
  done
  [ "${YES}" = true ] || { echo; ok "plan only: re-run with --yes to restore"; }
}

# --- verify ---------------------------------------------------------------------------------------------------------
cmd_verify() {
  log "verify: ${CLUSTER}"
  confirm_identity
  local comp bad=0 facts dur holder trans age rs
  for comp in $(components); do
    prepare "${comp}" || { warn "${comp}: manifest has the flags set to other values or cannot be edited"; bad=1; continue; }
    if [ "$(state "${comp}")" = same ]; then ok "${comp}: manifest has ${FLAGS}"; else warn "${comp}: manifest does not have ${FLAGS}"; bad=1; continue; fi
    if pod_json "${comp}" | jq -e '(.status.conditions // []) | any(.type == "Ready" and .status == "True")' >/dev/null 2>&1; then
      rs="$(restarts "${comp}")"; ok "${comp}: pod Ready, restartCount ${rs}"
    else warn "${comp}: pod not Ready"; bad=1; continue; fi
    facts="$(lease_facts "${comp}")" || facts=""
    [ -n "${facts}" ] || { warn "${comp}: lease unreadable"; bad=1; continue; }
    read -r dur holder trans age <<<"${facts}"
    if [ "${dur}" = "${LEASE_S}" ] && [[ "${holder}" == "${NODE}_"* ]] && [ "${age}" -lt "${LEASE_S}" ]; then
      ok "${comp}: lease ${dur}s held by ${holder}, renewed ${age}s ago, transitions ${trans}"
    else warn "${comp}: lease is ${dur}s held by ${holder}, renewed ${age}s ago (want ${LEASE_S}s on ${NODE}, fresh)"; bad=1; fi
  done
  echo "  restartCount only ever grows: compare it to an earlier reading over hours to see the crash-loop has stopped."
  [ "${bad}" -eq 0 ] || die "verify found problems"
}

case "${CMD}" in
  render) cmd_render ;;
  plan) cmd_plan ;;
  apply) cmd_apply ;;
  rollback) cmd_rollback ;;
  verify) cmd_verify ;;
  *) die "usage: $0 render|plan|apply|verify|rollback [flags] (see the header)" ;;
esac
