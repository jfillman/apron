# tests/cases/52-tenant-delete-guard.sh (see tests/run.sh)
# group: policy
# secs: 9
# needs: delete-guard
if out="$(python3 tests/policy/test_tenant_delete_guard.py "${TMP}/delete-guard-deny" "${TMP}/delete-guard" 2>&1)"; then
  ok "tenant-onboarding delete guard: $(tail -1 <<<"${out}")"
else
  bad "tenant-onboarding delete guard: $(grep -E 'FAIL|Error|error' <<<"${out}" | head -5)"
fi
