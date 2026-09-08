# 60-backstage

`kind-man`-only: the fleet's developer portal — upstream Backstage (not Red Hat
Developer Hub, a licensing call made explicitly, see `idp/docs/backstage-design.md`),
built as its own image and onboarded onto `platform-cicd` (`kind-dev`) as an `appType:
infra` app rather than through this template. This directory only carries what's
hand-deployed straight to `kind-man`.

- `postgres/` — Bitnami's `postgresql` chart (OCI, `oci://registry-1.docker.io/
  bitnamicharts/postgresql`, pinned `18.8.13`), standalone, real as of 2026-08-26.
  Backstage's own catalog/scaffolder/auth state lives here. `auth.existingSecret`
  works cleanly on this chart (unlike Infisical's bundled subchart, see that
  Application's own header for why that one couldn't) — create the credentials Secret
  by hand before this Application first syncs, same "never pasted to an assistant,
  never committed" convention as everywhere else in this platform:
  ```
  kubectl create namespace backstage
  kubectl create secret generic backstage-postgres-credentials -n backstage \
    --from-literal=postgres-password="$(openssl rand -base64 24)" \
    --from-literal=password="$(openssl rand -base64 24)"
  ```
- `backstage/` — the app itself, real as of 2026-08-26. Plain Deployment/Service (no
  officially-maintained Backstage Helm chart exists to adopt), pinned to the real
  first image the app's own onboarded CI pipeline published
  (`ghcr.io/jfillman/backstage:1.0.0-0b52ebe`). Manually bump the tag here after each
  new CI build for now - no GitOps image-updater wired up yet. `POSTGRES_*` env vars
  wire it to `postgres/`'s own instance; `imagePullSecrets: registry-credentials`
  needs the `backstage` namespace's `hangar.io/managed-secrets: "true"` label
  (declared in this directory's own `Namespace` manifest) for kind-man's
  `registry-credentials` `ClusterExternalSecret` to populate it - the image is
  genuinely private. `app.baseUrl`/`backend.baseUrl` are still the image's baked-in
  `localhost` defaults - no real kind-man ingress hostname decided yet, see
  `idp/docs/backstage-design.md`; reachable today only via `kubectl port-forward`.

Gated by `components.backstage` in `cluster.yaml` (see `cluster.yaml.example`) -
`kind-man` is the only cluster that should ever set this `true`, matching the singleton
pattern `components.secrets.infisicalHost`/`components.platformCicd` already use for
"exactly one cluster in the fleet runs this."
