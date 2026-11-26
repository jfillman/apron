# tests/cases/49-control-plane-tuning.sh (see tests/run.sh)
# group: render
# secs: 12
# needs: lab
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
