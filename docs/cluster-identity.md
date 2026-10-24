# Cluster identity

`components.clusterIdentity` gives each cluster its own ServiceAccount token issuer, and lets clusters trust each
other's issuers. A workload on one cluster can then call another cluster's API server with a short-lived,
audience-bound ServiceAccount token that the kubelet rotates. Nothing is stored or copied. This replaces the
long-lived `kubernetes.io/service-account-token` Secrets that cross-cluster callers used to carry. Tower, the
Backstage plugin, is the first user (hangar: `SPEC-tower-cluster-credentials.md`).

## How it works

```
cluster A (caller)                                    cluster B (trusting)
  pod with a projected token                            kube-apiserver --authentication-config
  (audience: B, expires in 10 min)  -- bearer token -->   jwt: issuer = A's issuer, audiences = [B]
                                                          CEL: namespace, ServiceAccount, lifetime
  A's issuer (first --service-account-issuer)            user: hangar:A:<serviceAccount>
  published as static files: discovery + JWKS  <-- B fetches A's keys
```

- **Issuer (every cluster).**
  - The cluster signs tokens as `components.clusterIdentity.issuer`, the first `--service-account-issuer`.
  - The Kubernetes default (`https://kubernetes.default.svc.cluster.local`) stays as a second, accepted issuer, so
    tokens minted before the change keep working.
  - `--api-audiences` lists both.
  - Every cluster built from this template defaults to the same issuer, and an API server refuses to trust its own
    issuer, so two clusters can only trust each other once both have a unique one.
- **Published keys.**
  - `hack/cluster-identity.sh publish` writes `.well-known/openid-configuration` and `jwks.json` for the cluster's
    current signing key. They're public keys.
  - Host them at the issuer URL, for example under the fleet's static site.
  - kubeadm does not rotate `sa.key`. If it ever changes, publish again.
- **Trust (clusters that accept other clusters' tokens).**
  - Each `trust` entry becomes one JWT authenticator in `00-bootstrap/cluster-identity/authentication-config.yaml`.
    It's installed as `/etc/kubernetes/authn/config.yaml`, and the API server reloads it on change.
  - Tokens are accepted only when all of these hold:
    - the namespace and ServiceAccount are on the list;
    - the audience matches;
    - the lifetime is at most `maxLifetimeSeconds` (600 by default; it also rules out the year-long extended 3607 s
      tokens).
  - An accepted token becomes the user `hangar:<cluster>:<serviceAccount>`, in group `hangar:<cluster>`, with the
    calling pod as `extra["hangar.io/pod"]`.
  - Bind RBAC to that user and nothing else. An accepted user with no binding can do nothing.
- **Revocation.** Delete the entry from the file. The API server reloads it within seconds, and every token from that
  issuer stops working, whatever its expiry. Otherwise a stolen token lives at most `maxLifetimeSeconds`.

## New clusters

Every Apron cluster's issuer is `https://<issuerBase>/oidc/<name>` (one-name rule; `issuerBase` defaults to
`hangarplatform.dev`). The hub cluster (dev profile, `components.towerAccessHub`) gets
`00-bootstrap/cluster-identity/authentication-config.yaml`, which trusts the issuer of the cluster Tower runs on
(`tower.cluster`) for `backstage-ingestor` and `tower-actor` in Tower's namespace (`app-backstage-<env>`). That
directory has no `application.yaml`, so Argo CD never syncs it.

