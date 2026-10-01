# 00-bootstrap

> **Template note**: this file was carried over from `gitops-cluster-dev`'s own README and describes that cluster's real build history — useful background on how this component works and why, not a to-do list for your new cluster. Treat dates/"live-verified" claims as historical, not something to re-verify on this one.


Namespaces, base RBAC, NetworkPolicies, ResourceQuotas — per `gitops-strategy.md` §3.

## Current state (documented, not yet ArgoCD-managed)

Every namespace on `kind-observe` today was created by whatever component owns it
(Helm's `--create-namespace`, an install script's `kubectl create namespace`, or
`platform-cicd`'s own onboarding chart) — there's no single place any of them were
declared as "bootstrap" resources, and re-declaring them here as ArgoCD-managed objects
wouldn't change anything real, just add a second, redundant owner. Documenting the
inventory here for reference; actual namespace creation stays colocated with whatever
installs into it (captured in `10-crds-operators/`, `40-observability/`,
`50-platform-cicd/`, or the app-onboarding flow).

Namespace inventory, by owner, as of 2026-08-12:

| Namespace(s) | Owned by |
|---|---|
| `crossplane-system` | Crossplane's own Helm chart — `10-crds-operators/crossplane/` |
| `cert-manager`, `external-secrets` | Their own Helm charts — `10-crds-operators/` |
| `argo-rollouts`, `projectcontour` | Raw-manifest installs — `10-crds-operators/` |
| `argocd` | ArgoCD's own raw install — `01-argocd-platform/` |
| `observability` | `kube-prometheus-stack`/`loki`/`minio`/`otel-collector`/`tempo`/`thanos` — `40-observability/` |
| `holmesgpt` | Own Helm chart — `40-observability/` (tentative grouping, see that dir's README) |
| `platform-system`, `platform-catalog`, `platform-secrets`, `pipelines-as-code`, `tekton-pipelines`, `tekton-pipelines-resolvers`, `tekton-chains`, `fulcio-system`, `rekor-system` | `platform-cicd`'s own charts + raw installs — `50-platform-cicd/` |
| `app-<name>-<env>` (per app, e.g. `app-boarding-api-cicd`) | Per-app onboarding — will move to `gitops-cluster-dev-tenants` (Phase 2) |
| `demo`, `demo-apps` | `ai-rollout`'s standalone demo (folded into `idp`'s design, not this cluster-config repo — see Item 7/8 discussion in `service-catalog-design.md`) |

**Known, real gap, not addressed by this pass**: no `NetworkPolicy` enforcement anywhere
on this cluster — already flagged in `platform-cicd/docs/bootstrap.md` before this repo
existed. Baseline RBAC/NetworkPolicy/ResourceQuota manifests belong here once designed;
not designed or built yet.
