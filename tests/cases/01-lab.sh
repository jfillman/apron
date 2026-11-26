# tests/cases/01-lab.sh (see tests/run.sh)
# group: render
# secs: 6
echo "== 1. render"
new "${LAB}/dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod
new "${LAB}/prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev
render_ok "${LAB}/dev" "dev/kiac"
render_ok "${LAB}/prod" "prod/kind"
expect "${LAB}/dev" "dev/kiac" 10-crds-operators/infisical/application.yaml 50-glidepath/glidepath-control-plane/values.yaml \
  00-bootstrap/cluster-identity/authentication-config.yaml 10-crds-operators/traefik/traefik.yaml \
  01-argocd-platform/argocd-apps-install/application.yaml '!hack/kind-config.yaml' '!66-tower-access' '!65-backstage'
expect "${LAB}/prod" "prod/kind" hack/kind-config.yaml 66-tower-access/rbac.yaml 10-crds-operators/traefik/traefik.yaml \
  10-crds-operators/external-secrets/secretstore-xr.yaml 01-argocd-platform/argocd-apps-install/application.yaml \
  '!10-crds-operators/infisical' '!50-glidepath' '!55-autopilot' '!65-backstage'
has "${LAB}/dev/00-bootstrap/cluster-identity/authentication-config.yaml" 'oidc/hangar-prod' "dev trusts prod's issuer"
has "${LAB}/dev/00-bootstrap/cluster-identity/authentication-config.yaml" 'namespace == "app-backstage-prod"' \
  "dev trusts Tower's namespace app-backstage-prod"
has "${LAB}/dev/50-glidepath/glidepath-control-plane/values.yaml" '^clusterName: hangar-dev$' "glidepath clusterName = name"
has "${LAB}/dev/60-gateway-routes/argocd-httproute.yaml" 'argocd\.hangar-dev\.local' "dev hostnames use <name>.local"
has "${LAB}/dev/60-gateway-routes/argocd-httproute.yaml" 'namespace: hangar-gateway' "routes attach to hangar-gateway"
has "${LAB}/prod/hack/kind-config.yaml" 'containerPort: 30080' "kind maps host 80 to Traefik's NodePort"
has "${LAB}/prod/10-crds-operators/traefik/traefik.yaml" 'nodePort: 30080' "Traefik NodePort matches kind mapping"
has "${LAB}/prod/20-service-catalog/airframe-service-catalog/application.yaml" 'xrds/dex.yaml' "prod gets the Dex XRD"
has "${LAB}/prod/10-crds-operators/crossplane/functions.yaml" 'function-dex' "prod gets function-dex"
has "${LAB}/prod/10-crds-operators/external-secrets/cluster-secret-store.yaml" 'hangar-dev\.local:31800/api' \
  "prod reaches the hub's Infisical"
has "${LAB}/prod/00-bootstrap/cluster-registry/application.yaml" 'gitops-cluster-hangar-dev' "prod reads the hub's fleet file"
# generated passwords land in the cluster repo, never the template's old values
has "${LAB}/dev/10-crds-operators/infisical/application.yaml" 'password: "[0-9a-f]{40}"' "Infisical passwords generated"
if grep -rqE '900bf58b|8826860c|6cf8f3dc|cbc9d507' "${LAB}" "${APRON}/templates"; then
  bad "an old committed password is still present"
else
  ok "no old committed password anywhere"
fi
d1="$(grep -h 'infisicalPgPassword' "${LAB}/dev/cluster.yaml")"
new "${TMP}/again" dev hangar-dev kiac --repo-url https://github.com/acme/x --scm-owner acme --tower-cluster hangar-prod
[ "${d1}" != "$(grep -h 'infisicalPgPassword' "${TMP}/again/cluster.yaml")" ] && ok "passwords differ per init" \
  || bad "two inits generated the same password"
