# tests/cases/17-glidepath-lists.sh (see tests/run.sh)
# group: render
# secs: 2
# needs: lab
GA="${TMP}/gpapi"
GW=30-policy/kyverno-policies/tower-identity-writes.yaml
CPV=50-glidepath/glidepath-control-plane/values.yaml
# The lists must match the pinned Glidepath's values: a render with a task added or dropped is refused, naming it.
gp_drift() { # gp_drift LABEL SED-EXPR WANT-IN-MESSAGE
  local f out
  f="$(mktemp "${TMP}/gp-values-XXXXXX")"
  sed "$2" "${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml" >"${f}"
  if cmp -s "${f}" "${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml"; then
    bad "glidepath lists drift: ${1}: the sed changed nothing"
    return
  fi
  if out="$(APRON_GLIDEPATH_VALUES="${f}" python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" 2>&1)"; then
    bad "glidepath lists drift: ${1}: render accepted"
  elif grep -q -- "$3" <<<"${out}"; then
    ok "glidepath lists drift: ${1}: refused ($(grep -o "$3" <<<"${out}" | head -1))"
  else
    bad "glidepath lists drift: ${1}: refused for another reason: ${out}"
  fi
}
if [ "${HAVE_YAML}" = true ]; then
  gp_drift "a source task Glidepath added" 's/build: \[build-source,/build: [build-source, lint-source,/' 'sourceTasks.build: missing here: lint-source'
  gp_drift "a source task Glidepath dropped" 's/build-go-binary-artifact\]/build-go-binary-artifactx]/' 'not in Glidepath: build-go-binary-artifact'
  gp_drift "a new pusher task" 's/build: \[push-image\]/build: [push-image, push-sbom]/' 'pusherTasks.build: missing here: push-sbom'
  gp_drift "a new record-writer task" 's/    release: \[open-release-pr\]/    release: [open-release-pr, open-release-x]/' 'recordWriterTasks.release: missing here: open-release-x'
  gp_drift "a new test-runner task" 's/    test: \[run-testworkflow\]/    test: [run-testworkflow, run-more]/' 'testRunnerTasks.test: missing here: run-more'
  gp_drift "a new cloud deployer Pipeline" 's/    deploy: \[deploy-aws-lambda, deploy-aws-ecs\]/    deploy: [deploy-aws-lambda, deploy-aws-ecs]\n    release: [deploy-aws-ecs]/' 'cloudDeployerTasks.release'
  for bad in 'a: [unclosed' '- a list' 'cicdRunAdmission: [x]'; do
    printf '%s\n' "${bad}" >"${TMP}/gp-badvalues.yaml"
    out="$(APRON_GLIDEPATH_VALUES="${TMP}/gp-badvalues.yaml" python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" 2>&1)"
    if grep -q '^error: ' <<<"${out}" && ! grep -q Traceback <<<"${out}"; then
      ok "glidepath lists: a bad values file (${bad}) is a clean error"
    else
      bad "glidepath lists: a bad values file (${bad}): ${out}"
    fi
  done
  if APRON_GLIDEPATH_VALUES=/nonexistent python3 hack/render.py --cluster "${LAB}/dev/cluster.yaml" --out "${TMP}/gp-drift-out" >/dev/null 2>&1; then
    bad "glidepath lists: an unreadable APRON_GLIDEPATH_VALUES was accepted"
  else
    ok "glidepath lists: an unreadable APRON_GLIDEPATH_VALUES is refused, not skipped"
  fi
else
  echo "  skip glidepath lists drift tests: need PyYAML"
fi
mkdir -p "${TMP}/gp-bad-mode"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {sourceIsolation: off}'; } >"${TMP}/gp-bad-mode/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-mode/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-mode/err"; then
  bad "glidepath.sourceIsolation: off was accepted"
