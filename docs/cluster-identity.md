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

With `enabled: true`, `hack/customize-cluster.sh`:

1. renders `00-bootstrap/cluster-identity/` (the README, plus `authentication-config.yaml` when `trust` is set), which
   has no `application.yaml`, so Argo CD never syncs it;
2. patches `hack/kind-config.yaml`:
   - the issuer flags (kubeadm v1beta4 `extraArgs`, a list, so the issuer can appear twice);
   - with trust entries, `--authentication-config`, the volume, and a bind mount of the rendered file.

After `kind create cluster`, publish the keys (next-steps item 4c). For a non-kind cluster, put the same flags and the
file in its own provisioning.

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

## In use: Tower on kind-prod → kiac-dev

The first consumer, live since 2026-10-12.

- **kind-prod** signs as `https://hangarplatform.dev/oidc/kind-prod`. The keys are on hangar's site, under
  `web/public/oidc/`.
- **kiac-dev** trusts it for two kind-prod ServiceAccounts in `backstage`, both with audience `kiac-dev`:
  - `backstage-ingestor`, the Backstage pod's projected token, for reads;
  - `tower-actor`, a token minted per write action.
- **The records:**
  - gitops-cluster-dev `00-bootstrap/cluster-identity/` (the trust file);
  - gitops-cluster-kind-prod `00-bootstrap/cluster-identity/` (the issuer flags);
  - Tower `docs/credentials/index.md` (identities, diagrams, operations, troubleshooting).

Lessons from that rollout that apply to any consumer:

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

## Managed clusters

EKS, GKE and AKS don't let you set API server flags. The same trust model goes through the cloud's identity
exchange instead: an IAM OIDC provider plus `AssumeRoleWithWebIdentity`, Workload Identity Federation, or an Entra
federated credential. Their own clusters already publish an issuer. See section 4 of hangar's
`SPEC-tower-cluster-credentials.md`.
