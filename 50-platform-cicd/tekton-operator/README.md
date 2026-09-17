# tekton-operator

> **Template note**: this file was carried over from `gitops-cluster-dev`'s own README and describes that cluster's real build history — useful background on how this component works and why, not a to-do list for your new cluster. Treat dates/"live-verified" claims as historical, not something to re-verify on this one.


Installs Tekton Pipelines/Triggers/Chains/Dashboard/Pipelines-as-Code on `kind-dev` via
[tektoncd/operator](https://github.com/tektoncd/operator) (v0.81.0, vendored) instead of
the raw-manifest-per-component install `hack/bootstrap.sh` uses for `kind-observe`.
`kind-observe` is untouched - this is `kind-dev`-only, see `50-platform-cicd/README.md`.

`tekton-servicemonitor.yaml` (also synced by this directory's Application) is the one
piece of `kind-observe`'s custom observability config ported here - Prometheus scraping
for Tekton's own controller metrics, feeding `pipelines-overview.json`'s PipelineRun
list panels. Confirmed the same `app: tekton-pipelines-controller` label and
`http-metrics` port name apply to the operator-installed Service unchanged.

## Why the operator, and why NOT a Helm chart

Real Helm charts exist for individual components
(`cdfoundation/tekton-helm-chart` for Pipelines,
`chainguard-dev/tekton-helm-charts` for Chains/Dashboard) - checked live, not assumed.
Only the Pipelines chart is actually current (1.6.0, matching what was running); the
Chains/Dashboard charts are badly stale (max appVersion v0.9.0/v0.24.1 against
v0.26.0/v0.70.0 actually running) - using them would be a real downgrade, not a
like-for-like migration. No chart exists anywhere for Triggers or Pipelines-as-Code.

`tektoncd/operator` is the Tekton project's own official install mechanism and covers
all 5 components in one place. Real tradeoff, accepted deliberately: it doesn't support
pinning individual component versions the way this platform's raw-manifest installs do
(`PAC_VERSION`/`TEKTON_DASHBOARD_VERSION` in `hack/bootstrap.sh`) - whatever versions ship
bundled with the operator release is what you get.

## What's real, not assumed - live-verified against a throwaway kind cluster, 2026-08-16

- **Everything lands in ONE namespace** (`spec.targetNamespace`, `tekton-pipelines`
  here), not each component's own conventional namespace. This is the single biggest
  structural difference from `kind-observe`'s layout and has a real ripple: anything that
  hardcoded `tekton-chains`/`pipelines-as-code` as a namespace name had to change - see
  `platform-cicd`'s own `tektonChainsNamespace` value
  (`charts/platform-cicd-control-plane`, `charts/platform-cicd-catalog`,
  `../platform-cicd-control-plane/values-kind-dev.yaml`), most importantly
  `verify-image-provenance.yaml`/`verify-sast-attestation.yaml`'s cosign
  `--certificate-identity-regexp` - a security-critical check (verifies a signature
  really came from the real Chains controller), not a cosmetic path.
- **`dashboard.readonly` defaults to `false`** (write-enabled) - this platform
  deliberately runs Dashboard read-only everywhere else (`hack/bootstrap.sh`'s own
  comment: a write-enabled dashboard is a standing bypass around the "no elevated
  identity anywhere" posture). Set explicitly in `tektonconfig.yaml`, confirmed live via
  the rendered Deployment's own `--read-only=true` arg - not trusted as inherited.
- **`profile: all` bundles Tekton Results** (an archival/results-API component).
  Enabled via `spec.result.disabled: false` for long-term pipeline data retention - a
  durable archive of full PipelineRun/TaskRun objects and step logs, which nothing else
  in this platform provides (Grafana/DORA-exporter/CDEvents track metrics and events, not
  the run objects; `pipelinerun-pruner-cronjob` just deletes them). Uses the operator's
  own auto-managed internal Postgres (`is_external_db: false`) and reuses the
  observability MinIO instance for S3 storage via a `tekton-results` bucket
  (`40-observability/minio/create-buckets-job.yaml`) and
  `tekton-results-s3-secret.yaml` (this directory). `watcher.completed_run_grace_period:
  "1h"` makes Results the primary CR-cleanup path, well ahead of
  `pipelinerun-pruner-cronjob`'s 24h retention. Deliberately no `HTTPRoute` - the Results
  API is TLS-only on its single port and a plain-HTTP Gateway listener can't front it;
  add one only once the target cluster's Gateway has a real TLS/passthrough listener. See
  `docs/admin/tekton-results.md` and `docs/admin/adr/0016-tekton-results-archival.md` in
  `glidepath` for the full writeup.
- **Pipelines-as-Code IS covered on plain Kubernetes** via
  `spec.platforms.kubernetes.pipelinesAsCode.enable` - a real, documented field, separate
  from the OpenShift-only `TektonAddon`/`OpenShiftPipelinesAsCode` mechanism this session
  found first and initially (incorrectly) concluded was the only path. Confirmed live
  running v0.50.0 - past the known v0.49.0 arm64 SIGSEGV crash `hack/bootstrap.sh` pins
  `PAC_VERSION=v0.48.1` to avoid, healthy with zero restarts on the same arm64 node class.
- **`scheduler`/`tektonpruner` sub-fields are structurally required**, even though
  neither component is in `profile: all`'s bundle - v0.81.0's `TektonConfig` CRD marks
  them required regardless of profile. Only surfaced on the real `kind-dev` apply, not
  the throwaway-cluster proof (that one only ever went through the simpler from-scratch
  install path once) - a from-scratch install gets these defaulted by the operator's own
  webhook, but re-applying the CR without them fails real schema validation
  (`spec.scheduler.disabled: Required value` et al). Both explicitly disabled in
  `tektonconfig.yaml`.

## Status

Proven twice: first against a real throwaway kind cluster (created and torn down same
session, never touched `kind-dev`) - operator installs cleanly, `TektonConfig` reaches
`Ready`, all expected component Deployments come up healthy in one namespace, Dashboard
confirmed read-only, PAC confirmed enabled and healthy (Results was disabled and confirmed
absent at the time of this original proof - see the 2026-09-17 update above for it being
enabled since). Then
applied for real to `kind-dev` and live-verified end-to-end with a real signed build -
see `50-platform-cicd/README.md`'s own status for the full writeup (including the
`scheduler`/`tektonpruner` gap above, only surfaced on the real apply, and two real
kaniko/TLS bugs found and fixed only by actually running a build).

**A genuinely separate, real node-capacity problem was also found and fixed while
applying this to `kind-dev`** - not a bug in this design, but worth recording here since
it will recur on any cluster running this many components on one kind node: kubelet's
default `max-pods` (110) and this specific podman container's own `--pids-limit`
(2048, well below what ArgoCD ×2 + Crossplane + the full observability stack + Tekton
needs simultaneously) were both hit live, producing exactly the same generic
`fork/exec: resource temporarily unavailable` symptom regardless of actual CPU/memory
headroom (both stayed low throughout - confirmed via `/proc/loadavg` and `free -h`, not
assumed). Fixed live: `maxPods: 250` added to `/var/lib/kubelet/config.yaml` +
`systemctl restart kubelet`, and `podman update --pids-limit 8192 dev-control-plane` -
neither persists across a full `podman machine stop`/`start` cycle, so re-apply both
after any VM-level restart of this node.
