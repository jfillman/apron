# Lab-only networking

Some name and address plumbing exists only because of the local lab: kiac on Apple `container`, kind on podman, LAN relays,
ssh forwards, and `*.local` names that are in no DNS. None of it belongs on EKS or any other real deployment target, where
names are real DNS and endpoints are routable. Apron has one switch for this, derived from the runtime:

| Runtime | `runtime.labNetworking` |
|---|---|
| `kiac`, `kind` | `true` |
| `eks`, `existing`, anything else | `false` |

An `existing` cluster that really is a lab (a hand-built kind or minikube) can say so in its `cluster.yaml`:
`runtime: {type: existing, labNetworking: true}`. Nothing else turns it on.

## What is gated

When `runtime.labNetworking` is not `true`:

| Key | Lab use | Off a lab |
|---|---|---|
| `tower.hostAliasIP` | pins Tower's hostname for Glidepath's Tekton pods, the Autopilot gateway and API, and the Clearance core and API | refused by `apron check`; never rendered |
| `fleet.hubAddress` | pins the hub's hostnames for Backstage, External Secrets, the Infisical provider and Prometheus | refused; never rendered |
| `clearance.gate.hostAlias` | the core's address for Argo CD's repo-server, the agent, the wait Job, the collectors and the target publisher (and the egress pinned to it) | refused; never rendered |
| `clearance.ledger.hostAlias` | the witness's address for the core, and its egress pin | refused; never rendered |
| `<name>.local` defaults | `domain`, `fleet.hubDomain`, `tower.domain` (and so `tower.baseUrl`) default to `<name>.local` | no default: `domain` and, with `tower.cluster`, `tower.domain` are required; a `.local` value for `domain`, `fleet.hubDomain`, `tower.domain`, `tower.baseUrl`, `fleet.relayUrl` or `infisical.url` is refused |
| Backstage `hostAliases` (`65-backstage/backstage/deployment.yaml`) | the hub's gateway names through the LAN forward | not rendered |

There are three layers, so a mistake in one does not leak lab plumbing into a real cluster:

1. `hack/check.py` refuses each key above on a non-lab runtime, by name.
2. `hack/render.py` reads those keys as unset on a non-lab runtime, even with `--no-check`.
3. The templates that render a `hostAliases` test `runtime.labNetworking` in their `#@if` as well as the knob.

`tests/run.sh` section 3a renders EKS clusters and asserts there is no `hostAliases` entry, `.local` host or RFC1918 literal in
any file, that each knob is refused, and that it still renders nothing when the check is bypassed. The lab clusters render
byte-for-byte as before.

## Not gated

Kubernetes API names that mention `hostAliases` are not lab plumbing and stay: CRD schemas (`argo-rollouts/install.yaml`,
`rabbitmq-operators`) and the admission policies that let a pod template set `hostAliases` only. The Clearance and Glidepath
charts take `hostAliases` as an empty-by-default value; Apron is what fills it, and now only on a lab.
