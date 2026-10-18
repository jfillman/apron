# Template tokens

Every `@@TOKEN@@` in `templates/` and where its value comes from. `hack/render.py` (`tokens()`) is the
authority; `tests/run.sh` fails if a token is used in a template but missing here, or listed here but unknown to
render.py. Values resolve from `cluster.yaml` over `profiles/<profile>.yaml`, `runtimes/<runtime>.yaml` and
`versions.yaml`; "derived" values follow from the cluster's name (the one-name rule) unless set explicitly.

An unknown token, a token with no value for the cluster (except the two marked optional), or a leftover `@@` stops
the render with `file:line`.

## Identity (one name)

| Token | Value from |
|---|---|
| `@@CLUSTER_NAME@@` | `name` - also the kubectl context, the fleet record, the Infisical stem (`<app>-<name>`, `glidepath-<name>`) |
| `@@CLUSTER_DOMAIN@@` | `domain`, derived `<name>.local` - hostname stem (`argocd.<domain>`) |
| `@@ISSUER@@` | `issuer`, derived `https://<issuerBase>/oidc/<name>` (`issuerBase` default `hangarplatform.dev`) |
| `@@REPO_URL@@` | `repoURL` - this cluster's GitOps repo (required, `apron init --repo-url`) |
| `@@TENANTS_REPO_URL@@` | `tenantsRepo`, derived `<repo name>-tenants` under `scm` |
| `@@TENANTS_REPO_NAME@@` | the tenants repo's bare name (prose in an AppProject description) |

## SCM and registry (no default owner)

| Token | Value from |
|---|---|
| `@@SCM_HOST@@` | `scm.host`, default `github.com` |
| `@@SCM_HOST_RE@@` | `scm.host`, regex-escaped (Kyverno image-signature subject) |
| `@@SCM_OWNER@@` | `scm.owner` - required (`--scm-owner`) |
| `@@REGISTRY_HOST@@` | `registry.host`, default `ghcr.io` |
| `@@REGISTRY_OWNER@@` | `registry.owner`, default `scm.owner` |

## Fleet (the hub is the control-plane cluster)

