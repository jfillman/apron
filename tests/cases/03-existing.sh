# tests/cases/03-existing.sh (see tests/run.sh)
# group: render
# secs: 6
E="${TMP}/existing"
new "${E}/dev" dev eks-dev existing --repo-url https://gitlab.example.com/org/gitops-eks-dev --scm-host gitlab.example.com \
  --scm-owner org --registry-owner org-images --tower-cluster eks-prod --domain eks-dev.example.dev \
  --set tower.domain=eks-prod.example.dev
new "${E}/prod" prod eks-prod existing --repo-url https://gitlab.example.com/org/gitops-eks-prod \
  --scm-host gitlab.example.com --scm-owner org --fleet-hub eks-dev --fleet-repo-url https://gitlab.example.com/org/gitops-eks-dev \
  --domain eks-prod.example.dev --set fleet.hubDomain=eks-dev.example.dev
render_ok "${E}/dev" "dev/existing"
render_ok "${E}/prod" "prod/existing"
has "${E}/prod/10-crds-operators/traefik/traefik.yaml" 'type: LoadBalancer' "existing: Traefik is a LoadBalancer"
has "${E}/dev/50-glidepath/glidepath-catalog/application.yaml" 'ghcr.io/org-images/airframe-validate' "registry owner flows"
has "${E}/dev/root-app-of-apps.yaml" 'https://gitlab.example.com/org/gitops-eks-dev' "repo URL flows"
# eks-dev sets registry owner org-images: nothing may fall back to the SCM owner or to github.com/ghcr.io/acme.
if grep -rqE '(github\.com|gitlab\.example\.com)/acme/|github\.com/org/|ghcr\.io/(org|acme)/' "${E}/dev"; then bad "existing: another owner/host leaked"; else ok "existing: only the configured SCM host/owner"; fi
