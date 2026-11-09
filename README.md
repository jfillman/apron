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
  Infisical consumer, the Attached-tier catalog plus Dex, Prometheus and tracing, and `towerAccess`. Tower itself (Backstage)
  is an Airframe app (`app-backstage-<env>`), not a cluster component: `towerAccess` holds only its cluster-scoped
  grants, and `65-backstage` stays in the templates off by default, for reference.
- Observability reaches apps through `cluster-defaults.yaml`'s `observability` block: every environment's
  NetworkPolicy admits Prometheus, and with `observability.tracing` (both profiles; implied by `observability.full`)
  the OpenTelemetry Operator auto-instruments Node.js, Java and Python apps (picked from the app's Airframe kind) into
  the gateway collector. The collector drops probe and `/metrics` spans, derives span metrics and the service graph
  (`traces_service_graph_*`, Tower's Airspace edges) for Prometheus, and sends traces to Tempo (MinIO-backed with the
  full stack, local disk without) unless `observability.tempo: false` (the prod profile: no trace store).
- A **runtime** says *how* the cluster comes to exist: `existing` (any cluster, Traefik as a LoadBalancer), `kiac`
  (single-node VM, Cilium, Traefik on NodePorts 30080/30443; never `--gateway`) or `kind` (Calico v3.29.1, host 80/443
  mapped to Traefik's NodePorts). Defaults live in `runtimes/*.yaml`. Every runtime gets the same Traefik Gateway
  (`hangar` in `hangar-gateway`), installed by Apron.
- Any value can be overridden in `cluster.yaml` or with `--set key=value` at init: `--set runtime.kiac.cpus=8`,
  `--set components.aiTriage=false`.
- `versions.yaml` pins Airframe, Glidepath and the Argo CD chart in one place. The name-free Airframe/Glidepath/Tower
  changes are on their `no-hardcoded-cluster-names` branches: cut tags from them and set those tags in `versions.yaml`
  before the rebuild uses them.

## Autopilot (`components.autopilot`, control-plane clusters only)

`55-autopilot/` holds what Autopilot's agent runs need on the cluster. `apron check` refuses it off the control-plane
cluster and without the full catalog.

| Path | What | Guardrail |
|---|---|---|
| `namespaces/` | `autopilot-system` (Clearance, the model proxy) and `autopilot-runs` (AgentRun XRs), pod security restricted | never labelled `hangar.io/ephemeral-env` |
| `agent-sandbox/` | the kubernetes-sigs/agent-sandbox controller, chart pinned by commit and image by digest (v1.0.8) | a run's Sandbox `shutdownTime` ends its pod with no Clearance or Crossplane involved |
| `clearance/` | the Autopilot gateway (Deployment `clearance`), its read API (`autopilot-api`), `autopilot-pg`, their NetworkPolicies and routes (`autopilot.<domain>`: `/mcp`, the inbox, person controls, Run, and a public `GET /healthz`) | ingress default-deny but for run namespaces and the cluster Gateway; with `observability.full` both send a copy of their log lines to the OTel collector (OTLP/HTTP, on to Loki as `service_name` `autopilot-gateway` / `autopilot-api`) |
| `agentrun-grants/` | provider-kubernetes's ClusterRole for a run's objects, the ValidatingAdmissionPolicy that confines it, a second policy on who may create such Objects, Clearance's Role | the grant only ships with the policy: run namespaces (`agent-r-*`) only, no pod-security label changes, no PR-sweep label, `serviceAccountName: run` only (decision D15); and a provider-kubernetes Object with a run-kind manifest comes only from Crossplane core for an AgentRun, never hand-made |

It also gives provider-kubernetes a stable service account (`10-crds-operators/crossplane/provider-kubernetes-runtime.yaml`)
and installs function-agentrun with the cluster's name (`function-agentrun-runtime.yaml`). Runs land only once the
cluster's registry record has `airframe.autopilotReady`, set after autopilot's `tools/netpol_canary.py` passes.
`tests/policy/test_agentrun_grants.py` proves the policy against a real kube-apiserver (envtest binaries in
`KUBEBUILDER_ASSETS`; `tests/run.sh` skips it without them).

## Clearance's Argo CD gate (`clearance.gate`, Draft)

`clearance.gate.enabled: true` puts Clearance's Config Management Plugin in front of every protected tenant
Application (clearance `docs/gate.md`, "The Argo CD plugin"). Two things render:

- argocd-apps' repo-server gets the `clearance-cmp` sidecar (`versions.clearance.cmpImage`, by digest), the only
  container that mounts the clearance token (a projected service-account token, audience `clearance`).
- the tenant-onboarding ApplicationSet gives an environment the gate covers one source, the plugin
  (`plugin.name: clearance`) on the app's gitops repo, in place of the Helm source and its `$appsrc` ref. The
  plugin fetches the same chart at the same pinned tag and renders it with the same value files and platform values.
  An environment is covered when `<cluster>/<env>` matches `clearance.protectedEnvironments` (every environment when
  that is empty); an environment on a registry (OCI) chart keeps the Helm source.

| `cluster.yaml` key | |
|---|---|
| `clearance.gate.enabled` | default off: nothing renders, an enabled cluster needs the next two pins |
| `versions.clearance.cmpImage`, `waitImage` | the `clearance-cmp` and `clearance-wait` images, by digest |
| `clearance.gate.url` | the core as the sidecar and the PreSync wait Job reach it; default `http://clearance-core.<namespace>.svc:8080` |
| `clearance.gate.hostAlias` | `ip=host[,host]` for the repo-server, the agent and the wait Job's pod when the core is on another cluster |
| `clearance.gate.apps` | limits the plugin to these apps, to turn the gate on one app at a time; empty: every app in a protected environment |
| `clearance.gate.agent` | renders the Argo CD agent (`56-clearance-gate/agent/`): `apiURL` (clearance-api), `projects`, `protectedNamespaces`; needs `versions.clearance.argocdAgentImage` and `argocdAgentChart` |

With the gate on and Flight admission on, the exact `versions.clearance.waitImage` is added to Flight's allowed images: the
wait Job runs in the tenant's namespace and is not a Flight image.

On the cluster that runs the core (`hangar-dev`), `clearance.foreignServiceAccounts`, `clearance.extraProviders`,
`clearance.verifiers` and `clearance.feedReaders` admit the protected cluster's agent, repo-server and wait Job;
`feedReaders` also opens the agent's `/v1/records` and `/v1/breakglass` routes.

## Check names (`pipelinesAsCode.applicationName`)

Pipelines-as-Code names every check run `<application-name> / <gate>-`. Apron sets the name from `cluster.yaml`
`pipelinesAsCode.applicationName` (default `Glidepath`, so checks read `Glidepath / sast-`) in two places that must
match: PaC's `pipelines-as-code` ConfigMap (`50-glidepath/tekton-operator/pipelines-as-code-vendored.yaml`) and the
glidepath-catalog's `pipelinesAsCode.applicationName`, which the gate tasks find checks by. The PaC GitHub App can have
any name; Backstage's `GLIDEPATH_GATE_COMMENT_APPS` must list its slug. See Glidepath's
[github-app.md](https://github.com/jfillman/glidepath/blob/main/docs/admin/github-app.md), including how to rename it.

## Flight admission (`admission.flight`, prod profile)

On an upper cluster, Apron renders Glidepath's Flight admission ([ADR-0029](https://github.com/jfillman/glidepath/blob/main/docs/admin/adr/0029-ground-and-flight-registries.md),
[registries.md](https://github.com/jfillman/glidepath/blob/main/docs/admin/registries.md#admission-phase-4)) into
`30-policy/kyverno-policies/flight-images.yaml`. `apron render` refuses `enabled` without `registries.flight.namespace`
and `promotion.promoter.repo` in `cluster.yaml`.

| Key | Renders | Turn it on when |
|---|---|---|
| `enabled` | `flight-only-images` (Flight prefix or `allowedPrefixes`) and `flight-images` (promotion attestation, offline), `[Audit, Warn]` with `failurePolicy: Ignore`, plus `kyverno/flight-registry-read` from Infisical `flight-registry-read-dockerconfigjson` | promotion is on in Glidepath |
| `pullFromFlight` | tenant `registry-credentials` reads `flight-registry-read-dockerconfigjson` (read-only) instead of the Ground credential | every app's prod release pins Flight; an app still on Ground could not pull on its next restart |
| `enforce` | `[Deny]` with `failurePolicy: Fail` | a server-side dry run of every running tenant pod gives no warning. While Kyverno's admission controller is down, new tenant pods are refused |
| `allowedPrefixes` | the third-party prefixes `flight-only-images` lets through (CloudNativePG, OTel auto-instrumentation, `bitnamilegacy`) | a tenant runs another image no Glidepath build produces |

hangar-prod: Audit 2026-10-29; `pullFromFlight` and `enforce` on since 2026-10-30.

## Clearance gate (`clearance.gate`, upper clusters)

On an upper cluster, Apron renders Clearance's deployment gate for Argo CD ([clearance docs/gate.md](https://github.com/jfillman/clearance/blob/main/docs/gate.md),
G-ARGO-2) into `56-clearance-gate/`: the `ClearanceGrant` CRD and two native ValidatingAdmissionPolicies.
`clearance-protected-writes` lets Argo CD's application controller write to a namespace labelled
`clearance.hangar.io/protected=true` only if the object carries the CMP's `clearance.hangar.io/rendered` stamp and the
namespace's one active, valid grant lists it at that hash; `clearance-grant-writer` lets only the grant-sync agent write
grants. Both match one service account, so no other writer is touched. The policy also exempts the plugin's injected `clearance.hangar.io/injected: wait` PreSync Job, but only the Job exactly
as the plugin builds it: the image **exactly** `versions.clearance.waitImage` (required with `clearance.gate.enabled`),
args `--change <id> --timeout <d>` only, `CLEARANCE_URL` pinned to `clearance.gate.url`, `hostAliases` pinned to
`clearance.gate.hostAlias`, no command, `envFrom`, host namespace, privileged container or volume besides the
audience-`clearance` token (the waiter mounts a clearance token, so its URL must not be changeable).

| Key | Renders | Turn it on when |
|---|---|---|
| `enabled` | the CRD, both policies and their bindings, `[Warn, Audit]` with `parameterNotFoundAction: Allow` | the cluster is a gate target (scratch namespace first) |
| `enforce` | `[Deny, Audit]` **and** `parameterNotFoundAction: Deny` | Warn is clean on every protected namespace, and the agent keeps one active grant on each (with Deny and no active grant, every matched write in the namespace is refused, from any user) |
| `argocdServiceAccount`, `agentServiceAccount` | the two usernames the policies name (`<namespace>:<name>`) | the defaults (`argocd-apps:argocd-application-controller`, `clearance-system:clearance-argocd-agent`) are wrong |

`tests/policy/test_clearance_gate.py` proves the rendered policies against a real kube-apiserver (envtest); clearance's
`providers/argocd/crd/test_admission.py` carries the full matrix. The two copies of the manifests are kept in step by hand.

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

## AWS (`--runtime eks`, the `platform` profile)

[hangar-infra](https://github.com/jfillman/hangar-infra) (Terraform) builds the accounts, networks, Infisical as its own
service and the EKS clusters; Apron onboards each cluster like any existing one. Its `docs/install.md` is the walkthrough.
What changes on EKS:

- **Runtime `eks`** (`runtimes/eks.yaml`): `apron up` runs `aws eks update-kubeconfig --alias <name>` instead of creating
  a cluster. Traefik's Service is an NLB from the AWS Load Balancer Controller (`traefik.loadBalancer`): TLS ends at
  the NLB with an ACM certificate, 443 forwards to Traefik's HTTP entrypoint, and only `sourceRanges` get in.
  `gateway.fleetRoutes` puts the hub's release relay (`relay.<domain>`) and the PaC webhook (`pac.<domain>`) on the
  gateway, since there are no shared NodePorts between VPCs. `gateway.scheme: https` makes the URLs Apron builds on
  `<service>.<domain>` (Clearance, people-dex) https.
- **Issuers**: EKS takes no API server flags, so `issuer` is the cluster's own EKS OIDC issuer (`apron check` refuses
  anything else on `eks`), and `apron identity` is refused. Tower's cluster is trusted through an EKS OIDC identity
  provider config (Terraform) with username prefix `hangar:<tower cluster>:`, so with `tower.trust: eks-oidc` the RBAC
  subjects are `hangar:<tower>:system:serviceaccount:<ns>:<sa>` (`@@TOWER_USER_*@@`). Set `tower.issuer` to Tower's
  cluster's EKS issuer.
- **Infisical off every cluster**: `infisical.host: false` everywhere and `infisical.url` set to the service. On the
  control plane, Glidepath's chart renders `platform-secret-store` with universal auth (glidepath
  `secretStore.infisical.auth`), and Apron's own consumer store stays off. Every cluster gets `provider-infisical-creds`
  planted by hand (`apron up` prints the command).
- **Profile `platform`**: upper zone, `roles: [platform-services]`, Tower (`towerAccess`) and its database, no app
  workloads, no Mongo/RabbitMQ/AI triage. With a platform cluster, prod sets `roles: [workloads]`,
  `components.towerAccess: false` and `components.towerAccessHub: true` (Tower reads it from the platform cluster).

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
| `hack/build-trust-root.sh` | the Sigstore trusted root and Fulcio chain from the cluster repo's public `signing-pki/` files ([docs/signing-pki.md](docs/signing-pki.md)) |
| `tests/run.sh` | offline tests: renders, re-render, every invariant refused |
| `apron`, `hack/apron_fleet.py`, `tests/cli/` | the CLI (`init`, `render`, `up`, `fleet`, `identity`, `verify`, `resume`, `down`) and its tests |
| `docs/` | [the fleet file](docs/clusters-file.md), [cluster identity](docs/cluster-identity.md), [the CLI](docs/cli.md), [after `apron up`](docs/after-up.md) |
