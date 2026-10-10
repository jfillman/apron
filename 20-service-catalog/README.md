# 20-service-catalog

> **Template note**: this file was carried over from `gitops-cluster-dev`'s own README and describes that cluster's real build history — useful background on how this component works and why, not a to-do list for your new cluster. Treat dates/"live-verified" claims as historical, not something to re-verify on this one.


Pins `idp-service-catalog`'s XRDs/Compositions to a version, per `gitops-strategy.md`
§3 — done, wired into the app-of-apps root and live-verified 2026-08-13. See
`idp-service-catalog/application.yaml`'s own header for the exact sync scope (`xrds/`
+ each `compositions/<name>/composition.yaml`, not `charts/idp-application` or
`functions/` — see that file's comments for why).

`idp-application` itself is NOT installed from here — it's a chart future
Compositions render per app-release into `gitops-<app-name>` repos, not a
cluster-wide install (see `idp-service-catalog/charts/idp-application/README.md`).

`analysis-catalog/` installs the ClusterAnalysisTemplates every app's canary analysis can use, from
airframe's `analysis/` directory at its own tag (separate from `idp-service-catalog`'s pin on purpose; see
that file's header). `hack/customize-cluster.sh` drops it when Argo Rollouts is off.
