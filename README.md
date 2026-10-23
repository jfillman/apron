<div align="center">
  <img src="docs/brand/apron-tile.svg" width="88" height="88" alt="Apron mark" />
  <h1>Apron</h1>
  <p><i>Ground infrastructure a cluster needs before a Hangar can run on it.</i></p>
</div>

**Apron deploys Hangar onto your Kubernetes cluster.** It renders the cluster's own GitOps repo from a small
`cluster.yaml`, then onboards the cluster: two Argo CD instances (`argocd` for the platform, `argocd-apps` for apps),
the root app-of-apps, and stops for the few secrets a person must plant. Onboarding an existing cluster is the
primary path. `kiac` and `kind` are conveniences that create a local cluster first and then run the same onboarding.

> Interim engine. Rendering is Apron's own token templates today. Porting them to the kubara catalog is next (the
> 2026-10-16 review decision: kubara as the only renderer, Apron's installs driven from its output), so don't build
> on the template format.

## The one-name rule

A cluster has one name, chosen by you, and everything else derives from it. Apron's code, templates and docs contain
no cluster names. For `--name hangar-dev`:

| What | Value |
|---|---|
| kubectl context | `hangar-dev` (Apron renames `kiac-hangar-dev` / `kind-hangar-dev` to it) |
| fleet record (`clusters.yaml`) | `name: hangar-dev` |
| Infisical projects | `<app>-hangar-dev`, `glidepath-hangar-dev` |
| ServiceAccount issuer | `https://<issuerBase>/oidc/hangar-dev` (`issuerBase` default `hangarplatform.dev`) |
| hostnames | `argocd.hangar-dev.local`, ... (`--domain` overrides `<name>.local`) |

Names must be DNS-1123 labels. There is no default owner either: `--scm-owner` is required, and `--registry-owner`
defaults to it.

## Profiles and runtimes (independent)

- A **profile** says *what* the cluster runs. `profiles/dev.yaml` is the lower zone: the CI/CD control plane
  (Glidepath, Bootstrap-tier Crossplane, the full service catalog), workloads, the fleet's Infisical server, full
  observability, Autopilot and AI triage. `profiles/prod.yaml` is the upper zone: workloads and platform services, an
  Infisical consumer, the Attached-tier catalog plus Dex, Prometheus only, and `towerAccess`. Tower itself (Backstage)
  is an Airframe app (`app-backstage-<env>`), not a cluster component: `towerAccess` holds only its cluster-scoped
  grants, and `65-backstage` stays in the templates off by default, for reference.
