# tests/cases/16-glidepath-api-rerun.sh (see tests/run.sh)
# group: policy
# secs: 1
# needs: lab glidepath-api-warn
GA="${TMP}/gpapi"
if out="$(python3 tests/policy/test_glidepath_api_rerun.py "${LAB}/dev" "${GA}/warn" 2>&1)"; then
  case "${out}" in
    skipped*) echo "  skip glidepath-api rerun policy CEL tests: ${out} (a skip is not a pass)";;
    *) ok "glidepath-api rerun policy CEL: $(grep -E '^Ran ' <<<"${out}"), $(tail -1 <<<"${out}")";;
  esac
else
  bad "glidepath-api rerun policy CEL: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
