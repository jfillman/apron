#!/usr/bin/env bash
# tests/case.sh CASE-FILE - run one case of tests/cases/ (tests/run.sh runs every case through this).
# Needs APRON_TEST_TMP (the run's shared directory) and APRON_CASE_RESULT (where "PASS FAIL" is written when the case ends;
# a case that dies before its end writes nothing, and tests/run.sh counts that as a failure).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "tests/cases/${1##*/}"
printf '%s %s\n' "${PASS}" "${FAIL}" >"${APRON_CASE_RESULT:?}"
