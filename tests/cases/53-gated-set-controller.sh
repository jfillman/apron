# tests/cases/53-gated-set-controller.sh (see tests/run.sh)
# group: gatedset
# secs: 87
# needs: gated-set migration-window delete-guard
# W-43: the gated set's two ApplicationSets (rendered above as gate-set and gate-set-handover) run by the real Argo CD
# ApplicationSet controller (tests/appset, the Argo CD Go module argocd-apps runs) against envtest: one set per environment,
# the ignore rule and preservedFields only in the gated set, and the handover in both directions keeping the Application.
# W-46 (d): the same with the delete guard in Deny (delete-guard-deny), the controller running as the user it names
# (TestDeleteGuard): bare flips and a removed identity keep the Application, the handovers still pass.
# The migration window (gate-window, TestMigrationWindow): only the window's apps reach the gated set, the held app stays in
# tenant-onboarding on the plugin, and a paused environment has no automated sync in every templatePatch branch.
if ! command -v go >/dev/null 2>&1; then
  if [ "${APRON_REQUIRE_ENVTEST:-}" = 1 ]; then bad "tenant-onboarding gated set: go is not installed"; else echo "  skip tenant-onboarding gated set (tests/appset): go is not installed"; fi
# The three tests each start their own envtest API server (envtest reserves its ports across processes), so they run side by
# side from one test binary; their -v output, together, is what the one ok line counts.
elif out="$(cd tests/appset && go test -c -o "${TMP}/appset.test" . 2>&1)"; then
  APPSET_TESTS="TestGatedSet TestDeleteGuard TestMigrationWindow"
  for t in ${APPSET_TESTS}; do
    ( cd tests/appset && APRON_GATED_RENDER="${TMP}/gate-set" APRON_GATED_HANDOVER_RENDER="${TMP}/gate-set-handover" \
        APRON_DELETE_GUARD_RENDER="${TMP}/delete-guard-deny" APRON_WINDOW_RENDER="${TMP}/gate-window" \
        "${TMP}/appset.test" -test.count=1 -test.v -test.timeout=10m -test.run "^${t}\$" >"${TMP}/appset-${t}.log" 2>&1
      echo $? >"${TMP}/appset-${t}.rc" ) &
  done
  wait
  out="" rc=0
  for t in ${APPSET_TESTS}; do
    out="${out}$(cat "${TMP}/appset-${t}.log")
"
    [ "$(cat "${TMP}/appset-${t}.rc" 2>/dev/null)" = 0 ] || rc=1
  done
  if [ "${rc}" != 0 ]; then
    bad "tenant-onboarding gated set: $(grep -E -- '--- FAIL|gatedset_test.go:[0-9]+:|^panic|^FAIL' <<<"${out}" | head -8)"
  elif grep -q -- '--- SKIP' <<<"${out}"; then echo "  skip tenant-onboarding gated set (tests/appset): $(grep -m1 -A1 -- '--- SKIP' <<<"${out}" | tail -1 | sed 's/^ *//')"
  else ok "tenant-onboarding gated set against Argo CD's ApplicationSet controller: $(grep -c -- '^    --- PASS' <<<"${out}") cases"; fi
else
  bad "tenant-onboarding gated set: the tests do not build: $(head -8 <<<"${out}")"
fi
