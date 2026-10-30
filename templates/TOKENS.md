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
| `@@HUB_API_SERVER@@` | `fleet.hubApiServer` - the hub's API server URL as this cluster reaches it (`observability.remoteWrite`) |
| `@@HUB_API_HOST@@` | the host part of `fleet.hubApiServer`, for the Prometheus pod's hostAliases |
| `@@HUB_CA_DATA@@` | `fleet.hubCaData` - the hub API server's CA, base64 PEM (public) |
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
| `@@RELEASE_SIGNERS@@` | `releaseSigning.signers`, a list of emails allowed to gitsign a released commit, rendered as a YAML flow list (`[]` when unset: every gitsign check fails closed until an admin fills it) - Glidepath's `releaseSigning.defaults.allowedCommitSigners` |
| `@@RELEASE_SIGNING_APPS@@` | `releaseSigning.githubMergeApps`, the apps whose GitHub-merge path is on, rendered as a YAML flow map `{<app>: {githubMerge: {enabled: true}}}` (`{}` when unset) - Glidepath's `releaseSigning.apps` |
| `@@ITSM_PROVIDER@@` | `itsm.provider` - Glidepath's change-management gate; the catalog's `itsm:` block renders only for `webhook` (optional) |
| `@@GLIDEPATH_REGISTRIES@@` | `registries.{ground,flight}.{host,namespace}`, Glidepath's Ground and Flight registries (ADR-0029), a YAML flow map; host defaults to `ghcr.io`, namespace to `""` (the GitHub owner) |
| `@@GLIDEPATH_PROMOTION@@` | `promotion.enabled` / `promotion.pinDigest` (both default `false`), Glidepath's promotion switches (ADR-0029), a YAML flow map; includes `promoter: {repo}` when `promotion.promoter.repo` is set |
| `@@GLIDEPATH_GUARDRAIL_OVERRIDES_BY_APP@@` | `releaseGuardrailOverridesByApp`, `{<app>: {<gate>: {required: false}}}`: gates that still run for that app but do not hold its release (glidepath release-guardrails.md "One app only"), a YAML flow map (`{}` when unset) |
| `@@GLIDEPATH_PROMOTER_REPO@@` | `promotion.promoter.repo`, the Flight promoter's dispatch repo (ADR-0029 phase 2; optional, the control plane's `promoter` block renders only when set) |
| `@@FLIGHT_PREFIX@@` | `registries.flight.{host,namespace}` as `<host>/<namespace>/`, the Flight images' prefix for upper-cluster admission (ADR-0029 phase 4; empty when no Flight namespace) |
| `@@FLIGHT_PROMOTER_SUBJECT_RE@@` | `promotion.promoter.repo`, as the promoter workflow's keyless identity regexp (`^https://github\.com/<repo>/\.github/workflows/promote\.yaml@refs/heads/main$`; empty when unset) |
| `@@FLIGHT_ADMISSION_ACTIONS@@` | `admission.flight.enforce`: `[Deny]`, else `[Audit, Warn]` |
| `@@FLIGHT_ADMISSION_FAILURE_POLICY@@` | `admission.flight.enforce`: `Fail`, else `Ignore` |
| `@@FLIGHT_ALLOWED_PREFIXES@@` | `admission.flight.allowedPrefixes`, third-party image prefixes tenants may run on an upper cluster, a CEL/YAML list (`[]` when unset) |
| `@@REGISTRY_PULL_KEY@@` | `admission.flight.pullFromFlight`: the Infisical key tenant `registry-credentials` reads, `flight-registry-read-dockerconfigjson` when true, else `registry-credentials-dockerconfigjson` |
| `@@ITSM_WEBHOOK_URL@@` | `itsm.webhookUrl`, the change tool's webhook (optional; the lab's mock is `http://itsm-mock.platform-system.svc.cluster.local:8080/webhook`) |
| `@@AUTOPILOT_PEOPLE@@` | `autopilot.people`, the GitHub logins that may sign in to Clearance as a person through people-dex (comma-separated; empty lets nobody in) - the gateway's `CLEARANCE_OIDC_ALLOWED_USERS` |
| `@@RELEASE_MERGERS@@` | `releaseSigning.mergers`, GitHub logins whose PR merge counts once an app turns the GitHub-merge path on (`[]` when unset) - Glidepath's `releaseSigning.defaults.githubMerge.allowedMergers` |

## Generated per cluster (cluster.yaml `generated:`)

`apron init` (hack/new_cluster.py) generates these with 20 random bytes (hex), like `openssl rand -hex 20`. They
protect ClusterIP-only databases and are committed in the cluster repo by design. Never copy them between clusters.

| Token | Value from |
|---|---|
| `@@INFISICAL_PG_PASSWORD@@`, `@@INFISICAL_REDIS_PASSWORD@@` | `generated.infisicalPgPassword` / `infisicalRedisPassword` (Infisical host) |
| `@@REKOR_MYSQL_PASSWORD@@`, `@@REKOR_MYSQL_ROOT_PASSWORD@@` | `generated.rekorMysqlPassword` / `rekorMysqlRootPassword` (Glidepath) |
