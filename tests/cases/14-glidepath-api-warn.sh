# tests/cases/14-glidepath-api-warn.sh (see tests/run.sh)
# group: render
# secs: 4
# needs: lab
echo "== 1a. glidepath-api's PipelineRun policies (pipeline trust T5)"
GA="${TMP}/gpapi"
mkdir -p "${GA}/warn"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {sourceIsolation: warn, runStorageClasses: [fast]}'; } >"${GA}/warn/cluster.yaml"
render_ok "${GA}/warn" "dev glidepath.sourceIsolation warn"
GW=30-policy/kyverno-policies/tower-identity-writes.yaml
CPV=50-glidepath/glidepath-control-plane/values.yaml
has "${LAB}/dev/${GW}" 'name: glidepath-api-pipelinerun-source-isolation' "glidepath-api: the source-isolation policy is rendered"
has "${LAB}/dev/${GW}" "expression: '\{\"build\": \[\"build-source\", \"unit-test\", \"build-image\", \"build-python-wheel-artifact\", \"build-go-binary-artifact\"\], \"clearance-gate-check\": \[\"render\"\], \"policy-validation-check\": \[\"render\"\], \"test\": \[\"run-integration-script\"\], \"values-check\": \[\"render\"\]\}'" "glidepath-api: the source tasks come from versions.glidepathRunTasks"
has "${LAB}/dev/${GW}" "expression: '\{\"build\": \[\"push-image\"\]\}'" "glidepath-api: the pusher task"
has "${LAB}/dev/${GW}" "expression: '\{\"deploy\": \[\"deploy-aws-lambda\", \"deploy-aws-ecs\"\]\}'" "glidepath-api: the cloud deployer tasks"
has "${LAB}/dev/${GW}" "expression: '\{\"bypass-merge-check\": \[\"mark-release-merged\", \"itsm-implement\"\], \"clearance-gate-check\": \[\"join-release\"\], \"itsm-check\": \[\"verify-change\", \"verify-change-advisory\"\], \"release\": \[\"open-release-pr\"\], \"release-outcome-notify\": \[\"itsm-close\"\], \"release-rollback-notify\": \[\"itsm-close-rolled-back\"\]\}'" "glidepath-api: the release-record-writer tasks"
has "${LAB}/dev/${GW}" "expression: '\{\"test\": \[\"run-testworkflow\"\]\}'" "glidepath-api: the test-runner task"
has "${LAB}/dev/${GW}" "s.serviceAccountName == 'clearance-gate' && variables.pipelineName in variables.clearanceTasks" "glidepath-api: clearance-gate is allowed on its own tasks, by exact name"
has "${LAB}/dev/${GW}" '^  validationActions: \[Deny\]$' "glidepath-api: deny by default"
has "${LAB}/dev/${CPV}" '^  sourceIsolationActions: \[Deny\]$' "glidepath control plane: source isolation Deny by default"
