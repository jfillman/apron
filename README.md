<div align="center">
  <img src="docs/brand/apron-tile.svg" width="88" height="88" alt="Apron mark" />
  <h1>Apron</h1>
  <p><i>Ground infrastructure a cluster needs before a Hangar can run on it.</i></p>
</div>

Gold-standard starting point for a new `gitops-cluster-<name>` repo — per
`idp/docs/gitops-strategy.md` §1's per-cluster repo shape, and closes the
"repo-scaffolding script" gap that doc flagged as unsolved. Standing up a new cluster
means using this repo as a GitHub template, running one script against a small
declarative config, and following the bootstrap sequence below — instead of hand-
copying the last cluster's repo and hoping nothing real diverged silently (the
divergence between the fleet's first two clusters, `gitops-cluster-dev` and
`gitops-cluster-kind-prod`, is exactly what motivated building this).

See `idp/docs/cluster-provisioning.md` for the full design.

## Usage

1. **Use this template** (GitHub's own "Use this template" button — mark this repo as
   a template repository in its GitHub settings first, one-time setup) to create a new
   repo, e.g. `gitops-cluster-kind-staging`. Clone it locally.
2. `cp cluster.yaml.example cluster.yaml` and edit it — at minimum `clusterName`,
   `clusterRepoName`, and `type` (`dev` or `upper`). See that file's own comments for
   the full schema, including the component-subset toggles.
3. `./hack/customize-cluster.sh` — validates your config (refuses outright on a
   `type: upper` cluster requesting a dev-only component, rather than silently
   correcting it), deletes whichever optional component directories you didn't select,
   and substitutes this template's own identity strings (repo name, cluster name,
   Infisical project slug) with your real values throughout every remaining file.
4. Follow the printed next steps: commit + push, register the new cluster in
   `gitops-cluster-dev`'s cluster registry (see below — deliberately not automated by
   the script), then bootstrap the cluster itself (see below).

## What this template does *not* model yet

- **AI-triage / HolmesGPT** (`30-ai-triage/` on `gitops-cluster-kind-prod`) — that
  mechanism is still only partially designed platform-wide
  (`idp/docs/gitops-strategy.md`'s "Forward-looking" section), so there's no
  `components.aiTriage` toggle here yet. Add one the same way the existing toggles
  work once that design lands.
- **Per-cluster secret/identity material that must never be reused across clusters**
  (platform-cicd's Fulcio root + API-server CA, the real Infisical bootstrap
  credentials) — deliberately not vendored into this template at all, generated fresh
  per cluster by tools that already exist for exactly this
  (`platform-cicd/hack/generate-cluster-values.sh`, ADR-0006's own subject; manual
  `kubectl create secret` for the Infisical bootstrap Secrets, same "never pasted to
  an assistant, never committed" convention as everywhere else in this platform). The
  script's own printed next-steps call these out by name when relevant.
- **`idp-cluster-baseline`** — `gitops-strategy.md` §8's planned shared Helm chart
  layer doesn't exist yet. This template packages today's real pattern (each logical
  group is its own vendored install / ArgoCD `Application`, exactly as both existing
  cluster repos already do) — if/when that chart gets built, this template's own
  `10-crds-operators/`/`40-observability/` groups are the natural place to switch over
  to consuming it.

## Cluster registry — not part of this repo

`hack/customize-cluster.sh` prints the exact `ConfigMap` to add, but doesn't push it
itself: the cluster registry lives centrally in `gitops-cluster-dev/00-bootstrap/
cluster-registry/`, the one place `NodeJSApplication.spec.devCluster` /
`ApplicationEnvironment.spec.cluster` actually read it from — it's not something a new
cluster's own repo carries a copy of.

## Bootstrap sequence

Same shape as both existing clusters' own (`gitops-cluster-kind-prod/README.md`'s
"Bootstrap steps, in order" is the most current, GitOps-native version — this repo's
own `01-argocd-platform/README.md` predates and describes the same steps in more
detail):

```
kind create cluster --name <short-name> --config hack/kind-config.yaml   # local kind only — skip for a real cluster
# install Calico (v3.29.1, matching the rest of this fleet) before anything else touches the cluster
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f 01-argocd-platform/install.yaml
# restore this cluster's own argocd-repo-creds-<you> Secret before the next step — root's own repo is private
kubectl apply -f root-app-of-apps.yaml
```

`--server-side`, not plain `apply` — the `applicationsets.argoproj.io` CRD is too
large for `kubectl apply`'s default `last-applied-configuration` annotation, hit live
on both existing clusters.
