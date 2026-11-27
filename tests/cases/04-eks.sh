# tests/cases/04-eks.sh (see tests/run.sh)
# group: render
# secs: 9
# needs: lab
# EKS (runtime eks, hangar-infra): three clusters, Infisical as its own service (no infisical.host anywhere), EKS's own
# issuers, Tower on the platform cluster trusted through an EKS OIDC identity provider config.
eks_extra() { # eks_extra TOWER_ISSUER: the keys Terraform's apron_values output supplies
  printf 'traefik: {loadBalancer: {certificateArn: %s, sourceRanges: [203.0.113.7/32, 198.51.100.0/24]}}\n' "${CERT}"
  printf 'tower: {cluster: eks-man, issuer: %s, domain: eks-man.aws.example.dev, baseUrl: https://backstage.eks-man.aws.example.dev}\n' "$1"
}
new "${K}/dev" dev eks-dev eks --repo-url https://github.com/acme/gitops-eks-dev --scm-owner acme \
  --domain eks-dev.aws.example.dev --set infisical.host=false --set "infisical.url=${INF}" --set "issuer=${ISS}/AAA1"
eks_extra "${ISS}/CCC3" >>"${K}/dev/cluster.yaml"
new "${K}/prod" prod eks-prod eks --repo-url https://github.com/acme/gitops-eks-prod --scm-owner acme \
  --domain eks-prod.aws.example.dev --fleet-hub eks-dev --fleet-repo-url https://github.com/acme/gitops-eks-dev \
  --set "infisical.url=${INF}" --set "issuer=${ISS}/BBB2" --set components.towerAccess=false \
  --set components.towerAccessHub=true --set fleet.relayUrl=https://relay.eks-dev.aws.example.dev
eks_extra "${ISS}/CCC3" >>"${K}/prod/cluster.yaml"
echo 'roles: [workloads]' >>"${K}/prod/cluster.yaml"
new "${K}/man" platform eks-man eks --repo-url https://github.com/acme/gitops-eks-man --scm-owner acme \
  --domain eks-man.aws.example.dev --fleet-hub eks-dev --fleet-repo-url https://github.com/acme/gitops-eks-dev \
  --set "infisical.url=${INF}" --set "issuer=${ISS}/CCC3" --set fleet.relayUrl=https://relay.eks-dev.aws.example.dev
eks_extra "${ISS}/CCC3" >>"${K}/man/cluster.yaml"
for c in dev prod man; do
  python3 hack/check.py --cluster "${K}/${c}/cluster.yaml" >/dev/null 2>"${TMP}/eks-check" \
    && ok "eks-${c}: passes check" || bad "eks-${c}: check: $(cat "${TMP}/eks-check")"
  render_ok "${K}/${c}" "eks-${c}"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" 'loadBalancerClass: service.k8s.aws/nlb' "eks-${c}: Traefik on the LBC's NLB"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" "aws-load-balancer-ssl-cert: ${CERT}" "eks-${c}: ACM cert on the NLB"
  has "${K}/${c}/10-crds-operators/traefik/traefik.yaml" 'loadBalancerSourceRanges: \["203\.0\.113\.7/32"' "eks-${c}: source ranges"
  expect "${K}/${c}" "eks-${c}" '!10-crds-operators/infisical' '!00-bootstrap/cluster-identity' '!10-crds-operators/metrics-server'
done
expect "${K}/dev" "eks-dev" 50-glidepath 55-autopilot 60-gateway-routes/glidepath-relay-httproute.yaml \
  60-gateway-routes/pac-webhook-httproute.yaml 00-bootstrap/backstage-ingestor-rbac/rbac.yaml \
  '!10-crds-operators/external-secrets/cluster-secret-store.yaml' '!10-crds-operators/external-secrets/secretstore-xr.yaml' \
  '!10-crds-operators/crossplane/provider-infisical-creds-external-secret.yaml'
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" "hostAPI: \"${INF}\"" "eks-dev: glidepath store reaches Infisical's URL"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" '^    auth: universal$' "eks-dev: glidepath store uses universal auth"
has "${K}/dev/00-bootstrap/backstage-ingestor-rbac/rbac.yaml" \
  'name: hangar:eks-man:system:serviceaccount:app-backstage-prod:backstage-ingestor' "eks-dev: Tower's EKS OIDC username"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" \
  'hangar:eks-man:system:serviceaccount:app-backstage-prod:tower-actor' "eks-dev: glidepath-api allows Tower's actor"
has "${K}/dev/50-glidepath/glidepath-control-plane/values.yaml" "${ISS}/AAA1" "eks-dev: Fulcio trusts the EKS issuer"
has "${K}/dev/55-autopilot/gateway/autopilot-api.yaml" 'value: "https://autopilot\.eks-dev\.aws\.example\.dev"' "eks-dev: Clearance's URL over https"
