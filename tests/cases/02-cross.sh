# tests/cases/02-cross.sh (see tests/run.sh)
# group: render
# secs: 6
X="${TMP}/cross"
new "${X}/dev" dev lab-a kind --repo-url https://github.com/acme/gitops-cluster-lab-a --scm-owner acme --tower-cluster lab-b
new "${X}/prod" prod lab-b kiac --repo-url https://github.com/acme/gitops-cluster-lab-b --scm-owner acme \
  --fleet-hub lab-a --fleet-repo-url https://github.com/acme/gitops-cluster-lab-a
render_ok "${X}/dev" "dev/kind (cross)"
render_ok "${X}/prod" "prod/kiac (cross)"
expect "${X}/dev" "dev/kind (cross)" hack/kind-config.yaml 10-crds-operators/infisical/application.yaml 50-glidepath
expect "${X}/prod" "prod/kiac (cross)" '!hack/kind-config.yaml' 66-tower-access '!50-glidepath'
