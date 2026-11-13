# Control-plane tuning

A single-node kiac or kind cluster runs etcd, the API server, the controller manager and the scheduler on one node.
When etcd or the API server is slow, `kube-controller-manager` and `kube-scheduler` can lose their leader-election
lease and exit. The kubelet restarts them, each restart re-lists everything from the API server, and that makes it slower still.

Seen on hangar-dev (2026-11): 362 controller-manager and 348 scheduler restarts, with `leaderelection lost` and
`Failed to renew lease ... context deadline exceeded` (the lease GET timed out at 5 s). etcd logged ~1,800 `apply request took too long`
per 10 minutes and `slow fdatasync` of 1.7 s; the API server used ~2.3 cores and 7 GiB over 474 CRDs and 517 Crossplane MRDs.
Small calls still answered in 0.1 s, a full CRD LIST timed out at 60 s.

## What it changes

Both components, and only these:

| Flag | Default | Here |
|---|---|---|
| `--leader-elect-lease-duration` | 15s | 60s |
| `--leader-elect-renew-deadline` | 10s | 40s |
| `--leader-elect-retry-period` | 2s | 10s |

A renewal attempt now has 40 s overall to succeed instead of 10 s, and
a dead leader's lease expires after 60 s instead of 15 s. On a single node there is no second instance to take over, so
the longer lease costs nothing: the only effect of a slow renewal is that it no longer kills the process.
The rule is lease > renew > 1.2 x retry; the script refuses values that break it.

Not changed, on purpose: `--kube-api-qps`/`--kube-api-burst` (defaults 20/30 are already low; lowering them would slow the
garbage collector and namespace controller, whose discovery over ~1,000 resource types is the heavy part, while the fix
for the re-list storm is to stop the restarts) and the `--concurrent-*-syncs` flags (the cost is the lists, not the workers).
The API server and etcd are not touched either; see "Next, not done here".

## Running cluster

`hack/control-plane-tuning.sh` (python3 with PyYAML, kubectl, jq on the workstation; the node needs only `cat`, `cp`, `mv`,
`mkdir`, `chmod`, `tee`, `ls`). `--cluster` is the kubectl context. `--node-exec` defaults to
`container exec -i <node>` (kiac); for kind use `--node-exec "docker exec -i <node>"` or `"ssh HOST podman exec -i <node>"`.

```
hack/control-plane-tuning.sh plan     --cluster hangar-dev        # read-only: the exact diff, nothing written (the default command)
hack/control-plane-tuning.sh apply    --cluster hangar-dev --yes  # one component at a time
hack/control-plane-tuning.sh verify   --cluster hangar-dev
hack/control-plane-tuning.sh rollback --cluster hangar-dev --yes
```

Values come from `--lease-duration/--renew-deadline/--retry-period`, or from the cluster's `runtime.controlPlane.leaderElection`
with `--cluster-dir DIR` (defaults 60s/40s/10s on kiac and kind).

**When to use it.** `kubectl -n kube-system get pods` shows kube-controller-manager or kube-scheduler with many restarts, and
their logs (`kubectl -n kube-system logs --previous ...`) say `leaderelection lost`. Do not use it to hide a node that is
out of memory or CPU: check `container ls` first (kiac sizes the control plane with `--cp-memory`, not `--memory`).

**Safety.** Before anything is written:

- the context must exist and have exactly one control-plane node, and that node's own `/etc/hostname`, read through
  `--node-exec`, must equal the node's name (a `--node-exec` aimed at another cluster is refused);
- a flag already set to a different value is refused for both components before either is touched; the same values are a no-op;
- the edit inserts three lines after the last argument of the command list and nothing else, and the result is parsed to
  confirm it differs from the original by exactly those arguments.

`apply` takes the scheduler first, then the controller manager, and for each: backs the manifest up to
`/etc/kubernetes/hangar-backup/kube-<component>.yaml.<UTC stamp>` (outside `manifests/`, where the kubelet would run it), stages
the new file beside it and `mv`s it into place (atomic, mode 0600), then waits for the static pod to restart Ready with the
new flags, waits for the new lease (`spec.leaseDurationSeconds` equals the new value, held by this node), and holds for
`HOLD_MINUTES` (5): no restart, no lost lease, renewTime fresh. Any failure restores that component's backup
by itself and exits non-zero. It never touches `kube-apiserver.yaml` or `etcd.yaml`.
Timeouts: `WAIT_SECONDS` 300, `ACQUIRE_SECONDS` 240, `POLL_SECONDS` 15.

**Verify.** `verify` checks the flags in both manifests, the pods Ready, and each lease's duration, holder and age, and prints the
restart counts. `restartCount` only grows, so judge the fix by reading it again hours later: it should not have moved.

**Rollback.** `rollback` (without `--yes` it prints the diff only) restores the newest `kube-<component>.yaml.<stamp>` backup per
component (`--backup STAMP` picks one, `--component` one component) after saving the current file as
`.pre-rollback-<stamp>`. By hand, from the node: `cp /etc/kubernetes/hangar-backup/kube-scheduler.yaml.<stamp>
/etc/kubernetes/manifests/kube-scheduler.yaml`. Never leave a copy in `manifests/`: the kubelet would run it as a second pod.

The node's filesystem survives node restarts. A recreated cluster does not keep the edit.

## New clusters

- **kind:** `hack/kind-config.yaml` carries a kubeadm `ClusterConfiguration` patch with `controllerManager.extraArgs` and
  `scheduler.extraArgs`, rendered from `runtime.controlPlane.leaderElection` (`leaseDuration`, `renewDeadline`,
  `retryPeriod`). `hack/control-plane-tuning.sh render` prints the same patch.
- **kiac:** kiac has no kubeadm hook (no create-time kubeadm patches), so a new kiac cluster gets the same edit after
  `apron up` by running `hack/control-plane-tuning.sh apply --cluster <name> --cluster-dir <dir> --yes`. `apron up` does not run it.
- **existing / eks:** managed control planes; the defaults are not rendered and the script is not for them.

## Next, not done here

Evidence-based suggestions for the API server and etcd, each needing its own review and apply (not part of this change):

- **etcd defrag and the fsync cost.** The DB is 215 MB (normal), so the slowness is `slow fdatasync` (1.7 s), i.e. the VM's
  disk, not size. A defrag (`etcdctl defrag`, one member, brief write stall) reclaims free pages and shortens the file but does
  not fix fsync latency; the real lever is faster storage for the node's `/var/lib/etcd` (host SSD-backed volume) or
  `--cpus`/`--cp-memory` headroom for the VM.
- **etcd `--heartbeat-interval` / `--election-timeout`.** A single member never holds an election, so these only matter for
  its own leader lease; raising them (e.g. 500 ms / 5000 ms) is harmless on one member but does not reduce write latency. Low value.
- **etcd `--quota-backend-bytes`.** Default 2 GiB; at 215 MB there is no pressure. Leave unless the DB grows past ~1 GiB.
- **kube-apiserver `--min-request-timeout`** (default 1800 s) governs watches only, not LISTs; it does not address the 60 s CRD LIST
  timeout. The levers for that are `--max-requests-inflight` / `--max-mutating-requests-inflight` (flow control already
  shapes load), `--default-watch-cache-size` and `--watch-cache-sizes` for the CRD-heavy resources, and fewer clients listing
  CRDs at once (Crossplane providers' MRD discovery, Argo CD resource caches).
- **Fewer restarts upstream of the API server.** The apiserver liveness probe is already relaxed (30 s x 12, see
  `templates/hack/kubeadm-patches/`); measure it again after this change before touching more.
