# tests/cases/10-clearance-gate-admission.sh (see tests/run.sh)
# group: admission
# secs: 47
# needs: clearance-gate
G="${TMP}/gate"
if out="$(python3 tests/policy/test_clearance_gate.py "${G}/warn" "${G}/enforce" "${G}/ca" "${G}/prev" 2>&1)"; then
  ok "clearance gate admission: $(tail -1 <<<"${out}")"
else
  bad "clearance gate admission: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
