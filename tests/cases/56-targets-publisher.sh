# tests/cases/56-targets-publisher.sh (see tests/run.sh)
# group: policy
# secs: 1
echo "== 7. clearance-targets publisher (the script in its ConfigMap: retry on a dropped connection, none on a refusal)"
if out="$(python3 tests/targets/test_publisher.py 2>&1)"; then
  ok "clearance-targets publisher: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "clearance-targets publisher: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi
