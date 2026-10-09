# The fleet's `clusters.yaml`

One record per cluster, at the root of the fleet's hub cluster repo (the cluster with the `control-plane` role;
`gitops-cluster-dev` today), next to `cluster-defaults.yaml`. Every product that needs to know about clusters reads it,
so a cluster is declared once ([Glidepath ADR-0024](https://github.com/jfillman/glidepath/blob/main/docs/admin/adr/0024-cluster-taxonomy-zone-roles-tier.md)).

| Reader | How | What it reads |
|---|---|---|
| Glidepath control plane | value file of `50-platform-cicd/platform-cicd-control-plane` | shared fields, `glidepath:` |
| Airframe cluster registry | value file of `00-bootstrap/cluster-registry` (Airframe `charts/cluster-registry`), rendering one `crossplane-system` ConfigMap per name and alias | shared fields, `airframe:` |

Each reader ignores keys it does not know, so a fleet running only Glidepath, or only Airframe, writes only the
shared fields and its product's section. Neither product reads the other's objects.

```yaml
clusters:
  - name: kind-dev                       # the cluster's identity, used everywhere (secrets projects, XRs, Tower)
    zone: lower                          # lower | upper
    roles: [control-plane, workloads]    # control-plane | workloads | platform-services
    tenantsRepo: gitops-cluster-dev-tenants
    aliases: [kiac-dev]                  # other names it answers to
    airframe: { cicdReady: true, infisicalHost: true }
  - name: kind-prod
    zone: upper
    roles: [workloads, platform-services]
    airframe: { crossplaneReady: true }
    glidepath: { relaySecretName: cluster-kind-prod-relay-token }
```

## Shared fields

- **`name`**: the cluster's identity. Choose one that will outlive the tool running the cluster: `kind-dev` runs on
  kiac now and keeps its name, because the name keys its Infisical projects, ClusterSecretStores and every
  Bootstrap XR's `devCluster`.
- **`zone`**: `upper` means nothing below it holds a write credential to it, and changes reach it only through a
  reviewed merge its own Argo CD syncs. `lower` clusters may be written to by pipelines. The control-plane cluster
  is always `lower`.
- **`roles`**: `control-plane` (the fleet's one CI/CD control plane and Bootstrap-tier Crossplane; exactly one
  cluster), `workloads` (application environments), `platform-services` (Backstage, observability).
- **`tenantsRepo`**: the cluster's tenants repo, when it is not `gitops-cluster-<name>-tenants`.
- **`aliases`**: other names the cluster answers to. Each gets its own registry ConfigMap (annotated
  `hangar.io/alias-of`).

## Product sections

- **`airframe:`** readiness flags, attested by a person after verifying the cluster live (not probed):
  `cicdReady` (the control plane runs here), `crossplaneReady` (Crossplane can compose onto it), `infisicalHost`
  (it runs the fleet's Infisical server). The Composition gates read them with `type`, which the chart derives
  from `roles` (`control-plane` -> `dev`, else `upper`).
- **`glidepath:`** `relaySecretName`, required on every record except the control plane's own: the Secret holding
  the token that cluster's notifications present to the release relay.

## Adding a cluster

`hack/customize-cluster.sh` prints the record for a new cluster. Add it to the hub's `clusters.yaml` in a PR, then
sync the hub's `cluster-registry` Application (manual by design) and let the control plane sync.

Move values between files in two steps when an Argo CD Application's own spec changes in the same change: add the new
value file first, remove the old values after it is live. Done in one commit (2026-10-08), the child Application
synced the new values with its old spec for ~10 minutes, emptying the Glidepath registry until the next sync.