A hub that receives the tower cluster's trace metrics (`observability.receive`, dev profile) also accepts that
cluster's `observability/kube-prometheus-stack-prometheus` ServiceAccount, with the same audience and 10-minute limit.
Its user, `hangar:<tower cluster>:kube-prometheus-stack-prometheus`, is bound to one thing:
`create` on the `services/proxy` of `thanos-receive:19291` (`40-observability/thanos-receive-access`). On the tower
cluster, `observability.remoteWrite` (prod profile) sends only the `traces_service_graph_*` and
`traces_span_metrics_*` series there, with a projected token read on every send; it needs `fleet.hubApiServer` and
`fleet.hubCaData` (the hub API server's CA, base64 PEM) in `cluster.yaml`. After adding the subject, run
`hack/cluster-identity.sh trust` on the hub again with the re-rendered file.

The flags are set on the running node after `apron up`, the same way for every runtime: `apron identity` wraps
`hack/cluster-identity.sh publish`, `issuer` and `trust` with the context, issuer and node derived from the name (kiac
can't pass API-server flags at create time, so one path for every runtime). Publish the keys first.

## Running clusters

`hack/cluster-identity.sh issuer` and `trust` change a live control-plane node through a command prefix that runs one
command inside it (`--node-exec`, for example `container exec -i <node>`, `docker exec -i <node>`, or
`ssh <host> podman exec -i <node>`). Each one:

1. reads `/etc/kubernetes/manifests/kube-apiserver.yaml` and edits it on the workstation (python3 + PyYAML), so the
   node needs no tools beyond `cat`, `cp`, `mkdir`, `tee` and `curl`;
2. shows the diff (`--dry-run` stops there);
3. backs the manifest up to `/etc/kubernetes/hangar-backup/`, outside `manifests/`, where the kubelet would run it;
4. writes the new manifest and waits for the API server to come back carrying the new flag;
5. on timeout, restores the backup by itself and exits with an error.

`trust` first checks that the node can fetch every trusted issuer's discovery document, so it refuses before
breaking anything. `verify` mints a 10-minute token on the caller cluster and presents it, with no other credential,
to the trusting cluster. It then checks that a wrong audience and a 20-minute token are refused.

The node's filesystem survives restarts. A recreated cluster gets the configuration from its kind config instead
(new clusters, above).

## In use

- **Tower → hub.** Tower's cluster signs as `https://<issuerBase>/oidc/<tower cluster>`; the hub trusts it for two
  ServiceAccounts in `app-backstage-<env>`, both with audience `<hub name>`: `backstage-ingestor` (the Tower pod's
  projected token, reads) and `tower-actor` (a token minted per write action). Records: the hub repo's
  `00-bootstrap/cluster-identity/` and `00-bootstrap/backstage-ingestor-rbac/`, Tower's `66-tower-access/`, Tower
  `docs/credentials/index.md`.
- **AWS → hub.** An IAM identity provider for the hub's issuer; roles trust audience `sts.amazonaws.com` and an exact
  ServiceAccount (`hangar-crossplane-<hub name>` for `crossplane-system:provider-aws-*`, `glidepath-deploy-<function>`
  for `app-<app>-cicd:glidepath-cloud-deployer`). Enable with `components.cloudTargets` and `aws.accountId`. Records:
  Airframe `docs/admin/cloud-credentials.md`, Glidepath `docs/admin/cloud-deploy-identity.md`.

Lessons from the first rollouts that apply to any consumer:

- **Make the issuer unique first.** Every kind and kubeadm cluster defaults to the same issuer, and an API server
  refuses to trust its own.
- **Set `--api-audiences` explicitly** when changing the issuer. It defaults to the *first* issuer, so changing only the
  issuer breaks every in-cluster token minted with the old audience.
- **Mint tokens no longer than the trust's `maxLifetimeSeconds`.** A 30-minute test token was refused (401) by the
  600 s rule.
- **Backstage's Kubernetes plugin** (`@backstage/plugin-kubernetes-backend` 0.21.10) rewrites a `serviceAccount`
  cluster with no `serviceAccountToken` to its *own* in-cluster API server when Backstage runs in a cluster. A
  federated entry must keep a non-empty placeholder token. Tower's token-file strategy never sends it.
- **Pod-bound tokens** carry the pod's name. The trust maps it to `extra["hangar.io/pod"]` so the audit log names the
  pod. Tokens that aren't pod-bound (`kubectl create token`) are accepted too; the mapping is `has()`-guarded.
- **Publish before you switch, and keep publishing.** AWS fetches `/.well-known/openid-configuration` from the issuer
  URL itself; a site deploy that dropped dotfiles would have broken every token.
- **Kubernetes tokens carry one audience,** so `StringEquals` on `aud` in an IAM trust policy is right.
- **A rebuilt cluster has a new `sa.key`.** Publish its keys again before anything relies on federation.

## Managed clusters

EKS, GKE and AKS don't let you set API server flags. The same trust model goes through the cloud's identity
exchange instead: an IAM OIDC provider plus `AssumeRoleWithWebIdentity`, Workload Identity Federation, or an Entra
federated credential. Their own clusters already publish an issuer. See section 4 of hangar's
`SPEC-tower-cluster-credentials.md`.
