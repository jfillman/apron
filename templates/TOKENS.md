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
| `@@TOWER_USER_INGESTOR@@`, `@@TOWER_USER_ACTOR@@` | the Kubernetes user Tower's `backstage-ingestor` / `tower-actor` become here: `hangar:<tower.cluster>:<sa>` (`tower.trust` structured, kubeadm's JWT authenticator), or `hangar:<tower.cluster>:system:serviceaccount:<tower.namespace>:<sa>` (`tower.trust: eks-oidc`, an EKS OIDC identity provider config with username prefix `hangar:<tower.cluster>:`) |
| `@@TOWER_USER_PROMETHEUS@@` | the same for Tower's cluster's `observability/kube-prometheus-stack-prometheus` (Thanos Receive) |

## Gateway (Traefik, every runtime)

| Token | Value from |
|---|---|
| `@@GATEWAY_NAMESPACE@@` | `gateway.namespace`, default `hangar-gateway` |
| `@@GATEWAY_NAME@@` | `gateway.name`, default `hangar` |
| `@@GATEWAY_SCHEME@@` | `gateway.scheme`, default `http` (runtime eks: `https`, TLS at the NLB) - URLs built on `<service>.<domain>` (Clearance, people-dex) |
| `@@TRAEFIK_SERVICE_TYPE@@` | `traefik.serviceType` - runtime: NodePort (kiac, kind), LoadBalancer (existing) |
| `@@TRAEFIK_HTTP_NODEPORT@@` / `@@TRAEFIK_HTTPS_NODEPORT@@` | `traefik.httpNodePort` / `httpsNodePort` (runtime; used only with `traefik.fixedNodePorts`) |
| `@@TRAEFIK_LB_CLASS@@` | `traefik.loadBalancer.class` - the Service's `loadBalancerClass` (runtime eks: `service.k8s.aws/nlb`) |
| `@@TRAEFIK_LB_SCHEME@@` | `traefik.loadBalancer.scheme`, default `internet-facing` |
| `@@TRAEFIK_LB_CERT_ARN@@` | `traefik.loadBalancer.certificateArn` - ACM certificate; TLS ends at the NLB and 443 forwards to Traefik's `web` entrypoint |
| `@@TRAEFIK_LB_SOURCE_RANGES@@` | `traefik.loadBalancer.sourceRanges`, a YAML flow list - the Service's `loadBalancerSourceRanges` |

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
| `@@PAC_APPLICATION_NAME@@` | `pipelinesAsCode.applicationName` (default `Glidepath`), quoted: Pipelines-as-Code's `application-name`, the first half of every check run's name (`Glidepath / sast-`). Set in PaC's ConfigMap and the glidepath-catalog's `pipelinesAsCode.applicationName` together, which must match (glidepath docs/admin/github-app.md). Not the GitHub App's name |
| `@@GLIDEPATH_PROMOTER_REPO@@` | `promotion.promoter.repo`, the Flight promoter's dispatch repo (ADR-0029 phase 2; optional, the control plane's `promoter` block renders only when set) |
| `@@FLIGHT_PREFIX@@` | `registries.flight.{host,namespace}` as `<host>/<namespace>/`, the Flight images' prefix for upper-cluster admission (ADR-0029 phase 4; empty when no Flight namespace) |
| `@@FLIGHT_PROMOTER_SUBJECT_RE@@` | `promotion.promoter.repo`, as the promoter workflow's keyless identity regexp (`^https://github\.com/<repo>/\.github/workflows/promote\.yaml@refs/heads/main$`; empty when unset) |
| `@@FLIGHT_ADMISSION_ACTIONS@@` | `admission.flight.enforce`: `[Deny]`, else `[Audit, Warn]` |
| `@@FLIGHT_ADMISSION_FAILURE_POLICY@@` | `admission.flight.enforce`: `Fail`, else `Ignore` |
| `@@FLIGHT_ALLOWED_PREFIXES@@` | `admission.flight.allowedPrefixes`, third-party image prefixes tenants may run on an upper cluster, a CEL/YAML list (`[]` when unset) |
| `@@CLEARANCE_GATE_ACTIONS@@` | `clearance.gate.enforce`: `[Deny, Audit]`, else `[Warn, Audit]` (both bindings of `56-clearance-gate`) |
| `@@CLEARANCE_GATE_PARAM_NOT_FOUND@@` | `clearance.gate.enforce`: `Deny`, else `Allow` (the `parameterNotFoundAction`; the flip changes this and the actions together) |
| `@@CLEARANCE_GATE_ARGOCD_USER@@` | `system:serviceaccount:` + `clearance.gate.argocdServiceAccount` (default `argocd-apps:argocd-application-controller`), the only writer `clearance-protected-writes` checks |
| `@@CLEARANCE_GATE_AGENT_USER@@` | `system:serviceaccount:` + `clearance.gate.agentServiceAccount` (default `clearance-system:clearance-argocd-agent`), the only writer of a ClearanceGrant |
| `@@CLEARANCE_GATE_WAIT_IMAGE@@` | `versions.clearance.waitImage` (the same digest the CMP injects), the one image `clearance-protected-writes` exempts as the injected PreSync Job, and the agent's `waitJob.image` so its exception scan recognises the same Job; required with `clearance.gate.enabled` |
| `@@REGISTRY_PULL_KEY@@` | `admission.flight.pullFromFlight`: the Infisical key tenant `registry-credentials` reads, `flight-registry-read-dockerconfigjson` when true, else `registry-credentials-dockerconfigjson` |
| `@@ITSM_WEBHOOK_URL@@` | `itsm.webhookUrl`, the change tool's webhook (optional; the lab's mock is `http://itsm-mock.platform-system.svc.cluster.local:8080/webhook`) |
| `@@AUTOPILOT_PEOPLE@@` | `autopilot.people`, the GitHub logins that may sign in to Clearance as a person through people-dex (comma-separated; empty lets nobody in) - the gateway's `CLEARANCE_OIDC_ALLOWED_USERS` |
| `@@AUTOPILOT_CUSTOM_IMAGES@@` | `autopilot.customImages`, globs a definition's `runtime.image` may match beyond the runtime catalog (custom images built for an agent's own repo, e.g. `ghcr.io/jfillman/*@sha256:*`); comma-separated; rendered only when set - `RUNTIME_IMAGES_EXTRA` on the gateway and its read API |
| `@@AUTOPILOT_PEOPLE_PRINCIPALS@@` | the same people as Clearance principals (`user:<login>`, comma-separated): the gateway read API's auditors (`GATEWAY_API_AUDITORS`) |
| `@@RELEASE_MERGERS@@` | `releaseSigning.mergers`, GitHub logins whose PR merge counts once an app turns the GitHub-merge path on (`[]` when unset) - Glidepath's `releaseSigning.defaults.githubMerge.allowedMergers` |

