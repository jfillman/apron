# glidepath-api's PipelineRun policies

`30-policy/kyverno-policies/tower-identity-writes.yaml` holds the Kyverno policies that constrain the PipelineRuns
`glidepath-api` creates (a rerun, a promote, a rollback). They match only `system:serviceaccount:platform-system:glidepath-api`
(and refuse Tower's `tower-actor`), only in `(app|infra)-*-cicd` namespaces, `failurePolicy: Fail`.

Glidepath's own policies (`cicd-run-shape`, `cicd-run-source-isolation`, in the glidepath-control-plane chart) hold the runs
Pipelines-as-Code creates from a `.tekton` file. The runs `glidepath-api` creates must be held to the same per-task rule, or
a rerun would be the way round it (pipeline trust T5).

## What is enforced

`glidepath-api-pipelinerun-shape` (always Deny), on create:

| Rule | Why |
|---|---|
| `taskRunSpecs` entries are only `(pipelineTaskName, serviceAccountName)` pairs the platform defines for the referenced Pipeline: source tasks as `source-runner`, pusher tasks as `image-pusher`, cloud deploy tasks as `glidepath-cloud-deployer` | a rerun may carry the isolation a build run has, and never attach a credentialed account to a task that runs repository code |
| no other field in an entry (`podTemplate`, `computeResources`, `stepSpecs`, `sidecarSpecs`, metadata), a task named once | Glidepath's own templates set only those two |
| annotations from an explicit allowlist: `glidepath.io/origin-ref`, `-origin-sha`, `-origin-event` (what `verify-ref-protection` checks), `glidepath.hangar.io/rerun-of`, `glidepath.hangar.io/idempotency-key-sha256`, `hangar.io/initiator`; never `pipelinesascode.tekton.dev/` | a new prefix cannot slip in |
| a workspace `volumeClaimTemplate` carries only `accessModes` (ReadWriteOnce) and a storage request of 1Gi to 50Gi; no `dataSource`, `dataSourceRef`, `volumeName`, `selector`, limits; `storageClassName` only if listed in `glidepath.runStorageClasses` | the same restriction Glidepath puts on `.tekton` files |
| the rules that were already there: no inline `pipelineSpec`; a cluster-resolved Pipeline in `platform-catalog`; run account `pipeline-runner`; `podTemplate` only `hostAliases`; workspaces only `emptyDir` or `volumeClaimTemplate`; an update may change `spec.status` only | unchanged |

`glidepath-api-pipelinerun-source-isolation` (Deny, or Warn and Audit; see below): a run of a Pipeline that runs repository code
must give those tasks to `source-runner` and its push task to `image-pusher`. This mirrors Glidepath's
`cicd-run-source-isolation`: a rerun that dropped `taskRunSpecs` would run repository code as `pipeline-runner`.

Every expression reads a field only after checking it exists and has the type it should (Tekton keeps `spec` as unknown
fields), so an odd shape is refused or ignored, never an evaluation error.

## Where the task lists come from

The lists are Glidepath's `cicdRunAdmission.sourceTasks`, `pusherTasks` and `cloudDeployerTasks`. A Kyverno policy cannot read a
chart's values, and Apron does not set them (the chart's defaults apply), so `versions.yaml` (`versions.glidepathRunTasks`)
carries them next to the Glidepath pin and `apron render` compares them with the pinned Glidepath's
`charts/glidepath-control-plane/values.yaml` (`hack/glidepath_tasks.py`): a list that differs refuses the render and names the
Pipeline and the tasks. Bump them with the pin.

- `APRON_GLIDEPATH_VALUES=<values.yaml>` compares with a local file (a checkout's) instead of fetching.
- If the pinned values cannot be fetched (no network), the render goes on with a warning saying the check was not made.
- `APRON_GLIDEPATH_CHECK=off` skips it.

The version that cannot drift is the policy living in the Glidepath chart next to the other two, reading the same values, so one
release carries all three. That is a Glidepath change (the chart would also need the Tower actor's name, which only Apron
knows); until it exists the render check is what keeps the copies equal.

## Upgrading

`glidepath.sourceIsolation` (in `cluster.yaml`) sets the action of the source-isolation policy here AND of Glidepath's
`cicd-run-source-isolation` binding (`cicdRunAdmission.sourceIsolationActions`), so a rerun and a Pipelines-as-Code run are held
to the rule at the same time:

- `deny` (the default): enforcing. Use it once every app's `.tekton` files have been resynced and no run without the
  source-runner entries remains.
- `warn`: `[Warn, Audit]`, for the upgrade. A rerun of a run created before the hardening (no `taskRunSpecs`) is admitted with a
  warning. The first policy stays Deny in both modes, so a credentialed account on a task that runs repository code is refused
  even now. The chart annotates its binding "NOT ENFORCING" and alerts while it is not `deny`.

The first policy admits runs from before and after the Glidepath release, so it can be rendered at any time. Order:

1. Render the cluster with this version of Apron and `glidepath.sourceIsolation: warn`, and let Argo CD apply it. Reruns of
   today's runs, and of hardened ones, are admitted.
2. Glidepath release synced; resync each app's `.tekton/` (`onboarding-resync`), so new runs carry the entries.
3. When no run without them is left (finished runs are pruned within about an hour; PaC keeps a few), remove
   `glidepath.sourceIsolation` (or set `deny`), render, apply.

Cluster order: `hangar-dev` first (it runs the Glidepath control plane and `glidepath-api`; its tree gets the policy); then, with
the owner's OK, any other cluster that runs the control plane. A cluster without the Glidepath control plane (the lab's
`hangar-prod`) renders no change from this.
