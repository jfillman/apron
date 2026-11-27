#!/usr/bin/env bash
# tests/run.sh - offline tests for Apron's renderer and checks. No cluster, no network.
#
#   1. render: the lab pair (dev on kiac as hangar-dev, prod on kind as hangar-prod), the cross pair (dev on kind,
#      prod on kiac) and both profiles on an existing cluster with another SCM host/owner. Each must leave no @@, no
#      old cluster name, no hardcoded owner; every YAML must parse (if python3 has PyYAML) and every script `bash -n`.
#   2. re-render: a second render changes nothing; removing a component removes its files; cluster.yaml survives.
#   3. check: each invariant violation is refused.
#   4. TOKENS.md lists exactly the tokens templates use.
#   5. the AgentRun confinement policy admits a run's objects and refuses everything D15 forbids, and Clearance's
#      argo.sync.lower grant admits only a sync of a -lower Application (skipped without envtest binaries in
#      KUBEBUILDER_ASSETS: tests/policy/test_agentrun_grants.py, test_argo_sync.py), and the tenant-onboarding delete guard
#      refuses only the ApplicationSet controller's delete of a tenant Application (test_tenant_delete_guard.py).
#
# The tests are the cases in tests/cases/ (one file each, named after the section of the old single script it was; the
# section names are still the `== ...` headers). tests/runner.py runs them 4-8 at a time, each in its own bash process
# (tests/case.sh: tests/lib.sh, then the case), prints each case's ok/FAIL lines in one piece when it ends, the failing
# cases' output again at the end, and the total; the exit status is nonzero if anything failed.
#
#   bash tests/run.sh                      every case
#   bash tests/run.sh -j 1                 one at a time
#   bash tests/run.sh gate-rule eks        those cases (and, as uncounted setup, the cases they read from)
#   bash tests/run.sh --group render --shard 2/4    what one CI job runs (.github/workflows/test.yaml)
#   bash tests/run.sh --list               the cases, their group, rough duration and needs
exec python3 "$(dirname "${BASH_SOURCE[0]}")/runner.py" "$@"