## Clearance (55-clearance, cluster.yaml `clearance:`; each key falls back to the `autopilot:` key it replaced)

| Token | Value from |
|---|---|
| `@@CLEARANCE_CHART_VERSION@@` | `versions.clearance.chart`, the clearance chart's version (OCI, `<registry>/<owner>/charts/clearance`) |
| `@@CLEARANCE_IMAGE_DIGEST@@` | `versions.clearance.imageDigest`, the image index the chart's default tag is pinned to |
| `@@CLEARANCE_NAMESPACE@@` | `clearance.namespace`, default `clearance-system` (hangar-dev: `autopilot-system`, where clearance-pg lives) |
| `@@CLEARANCE_PROVIDERS@@` | the registered runtime provider, the Autopilot gateway (`autopilot-system/clearance`, version `versions.autopilot.gateway`, `"definitions": true`), a YAML flow list |
| `@@CLEARANCE_VERIFIERS_LIST@@` | `app-*-cicd/pipeline-runner` (Glidepath's gate checks), `github:<glob>` for each `clearance.githubWorkflows` entry, and `clearance.verifiers` |
| `@@CLEARANCE_DELEGATES_LIST@@` | Tower's backend (`<tower.cluster>/<tower.namespace>/backstage-ingestor`) when `tower.cluster` is set, plus `clearance.delegates` |
| `@@CLEARANCE_NOTIFIERS_LIST@@` | the same Tower backend plus `clearance.notifiers`: clearance-api's notifiers |
| `@@CLEARANCE_PEOPLE_LIST@@` | `clearance.people` (else `autopilot.people`): people-dex logins the core and clearance-api accept |
| `@@CLEARANCE_ADMINS_LIST@@` | `clearance.admins` (else the people) as `user:<login>`: who may deny any held change and open break-glass windows |
| `@@CLEARANCE_PROTECTED_ENVIRONMENTS_LIST@@` | `clearance.protectedEnvironments`, `<cluster glob>/<env glob>` entries the gate protects (D30); any other environment clears at tier 0. Empty (the default): every environment is protected |
| `@@CLEARANCE_GATE_RELEASE_STAMPS_LIST@@` | `clearance.gateReleaseStamps` (default: the Airframe chart's version label on the object and its pod template, and the `hangar.io/release-id` annotation): the JSON pointers a release stamps, which the gate does not count as changes |
| `@@CLEARANCE_GATE_OUTSIDE_GROUPS_LIST@@` | `clearance.gateOutsideGroups` (default `["group:default/admins"]`): the groups whose members count as the outside approver a tier-3 change needs (one from the owner group, one from these; never the proposer, never one person twice) |
| `@@CLEARANCE_AUDITORS_LIST@@` | `clearance.auditors` (else the people) as `user:<login>`, then `clearance.extraAuditors` verbatim (principal globs such as `clearance-system/clearance-observe-aws`): clearance-api's auditors |
| `@@CLEARANCE_GITHUB_WORKFLOWS_LIST@@` | `clearance.githubWorkflows` (else `autopilot.githubWorkflows`): globs on a GitHub Actions OIDC token's `sub` that may `clearance register` |
| `@@CLEARANCE_RUNTIME_IMAGES_LIST@@` | `autopilot.customImages`, as the gate's `runtimeImagesExtra` |
| `@@CLEARANCE_TRUSTED_REGISTRIES_LIST@@` | `clearance.trustedRegistries`, default `[<registries.flight.host>/<registries.flight.namespace>/]` (decided 2026-11-03): an image bump from them is tier 1, from anywhere else tier 2; each ends in `/` |
| `@@CLEARANCE_GATE_ENV_REGEX@@` | the environments the Argo CD gate covers, from `clearance.protectedEnvironments` (`<cluster glob>/<env glob>`; empty: every environment), as one regex over `<cluster>/<env>` with no backslashes (`render.py` `_glob_regex`) - only under `#@if clearance.gate.enabled` |
| `@@CLEARANCE_GATE_APP_REGEX@@` | `clearance.gate.apps` as one regex over the app name; empty: every app |
| `@@CLEARANCE_GATE_HOST_ALIASES@@` | `clearance.gate.hostAlias` as the chart's `hostAliases` list (argocd-apps' `global.hostAliases`) |
| `@@CLEARANCE_FOREIGN_SERVICE_ACCOUNTS_LIST@@` | Tower's backend and `clearance.foreignServiceAccounts`: the other cluster's `<namespace>/<sa>` globs the core and clearance-api accept |
| `@@CLEARANCE_FEED_READERS_LIST@@` | `clearance.feedReaders`: `{principal, cluster}` entries that read a cluster's grant feed |
| `@@CLEARANCE_AGENT_CHART_VERSION@@`, `@@CLEARANCE_AGENT_IMAGE_REPOSITORY@@`, `@@CLEARANCE_AGENT_IMAGE_TAG@@` | `versions.clearance.argocdAgentChart` and `argocdAgentImage`, the digest carried in the tag |
| `@@CLEARANCE_AGENT_API_URL@@`, `@@CLEARANCE_AGENT_PROJECTS@@`, `@@CLEARANCE_AGENT_PROTECTED_NAMESPACES@@`, `@@CLEARANCE_AGENT_HOST_ALIASES@@` | `clearance.gate.agent` and `clearance.gate.hostAlias` plus clearance-api's host |
| `@@CLEARANCE_GATE_URL@@` | `clearance.gate.url`, default `http://clearance-core.<clearance namespace>.svc:8080`: the core as the plugin sidecar and the PreSync wait Job reach it |
| `@@CLEARANCE_GATE_HOST_ALIAS@@` | `clearance.gate.hostAlias` (`ip=host[,host]`, may be empty): a hostAlias for the wait Job's pod when the core is on another cluster (hangar-prod to hangar-dev) |
| `@@CLEARANCE_CMP_IMAGE@@` | `versions.clearance.cmpImage`: the plugin sidecar image (`clearance-cmp`, by digest); required with `clearance.gate.enabled` |
| `@@CLEARANCE_WAIT_IMAGE@@` | `versions.clearance.waitImage`: the PreSync wait Job's image (`clearance-wait`, by digest); required with `clearance.gate.enabled` |
| `@@CLEARANCE_LEDGER_KEY_SECRET@@` | `clearance.ledger.keySecret`, default `hangar-ledger-<cluster name>-key`: the Infisical secret holding the log's signing key (private; the owner puts it there) - only under `#@if clearance.ledger.enabled` |
| `@@CLEARANCE_LEDGER_WITNESS_POLICY@@` | `clearance.ledger.witnesses` (`{name, vkey, url}`; the vkey is the witness's cosignature key, type 0x04, checked) as the chart's `ledger.witnessPolicy`, a JSON string: a `witness <name> <vkey> <url>` line each, then `quorum <name>` (one witness) or `group witnesses <clearance.ledger.quorum, default all> <names>` and `quorum witnesses` |
| `@@CLEARANCE_LEDGER_RETIRED_KEYS@@` | `clearance.ledger.retiredKeys` (log vkeys of keys rotated out), one per line as a JSON string; `""` when none |
| `@@CLEARANCE_LEDGER_EGRESS@@` | the core's egress to the witnesses (`ledger.egress`): their port(s), and the `/32` of `clearance.ledger.hostAlias`'s address when set |
| `@@CLEARANCE_LEDGER_HOST_ALIASES@@` | `clearance.ledger.hostAlias` (`ip=host[,host]`) as the core's `hostAliases` list, used when the cluster has no `tower.hostAliasIP` |
| `@@CLEARANCE_LEDGER_TOWER_HOSTNAMES_MORE@@` | The witness's hostnames when `clearance.ledger.hostAlias` has Tower's address: Kubernetes merges hostAliases by ip, so they join Tower's entry instead of adding one |
| `@@CLEARANCE_LEDGER_HOST_ALIASES_MORE@@` | the same entry as `, {...}` appended to the core's Tower host alias; empty (optional) unless the ledger is on with a hostAlias, so a cluster without the ledger renders what it did before |
| `@@CLEARANCE_LEDGER_CHECKPOINT_INTERVAL@@`, `@@CLEARANCE_LEDGER_STALL_AFTER@@` | `clearance.ledger.checkpointInterval`, `stallAfter` (Go durations; each line renders only when set) |
| `@@CLEARANCE_LEDGER_TIER3_WAIT@@` | `clearance.ledger.tier3Wait`, default `true`: a tier 3 change waits while evidence cannot be checkpointed |
| `@@CLEARANCE_LEDGER_STORAGE_SIZE@@`, `@@CLEARANCE_LEDGER_STORAGE_CLASS@@` | `clearance.ledger.storage.size` (default `1Gi`) and `storageClass` (line renders only when set): the log's ReadWriteOnce volume |
| `@@CLEARANCE_OBSERVE_CHART_VERSION@@`, `@@CLEARANCE_OBSERVE_IMAGE_REPOSITORY@@`, `@@CLEARANCE_OBSERVE_IMAGE_TAG@@` | `versions.clearance.observeK8sChart` and `observeK8sImage` (by digest; the digest pin goes in the tag) - only under `clearance.observe.enabled` |
| `@@CLEARANCE_OBSERVE_PROTECTED_NAMESPACES@@`, `@@CLEARANCE_OBSERVE_SERVICE_IP@@` | `clearance.observe.protectedNamespaces` and `serviceIP` (checked when on) |
| `@@CLEARANCE_OBSERVE_KUBELET_NODES@@` | `clearance.observe.kubeletNodes`, a JSON list; empty when unset |
| `@@CLEARANCE_OBSERVE_ARGOCD_NAMESPACE@@`, `@@CLEARANCE_OBSERVE_ARGO_SUBJECT@@` | `clearance.observe.argocdNamespace`, default `argocd` on the control plane and `argocd-apps` elsewhere, and its application controller's subject |
| `@@CLEARANCE_OBSERVE_AWS_CHART_VERSION@@`, `@@CLEARANCE_OBSERVE_AWS_IMAGE_REPOSITORY@@`, `@@CLEARANCE_OBSERVE_AWS_IMAGE_TAG@@` | `versions.clearance.observeAWSChart` and `observeAWSImage` (by digest; the digest pin goes in the tag) - only under `clearance.observeAWS.enabled` |
| `@@CLEARANCE_OBSERVE_AWS_ACCOUNT@@`, `@@CLEARANCE_OBSERVE_AWS_REGION@@` (default `us-east-1`), `@@CLEARANCE_OBSERVE_AWS_QUEUE_URL@@`, `@@CLEARANCE_OBSERVE_AWS_ENVIRONMENT@@`, `@@CLEARANCE_OBSERVE_AWS_ROLE_ARN@@`, `@@CLEARANCE_OBSERVE_AWS_TRAIL_ROLE_ARN@@` | `clearance.observeAWS.account`, `region`, `queueURL`, `environment`, `roleARN`, `trailRoleARN`, as JSON strings; `account`, `queueURL`, `roleARN` and `applyRoles` are checked when on |
| `@@CLEARANCE_OBSERVE_AWS_TRAIL_NAME@@` (default `organization`), `@@CLEARANCE_OBSERVE_AWS_TRAIL_BUCKET@@`, `@@CLEARANCE_OBSERVE_AWS_TRAIL_PREFIX@@`, `@@CLEARANCE_OBSERVE_AWS_TRAIL_REGION@@` (default `us-east-1`), `@@CLEARANCE_OBSERVE_AWS_TRAIL_REGIONS@@` (default `[us-east-1]`) | `clearance.observeAWS.trail.name`, `bucket`, `prefix`, `region`, `regions` |
| `@@CLEARANCE_OBSERVE_AWS_DATA_BUCKETS@@`, `@@CLEARANCE_OBSERVE_AWS_RULES@@` (default `[observe-aws-cloudtrail, observe-aws-config]`), `@@CLEARANCE_OBSERVE_AWS_APPLY_ROLES@@`, `@@CLEARANCE_OBSERVE_AWS_SSO_ADMIN_ROLES@@`, `@@CLEARANCE_OBSERVE_AWS_GOVERNED_ACCOUNTS@@` | `clearance.observeAWS.dataBuckets`, `rules`, `applyRoles`, `ssoAdminRoles`, `governedAccounts`, JSON lists |
| `@@CLEARANCE_WITNESS_NAME@@` | `clearance.witness.name`: the name the log's operator lists this witness under (an annotation on the Deployment) - only under `#@if clearance.witness.enabled` (the directory) |
| `@@CLEARANCE_WITNESS_KEY_SECRET@@` | `clearance.witness.keySecret`, default `hangar-witness-<cluster name>-key`: the Infisical secret holding the witness's signing key (private) |
| `@@CLEARANCE_WITNESS_IMAGE@@` | `versions.clearance.witnessImage`: `clearance-witness` by digest; required with `clearance.witness.enabled`, and added exactly to Flight admission's allowed images |
| `@@CLEARANCE_WITNESS_HOST@@` | `clearance.witness.host`, default `witness.<domain>`: the route the log's core reaches (through its hostAlias) |
| `@@CLEARANCE_WITNESS_LOGS@@` | `clearance.witness.logsVkeys` (log verifier keys, type 0x01, checked): the witness's `--logs-file`, one per line, as a JSON string |
| `@@CLEARANCE_WITNESS_STORAGE_SIZE@@`, `@@CLEARANCE_WITNESS_STORAGE_CLASS@@` | `clearance.witness.storage.size` (default `64Mi`) and `storageClass` (line renders only when set): the witness's state claim |
| `@@CLEARANCE_GITHUB_APP_ID@@` | `clearance.githubAppId`, the Clearance GitHub App's id (public; optional, used with `clearance.githubApp`) |

## Generated per cluster (cluster.yaml `generated:`)

`apron init` (hack/new_cluster.py) generates these with 20 random bytes (hex), like `openssl rand -hex 20`. They
protect ClusterIP-only databases and are committed in the cluster repo by design. Never copy them between clusters.

| Token | Value from |
|---|---|
| `@@INFISICAL_PG_PASSWORD@@`, `@@INFISICAL_REDIS_PASSWORD@@` | `generated.infisicalPgPassword` / `infisicalRedisPassword` (Infisical host) |
| `@@REKOR_MYSQL_PASSWORD@@`, `@@REKOR_MYSQL_ROOT_PASSWORD@@` | `generated.rekorMysqlPassword` / `rekorMysqlRootPassword` (Glidepath) |

## Signing PKI (C-2a, off by default)

| Token | Value from |
|---|---|
| `@@SIGNING_FULCIO_CHAIN@@` | `signing-pki/fulcio-chain.pem` in the cluster repo (the new Fulcio chain, intermediate then root, public), as a JSON string; read only with `signing.managedKeys` |
| `@@SIGNING_TRUSTED_ROOT@@` | `signing-pki/trusted-root.json` (the Sigstore TrustedRoot, public), as a JSON string; read only with `signing.trustedRoot` |
| `@@CLEARANCE_FULCIO_URL@@` | `clearance.attestation.fulcioUrl`, default `http://fulcio-server.fulcio-system.svc` |
| `@@CLEARANCE_REKOR_URL@@` | `clearance.attestation.rekorUrl`, default `http://rekor-server.rekor-system.svc` |
| `@@CLEARANCE_ATTEST_AUDIENCE@@` | `clearance.attestation.audience`, default `sigstore` (the client-id in Fulcio's issuer entry) |