- Observability reaches apps through `cluster-defaults.yaml`'s `observability` block: every environment's
  NetworkPolicy admits Prometheus, and with full observability the OpenTelemetry Operator auto-instruments Node.js,
  Java and Python apps (picked from the app's Airframe kind) into the gateway collector, then Tempo and Prometheus.
- A **runtime** says *how* the cluster comes to exist: `existing` (any cluster, Traefik as a LoadBalancer), `kiac`
  (single-node VM, Cilium, Traefik on NodePorts 30080/30443; never `--gateway`) or `kind` (Calico v3.29.1, host 80/443
  mapped to Traefik's NodePorts). Defaults live in `runtimes/*.yaml`. Every runtime gets the same Traefik Gateway
  (`hangar` in `hangar-gateway`), installed by Apron.
- Any value can be overridden in `cluster.yaml` or with `--set key=value` at init: `--set runtime.kiac.cpus=8`,
  `--set components.aiTriage=false`.
- `versions.yaml` pins Airframe, Glidepath and the Argo CD chart in one place. The name-free Airframe/Glidepath/Tower
  changes are on their `no-hardcoded-cluster-names` branches: cut tags from them and set those tags in `versions.yaml`
  before the rebuild uses them.

## Install

1. **Create two new repos per cluster**, the cluster repo and its tenants repo (`<repo>-tenants` by default): by hand,
   or with `apron init --create-repos`, which runs `gh repo create <owner>/<name> --private` only for repos that don't
   exist. Old cluster repos are never touched.
2. **Init** writes `DIR/cluster.yaml` (committed: it is what re-renders from), checks it, and renders the repo:

   ```
   apron init dev  --name hangar-dev  --runtime kiac --out ~/gitops-cluster-hangar-dev \
     --repo-url https://github.com/<owner>/gitops-cluster-hangar-dev --scm-owner <owner> --tower-cluster hangar-prod
   apron init prod --name hangar-prod --runtime kind --out ~/gitops-cluster-hangar-prod \
     --repo-url https://github.com/<owner>/gitops-cluster-hangar-prod --scm-owner <owner> \
     --fleet-hub hangar-dev --fleet-repo-url https://github.com/<owner>/gitops-cluster-hangar-dev
   ```

   `--runtime existing --context <ctx>` adopts an existing cluster instead.
3. **Commit and push** the cluster repo (`--push` does it).
4. **Up**: `apron up --out DIR` (add `--dry-run` to see the plan). Phase 1 is the runtime: create the cluster, or
   verify an existing one is reachable, and make its context equal the name. Phase 2 is onboarding, the same for every
   runtime: CNI if the runtime needs one, Argo CD, then a stop for every secret a person must plant (exact commands
   printed, values never). Re-run `apron up` after planting them: it resumes and applies the root app.
5. **Fleet**: `apron fleet add --from DIR --fleet <hub repo>/clusters.yaml` writes the cluster's record (with the
   file's required `scm: {owner}` block) in the hub's fleet file. After Infisical's first-run setup,
   `apron fleet set-infisical --fleet ... --org-id X --url U` fills the `infisical:` block.
6. **Identity**: `apron identity --out DIR` gives the cluster its issuer and, on the hub, trusts Tower's cluster
   (`hack/cluster-identity.sh` with names derived from the cluster; [docs/cluster-identity.md](docs/cluster-identity.md)).
   Publish the issuer's keys first.

Day 2, after upgrading Apron or bumping `versions.yaml`: `apron render --out DIR` re-renders from `cluster.yaml`. It
prints what it added, changed and removed, and leaves `cluster.yaml` and `clusters.yaml` alone. Review, commit, push.

<!-- apron CLI section: kept separate so it merges cleanly with the rest of this README. -->
## Install Hangar on a cluster

`./apron` does it in two commands ([docs/cli.md](docs/cli.md)). Pick a name: it becomes the cluster's kubectl
context, fleet entry, Infisical project stem, issuer path and hostname stem.

**An existing cluster** (the primary path). Its kubectl context must be the cluster's name
(`apron up --rename-context <current>` renames it):

```
./apron init prod --name <name> --runtime existing --repo-url https://github.com/<owner>/gitops-<name>.git \
  --scm-owner <owner> --out ../gitops-<name> --create-repos --push
./apron up --out ../gitops-<name>
```

**A local cluster**: the same, with `--runtime kiac` (Apple container VMs) or `--runtime kind`. `apron up` creates the
cluster first, then onboards it exactly as above.

`apron up` stops once, after installing Argo CD, to list the Secrets you create by hand (it prints the commands with
`<value>` placeholders). Create them and run `apron up` again. Then follow the steps it prints
([docs/after-up.md](docs/after-up.md)) and add the cluster to the fleet with
`./apron fleet add --from ../gitops-<name> --fleet <control-plane repo>/clusters.yaml`.

## Rebuilding the lab

The lab's dev cluster runs on a Mac with kiac, its prod cluster on a second MacBook with kind. That is a hardware
choice, not a rule: either profile runs on any runtime. Steps 1-6 above with `--name hangar-dev --runtime kiac` and
`--name hangar-prod --runtime kind`. Then:

- Hosts reach a kiac or kind cluster's Gateway through its node: `/etc/hosts` maps `argocd.<name>.local` and the rest
  (`apron up` prints them) to the node's IP. kind maps host port 80; on kiac use `<node IP>:30080`, or forward 80 to
  it.
- The prod cluster reaches the hub's Infisical and release relay at `<hub>.local:31800` / `:30880`. If its pods can't
  resolve that name, set `fleet.hubAddress` to an IP the hub's NodePorts answer on, and Apron adds hostAliases.

## Layout

| Path | What |
|---|---|
| `templates/` | every file a cluster repo gets, by numbered group (00 bootstrap ... 70 AI triage); `MANIFEST` selects paths, `#@if` selects lines; tokens in [templates/TOKENS.md](templates/TOKENS.md) |
| `profiles/`, `runtimes/`, `versions.yaml` | defaults layered under `cluster.yaml` |
| `hack/render.py`, `hack/check.py`, `hack/new_cluster.py` | render, invariants (zone/roles, singletons, one-name rule), starter `cluster.yaml` |
| `hack/cluster-identity.sh` | issuer and trust on a running control-plane node |
| `tests/run.sh` | offline tests: renders, re-render, every invariant refused |
| `apron`, `hack/apron_fleet.py`, `tests/cli/` | the CLI (`init`, `render`, `up`, `fleet`, `identity`, `verify`, `resume`, `down`) and its tests |
| `docs/` | [the fleet file](docs/clusters-file.md), [cluster identity](docs/cluster-identity.md), [the CLI](docs/cli.md), [after `apron up`](docs/after-up.md) |
