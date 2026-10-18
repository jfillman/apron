# `apron` command reference

`apron` deploys Hangar onto a Kubernetes cluster. Onboarding an **existing** cluster is the primary path; the `kiac`
(Apple container VMs) and `kind` runtimes first create a local cluster and then run the same onboarding.

- **Profile** (`dev` | `prod`) is *what runs*; **runtime** (`existing` | `kiac` | `kind`) is *where*. They are
  independent.
- **One name.** A cluster's name is also its kubectl context, its fleet registry entry, its Infisical project stem,
  its issuer path (`https://<issuerBase>/oidc/<name>`) and its hostname stem. `apron` refuses a context that differs.
- Nothing has a default cluster name or GitHub owner: pass them.
- Everything else comes from the cluster repo's `cluster.yaml`, resolved by `hack/render.py --print-values`.
- `apron` never prints or commits secret values. It checks hand-planted Secrets by existence only.

## init

```
apron init <dev|prod> --name N --runtime existing|kiac|kind --out DIR --repo-url URL --scm-owner OWNER
           [--tenants-repo URL] [--registry-owner OWNER] [--domain D] [--context CTX]
           [--fleet-hub NAME --fleet-repo-url URL] [--tower-cluster NAME] [--set k=v]... [--create-repos] [--push]
```

`--fleet-hub`/`--fleet-repo-url` (the control-plane cluster and its repo) are required on every cluster but the hub;
`--tower-cluster` whenever the profile turns Tower access on (`hack/check.py` says which). `--context` (existing only)
records the kubeconfig context to adopt; when it differs from the name, `apron up` renames it.

Validates the name (DNS-1123 label) and owners, writes `DIR/cluster.yaml` (`hack/new_cluster.py`; an existing one is
kept), validates it (`hack/check.py`), renders the cluster repo into DIR (`hack/render.py`) and makes DIR a git repo
with `origin` = `--repo-url` (an existing different origin is refused). `--tenants-repo` defaults to the cluster
repo's name plus `-tenants`, same owner.

- `--create-repos`: `gh repo create OWNER/NAME --private` for the cluster and tenants repos, only those missing.
  Existing repos are left untouched and listed as skipped.
- `--push`: commit the rendered tree and push it to `main` of the cluster repo (DIR's own origin, nothing else).

## render

`apron render --out DIR`: day-2 re-render after editing `cluster.yaml`: check, render, then `git status --short`.

## up

`apron up --out DIR [--dry-run] [--yes] [--rename-context FROM]`. Idempotent; re-run it after any stop.

1. **Runtime.**
   - kiac: `kiac create cluster --name N --workers W --cni C --kernel K --cpus X --cp-memory Y`, from resolved
     `runtime.kiac`, never `--gateway` (Apron installs Traefik itself). Skipped when `kiac get clusters` lists N.
   - kind: `kind create cluster --name N --config <rendered kind config>`. Skipped when `kind get clusters` lists N.
   - existing: `kubectl --context N get --raw /readyz`.
2. **Context.** kiac/kind: when context N is missing, the one the runtime created (`kiac-N` / `kind-N`, looked up in
   `kubectl config get-contexts`) is renamed to N. existing: the context must already be N; otherwise
   `runtime.existing.context` (from `init --context`) or `--rename-context FROM` is renamed to N. Then N must answer `/readyz`.
3. **Onboard** (every runtime): the CNI manifest when the resolved values name one (kind: Calico); namespace
   `argocd`; `kubectl apply --server-side -n argocd -f <rendered 01-argocd-platform/install.yaml>`.
4. **Hand-planted Secrets.** Each one is checked with `kubectl get secret` (existence only): the Argo CD repo-creds
   Secret; on the Infisical host `infisical/infisical-secrets` and `infisical/infisical-bootstrap-credentials`;
   elsewhere `crossplane-system/provider-infisical-creds`. The list and the commands come from `bootstrapSecrets` in
   the resolved values. When any is missing, `up` prints a `kubectl create secret ...` template with `<value>`
   placeholders for each, then exits 0 with "re-run apron up to continue". You run those commands yourself.
5. **Root.** `kubectl apply -f DIR/root-app-of-apps.yaml`, then the manual steps from
   [after-up.md](after-up.md) (manual-sync order, cluster identity, readiness flags, provider SA re-pins).

`--dry-run` prints every step and command and changes nothing. `--yes` skips the confirmation prompt.

## fleet

```
apron fleet add --from DIR --fleet FILE
apron fleet set-infisical --fleet FILE --org-id X --url U [--in-cluster-url U]
```

Edits the fleet's `clusters.yaml` (owned by the control-plane cluster's repo; [clusters-file.md](clusters-file.md)).
`add` adds or updates DIR's record (name, zone, roles, tenantsRepo, serviceAccountIssuer, readiness flags `false`,
keeping flags a person already set) and ensures top-level `scm: {owner}`. Comments are kept when `ruamel.yaml` is
installed; with PyYAML only they are dropped, and the helper says so.

## identity

`apron identity --out DIR [--node-exec CMD] [--dry-run]` wraps `hack/cluster-identity.sh issuer` with issuer
`issuer` from the resolved values (`https://<issuerBase>/oidc/<name>`), context N and the control-plane node found by
label. `--node-exec` defaults to the resolved `runtime.nodeExec` plus the node (kiac `container exec -i`, kind
`docker exec -i`); override it for podman or a cluster on another
machine (`ssh HOST podman exec -i <node>`). Refused on `existing`: a managed cluster publishes its own issuer.
Publish the keys afterwards with `hack/cluster-identity.sh publish` ([cluster-identity.md](cluster-identity.md)).

## verify, resume, down

- `apron verify --out DIR`: `kiac verify cluster --name N` (kiac) or `/readyz` and nodes, then every Argo CD
  Application's sync and health. Read-only.
- `apron resume --out DIR`: `kiac resume cluster --name N`, or (kind) start the cluster's containers
  (`APRON_CONTAINER_ENGINE`, default `docker`); fix the context; print `/etc/hosts` lines for `*.<domain>` at the
  node IP. `/etc/hosts` is never edited.
- `apron down --out DIR --yes`: `kiac delete cluster --name N` or `kind delete cluster --name N`, then deletes the
  context. Refused for `existing`.

## Tests

`tests/cli/test_cli.sh` runs offline with fake `kubectl`, `kiac`, `kind`, `gh` and `docker` on PATH and stub
`hack/*.py` (`tests/stubs/`). `APRON_IMPL_ROOT=<apron checkout> tests/cli/test_cli.sh` runs it against a real
implementation of `hack/render.py`, `check.py` and `new_cluster.py` instead.
