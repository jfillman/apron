# tests/cases/51-argo-sync.sh (see tests/run.sh)
# group: policy
# secs: 11
if out="$(python3 tests/policy/test_argo_sync.py 2>&1)"; then
  ok "clearance argo-sync: $(tail -1 <<<"${out}")"
else
  bad "clearance argo-sync: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
