# Clearance Map: the target registry and the attestation trust

Two things the Clearance 0.45.0 server needs from the cluster repo, both rendered from `cluster.yaml`:

1. **The target registry** (the Map's "what should be protected"): each cluster declares its protected targets and the core
   publishes nothing on its own. A publisher per cluster sends the set to the core.
2. **The attestation trust** (`api.attest.*`): the public material `clearance-api` verifies stored attestations with, so
   `GET /v1/attestation-config` answers `verifiable: true`.

Neither changes a cluster that sets neither key.

## The target registry publisher

Off by default. Turn it on in `cluster.yaml`:

```yaml
clearance:
  targets:
    enabled: true
    # On the cluster that runs the core only: the other clusters whose publishers it registers (Tower's cluster: the core
    # trusts another cluster's service-account tokens for clearance.foreignCluster, which is tower.cluster).
    publishers:
      - {cluster: hangar-prod}
    owner: group:default/admins                 # default owner of a target (default clearance.gateOwnerFallback)
    owners: {gate-api: group:default/team-gate}   # by app
    schedule: "*/15 * * * *"                    # default
    registry: flight                            # default flight on an upper cluster that has registries.flight, else ground
    argoInstance: argocd-agent                  # the g-argo gate's instance (default argocd-agent)
    extra: []                                   # hand-declared targets, validated like the core does
```

### What is declared

`hack/render.py` (`clearance_targets_tokens`) derives the set from what the renderer already knows. The cluster name is the
source and the scope of its namespaces. One target per:

| Target | From | Fields |
|---|---|---|
| a protected namespace (`k8s-namespace`) | the union of `clearance.observe.protectedNamespaces` and `clearance.gate.agent.protectedNamespaces` | `id` `<cluster>.<namespace>`, `name` the namespace, `group` and `scope` the cluster, `registry` ground/flight, observers `observe-k8s` when the audit collector watches it |
| an application namespace `app-<app>-<env>` (the above, by name) | the namespace name | adds `app`, `env`, `owner` and the gates below |
| the AWS account the collector watches (`aws-account`) | `clearance.observeAWS.*` | `id` `aws.<account>`, `group` and `scope` the account (from `cluster.yaml`, never a template), `env` the collector's environment, observer `observe-aws`, gates from `clearance.observeAWS.gates` |
| anything else | `clearance.targets.extra` | as written |

Gates (only on an application namespace, because the core attributes a gate's records to a target by the record's `app` and
`env`):

| Gate | Declared when | `instance` | `mode` |
|---|---|---|---|
| `glidepath` | always (the Glidepath `clearance-gate` check) | `app-<app>-cicd/pipeline-runner` | `enforce` where `<cluster>/<env>` matches `clearance.protectedEnvironments`, else `flag` (tier 0: recorded, not refused); an unset `protectedEnvironments` protects every environment (the core fails closed), so `enforce` |
| `g-argo` | `clearance.gate.enabled` and the namespace is one the agent protects (or, without an agent, the app is in `clearance.gate.apps`) | `argocd-agent` | `enforce` with `clearance.gate.enforce`, else `flag` |

**Why the instances attribute.** The Map counts a record for a gate instance when the record's `provider.name` is the
instance, or the change the record names was registered by it (`registered_by`, the principal that registered the change)
(`internal/api/map.go`, `byInst`). Glidepath's `clearance-gate` check registers each change as the pipeline-runner of the app's
`-cicd` namespace, which is the core's `CLEARANCE_VERIFIERS` entry `app-*-cicd/pipeline-runner`, so that principal is the
`registered_by` and the gate's instance. The Argo CD agent's outcomes and exceptions are written by the registered provider
`argocd-agent` (`provider.name`). A declared instance no record names is shown `silent`: declare only what the core
attributes. Two things stay in `cluster.yaml` because the renderer cannot know the principal: the G-TF gate's instance
(`clearance.observeAWS.gates`: hangar-infra's workflow registers the plan as `github:repo:<owner>/hangar-infra:ref:refs/heads/main`)
and any GitHub Actions deployment-protection target (`extra`).

### The mechanism

`59-clearance-targets/` (rendered with `clearance.targets.enabled`): a ConfigMap holding the rendered `targets.json` and
`publish.py` (standard library), a CronJob (every 15 minutes, `concurrencyPolicy: Forbid`) running it, a ServiceAccount
`clearance-targets` and two NetworkPolicies (a remote core needs `clearance.gate.hostAlias`: the egress is pinned to that address, and the render refuses without it) (DNS; the core and nothing else). The Job calls `PUT /v1/targets/<cluster>` with
its projected service-account token (audience `clearance`, minted per run, never stored). The core replaces only that
source's set and answers `changed: false`, recording nothing, when it already holds it: a timer is safe, and a re-rendered set
is picked up by the next run. A timer also makes a restarted core or a missed publish self-heal.

On the core's cluster the render registers each publisher in `CLEARANCE_PROVIDERS` as `targets-<cluster>` with
`targets: ["<cluster>"]` (the right to publish that source only), principal `clearance-system/clearance-targets` for its own
and `<cluster>/clearance-system/clearance-targets` for a remote one (whose account is added to
`foreignCluster.serviceAccounts`), and admits the local Job in the core's NetworkPolicy. The entry carries `"kinds": []`,
which grants no record kinds (Clearance 0.46.0+; an ABSENT `kinds` would mean every record kind but the observations), so a
publisher can publish its own source's targets and write nothing else.

## The attestation trust (`api.attest.*`)

Rendered where the core runs, with `clearance.attestation.keyless` and `signing.trustedRoot` (docs/signing-pki.md): the core
signs keyless, so the public trust is the cluster's trusted root, `signing-pki/trusted-root.json`, in the ConfigMap
`clearance-attest-trust` (`55-clearance/clearance-config/attest-trust.yaml`; the api mounts it read-only at
`/etc/clearance/attest-trust`), plus the two values the certificate must name: `identity`
`https://kubernetes.io/namespaces/<clearance namespace>/serviceaccounts/clearance-core` and `issuer` the cluster's issuer
(`clearance.attestation.issuer` overrides it where the cluster signs under another one). `rekorUrl` is Rekor's public URL,
`<scheme>://rekor.<domain>` (`clearance.attestation.rekorPublicUrl` overrides it), for "open in Rekor" links.

Only public material is rendered; the render refuses a private key anywhere in `signing-pki/`. Attestations signed while the
core ran in `autopilot-system` name that service account and do not verify against this identity (the api takes one). A
cluster that signs with a static key has no public key in this repo: it needs the key's public half in a ConfigMap and
`api.attest.key`, which the owner supplies.