else
  grep -q 'deny (default) or warn' "${TMP}/gp-bad-mode/err" && ok "glidepath.sourceIsolation off is refused" || bad "glidepath.sourceIsolation off: $(cat "${TMP}/gp-bad-mode/err")"
fi
mkdir -p "${TMP}/gp-bad-gate"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gateConcurrency: 0}'; } >"${TMP}/gp-bad-gate/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-gate/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-gate/err"; then
  bad "glidepath.gateConcurrency: 0 was accepted"
else
  grep -q 'whole number of at least 1' "${TMP}/gp-bad-gate/err" && ok "glidepath.gateConcurrency 0 is refused" || bad "glidepath.gateConcurrency 0: $(cat "${TMP}/gp-bad-gate/err")"
fi

mkdir -p "${TMP}/gp-bad-prov"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: main}'; } >"${TMP}/gp-bad-prov/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-bad-prov/cluster.yaml" >/dev/null 2>"${TMP}/gp-bad-prov/err"; then
  bad "glidepath.gitopsRepoProvenance: main was accepted"
else
  grep -q 'default_branch, source, or unset' "${TMP}/gp-bad-prov/err" && ok "glidepath.gitopsRepoProvenance main is refused" || bad "glidepath.gitopsRepoProvenance main: $(cat "${TMP}/gp-bad-prov/err")"
fi

# the key's first name, glidepath.gitopsPipelineProvenance, is still read: alone it is used with a warning, next to a different new key it is an error
mkdir -p "${TMP}/gp-prov-new" "${TMP}/gp-prov-old" "${TMP}/gp-prov-both" "${TMP}/gp-prov-same"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsRepoProvenance: source}'; } >"${TMP}/gp-prov-new/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-new/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-new/err" || bad "glidepath.gitopsRepoProvenance: source did not render: $(cat "${TMP}/gp-prov-new/err")"
has "${TMP}/gp-prov-new/${CPV}" '^  gitopsRepoProvenance: source$' "glidepath.gitopsRepoProvenance source reaches the control plane values"
if grep -q 'deprecated' "${TMP}/gp-prov-new/err"; then bad "glidepath.gitopsRepoProvenance warned about a deprecated key"; else ok "glidepath.gitopsRepoProvenance prints no deprecation warning"; fi
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source}'; } >"${TMP}/gp-prov-old/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-old/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-old/err" || bad "the old glidepath.gitopsPipelineProvenance: source did not render: $(cat "${TMP}/gp-prov-old/err")"
has "${TMP}/gp-prov-old/${CPV}" '^  gitopsRepoProvenance: source$' "the old key gitopsPipelineProvenance is still read"
grep -q 'glidepath.gitopsPipelineProvenance is deprecated, rename it to glidepath.gitopsRepoProvenance' "${TMP}/gp-prov-old/err" && ok "the old key prints a deprecation warning" || bad "the old key printed no deprecation warning: $(cat "${TMP}/gp-prov-old/err")"
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source, gitopsRepoProvenance: default_branch}'; } >"${TMP}/gp-prov-both/cluster.yaml"
if python3 hack/render.py --cluster "${TMP}/gp-prov-both/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-both/err"; then
  bad "both provenance keys with different values were accepted"
else
  grep -q 'they are the same setting' "${TMP}/gp-prov-both/err" && ok "both provenance keys with different values are refused" || bad "both provenance keys differing: $(cat "${TMP}/gp-prov-both/err")"
fi
{ cat "${LAB}/dev/cluster.yaml"; echo 'glidepath: {gitopsPipelineProvenance: source, gitopsRepoProvenance: source}'; } >"${TMP}/gp-prov-same/cluster.yaml"
python3 hack/render.py --cluster "${TMP}/gp-prov-same/cluster.yaml" >/dev/null 2>"${TMP}/gp-prov-same/err" && ok "both provenance keys with the same value render" || bad "both provenance keys, same value: $(cat "${TMP}/gp-prov-same/err")"