| Token | Value from |
|---|---|
| `@@FLEET_REPO_URL@@` | `fleet.repoURL` - the hub's repo, whose `clusters.yaml` the cluster-registry reads; on the hub, its own `repoURL` |
| `@@HUB_NAME@@` | `fleet.hub` - the control-plane cluster's name (only the reference-only `65-backstage` uses it) |
| `@@HUB_DOMAIN@@` | `fleet.hubDomain`, derived `<fleet.hub>.local` |
| `@@HUB_ADDRESS@@` | `fleet.hubAddress` - an IP for hostAliases when pods can't resolve `<hub domain>` (lab only; empty = no alias) |
| `@@RELAY_URL@@` | `fleet.relayUrl`, derived `http://<hubAddress or hubDomain>:30880` (Glidepath's release relay NodePort) |
| `@@INFISICAL_URL@@` | `infisical.url`, derived `http://<hub domain>:<infisical.nodePort>/api` on consumers |
| `@@INFISICAL_NODEPORT@@` | `infisical.nodePort` (versions.yaml, 31800) |

## Tower (Backstage as an Airframe app)

| Token | Value from |
|---|---|
| `@@TOWER_CLUSTER@@` | `tower.cluster` - the cluster Tower runs on (`apron init --tower-cluster` on the hub) |
| `@@TOWER_ISSUER@@` | `tower.issuer`, derived `https://<issuerBase>/oidc/<tower.cluster>` |
| `@@TOWER_NAMESPACE@@` | `tower.namespace`, derived `app-backstage-<tower.env>` (Airframe's `app-<app>-<env>`; env default `prod`) |
| `@@TOWER_BASE_URL@@` | `tower.baseUrl`, derived `http://backstage.<tower.cluster>.local` (optional) |
| `@@TOWER_HOST_ALIAS_IP@@` | `tower.hostAliasIP` - only when pods can't resolve Tower's hostname (optional, empty by default) |

## Gateway (Traefik, every runtime)

| Token | Value from |
|---|---|
| `@@GATEWAY_NAMESPACE@@` | `gateway.namespace`, default `hangar-gateway` |
| `@@GATEWAY_NAME@@` | `gateway.name`, default `hangar` |
| `@@TRAEFIK_SERVICE_TYPE@@` | `traefik.serviceType` - runtime: NodePort (kiac, kind), LoadBalancer (existing) |
| `@@TRAEFIK_HTTP_NODEPORT@@` / `@@TRAEFIK_HTTPS_NODEPORT@@` | `traefik.httpNodePort` / `httpsNodePort` (runtime; used only with `traefik.fixedNodePorts`) |

## Runtime (kind only)

| Token | Value from |
|---|---|
| `@@CALICO_VERSION@@` | `runtime.cni.version` (runtimes/kind.yaml, v3.29.1) |
| `@@KIND_POD_SUBNET@@`, `@@KIND_MAX_PODS@@` | `runtime.kind.podSubnet`, `runtime.kind.maxPods` |
| `@@KIND_HOST_HTTP_PORT@@`, `@@KIND_HOST_HTTPS_PORT@@` | `runtime.kind.hostHttpPort` / `hostHttpsPort` (80/443) |

## Versions (versions.yaml)

| Token | Value from |
|---|---|
| `@@AIRFRAME_CATALOG_VERSION@@` | `versions.airframe.catalog` |
| `@@AIRFRAME_REGISTRY_VERSION@@` | `versions.airframe.clusterRegistry` |
| `@@AIRFRAME_ANALYSIS_VERSION@@` | `versions.airframe.analysisCatalog` |
| `@@AIRFRAME_CHART_VERSION@@` | `versions.airframe.defaultChart` (cluster-defaults.yaml) |
| `@@GLIDEPATH_VERSION@@` | `versions.glidepath` |
| `@@ARGOCD_CHART_VERSION@@` | `versions.argocdChart` (the second Argo CD instance) |
| `@@INFISICAL_BOOTSTRAP_IMAGE_TAG@@` | `infisical.bootstrapImageTag` |

## Profile sizing

| Token | Value from |
|---|---|
| `@@CNPG_REPLICAS@@` | `cnpg.replicas` (dev 2, prod 1) |
| `@@OBSERVABILITY_FULL@@` | `observability.full` (dev true, prod false) |
| `@@AI_TRIAGE_CPU_REQUEST@@`, `@@AI_TRIAGE_MEMORY_REQUEST@@`, `@@AI_TRIAGE_MEMORY_LIMIT@@` | `aiTriage.*` |
| `@@XR_NAMESPACE_SUFFIX@@` | derived: `cicd` on the control plane, `xrs` elsewhere (xr-requests target namespaces) |
| `@@XR_APP_NAMESPACE@@` | derived: `argocd` on the control plane, `argocd-apps` elsewhere |
| `@@AWS_ACCOUNT_ID@@` | `aws.accountId` (only with `components.cloudTargets`) |

## Generated per cluster (cluster.yaml `generated:`)

`apron init` (hack/new_cluster.py) generates these with 20 random bytes (hex), like `openssl rand -hex 20`. They
protect ClusterIP-only databases and are committed in the cluster repo by design. Never copy them between clusters.

| Token | Value from |
|---|---|
| `@@INFISICAL_PG_PASSWORD@@`, `@@INFISICAL_REDIS_PASSWORD@@` | `generated.infisicalPgPassword` / `infisicalRedisPassword` (Infisical host) |
| `@@REKOR_MYSQL_PASSWORD@@`, `@@REKOR_MYSQL_ROOT_PASSWORD@@` | `generated.rekorMysqlPassword` / `rekorMysqlRootPassword` (Glidepath) |
