# tests/cases/38-cloud-targets.sh (see tests/run.sh)
# group: render
# secs: 7
# Cloud-target providers: each of iam/ec2/rds/azure drops on its own (components.crossplane.*); the rest stay.
CT="${TMP}/cloudtargets"
new "${CT}/on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set components.cloudTargets=true --set 'aws.accountId="123456789012"'
new "${CT}/off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set components.cloudTargets=true --set 'aws.accountId="123456789012"' \
  --set components.crossplane.awsIam=false --set components.crossplane.awsEc2=false \
  --set components.crossplane.awsRds=false --set components.crossplane.azure=false
render_ok "${CT}/on" "cloudTargets/all providers"
render_ok "${CT}/off" "cloudTargets/trimmed providers"
CR=10-crds-operators/crossplane
expect "${CT}/on" "cloudTargets/all" ${CR}/provider-aws-iam.yaml ${CR}/provider-aws-ec2.yaml ${CR}/provider-aws-rds.yaml \
  ${CR}/provider-azure.yaml ${CR}/provider-azure-config.yaml ${CR}/provider-cloud-runtime.yaml
expect "${CT}/off" "cloudTargets/trimmed" !${CR}/provider-aws-iam.yaml !${CR}/provider-aws-ec2.yaml !${CR}/provider-aws-rds.yaml \
  !${CR}/provider-azure.yaml !${CR}/provider-azure-config.yaml !${CR}/provider-azure-creds-external-secret.yaml \
  !${CR}/provider-cloud-runtime.yaml ${CR}/provider-aws-runtime.yaml ${CR}/provider-aws-config.yaml
grep -rq 'name: provider-aws-ecr$' "${CT}/off/${CR}" && grep -rq 'name: provider-aws-sqs$' "${CT}/off/${CR}" \
  && grep -rq 'name: provider-family-aws$' "${CT}/off/${CR}" && ok "cloudTargets/trimmed: ecr, ecs, lambda, s3, sqs and the AWS family stay" \
  || bad "cloudTargets/trimmed: a kept provider is missing"
! grep -rqE 'name: provider-(aws-iam|aws-ec2|aws-rds|family-azure|azure-containerapp)$' "${CT}/off/${CR}" \
  && ok "cloudTargets/trimmed: no iam/ec2/rds/azure Provider rendered" || bad "cloudTargets/trimmed: a dropped provider is still rendered"
grep -rq 'name: provider-aws-iam$' "${CT}/on/${CR}" && grep -rq 'name: provider-azure-containerapp$' "${CT}/on/${CR}" \
  && ok "cloudTargets/all: iam and azure Providers rendered" || bad "cloudTargets/all: a provider is missing"
