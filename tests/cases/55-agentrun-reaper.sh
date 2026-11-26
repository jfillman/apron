# tests/cases/55-agentrun-reaper.sh (see tests/run.sh)
# group: policy
# secs: 1
echo "== 6. agentrun-reaper (the script in its ConfigMap, against a fake API)"
if out="$(python3 tests/reaper/test_reaper.py 2>&1)"; then
  ok "agentrun-reaper: $(grep -E '^Ran ' <<<"${out}")"
else
  bad "agentrun-reaper: $(grep -E 'FAIL|Error' <<<"${out}" | head -5)"
fi
