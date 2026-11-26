#!/usr/bin/env bash
# tests/case.sh CASE-FILE - run one case of tests/cases/ (tests/run.sh runs every case through this).
# Needs APRON_TEST_TMP (the run's shared directory) and APRON_CASE_RESULT (where "PASS FAIL" is written when the case ends;
# a case that dies before its end writes nothing, and tests/run.sh counts that as a failure).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# A syntax error in a sourced file need not end bash (outside POSIX mode): the case would stop part way and still report.
bash -n "tests/cases/${1##*/}" || exit 2
. "tests/cases/${1##*/}"
printf '%s %s\n' "${PASS}" "${FAIL}" >"${APRON_CASE_RESULT:?}"
