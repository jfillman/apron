# tests/lib.sh - what every case in tests/cases/ shares: the counters, the helpers and the settings more than one case uses.
# tests/case.sh sources it, then one case file; tests/run.sh runs the cases. TMP is the run's directory, shared by every
# case of the run (tests/run.sh makes it and removes it): a case writes only its own paths under it and reads another's only
# when it names that case in its `# needs:` line, so the other has finished first.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
APRON="$(pwd)"
TMP="${APRON_TEST_TMP:?tests/lib.sh: APRON_TEST_TMP is unset (run the cases with tests/run.sh)}"
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
# `apron render` compares versions.glidepathRunTasks with the pinned Glidepath's values (hack/glidepath_tasks.py); the tests use a
# fixture, not the network.
export APRON_GLIDEPATH_VALUES="${APRON}/tests/policy/fixtures/glidepath-control-plane-values.yaml"
OLD='kind-dev|kiac-dev|kind-prod|kiac-prod|kind-man|kiac-man|kiac\.local|jfillman|gitops-cluster-dev\b|gitops-cluster-kind|192\.168\.1\.78|700017004810'
HAVE_YAML=false
python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=true

new() { # new DIR PROFILE NAME RUNTIME [more new_cluster.py flags]
  local dir="$1" profile="$2" name="$3" runtime="$4"; shift 4
  mkdir -p "${dir}"
  python3 hack/new_cluster.py --profile "${profile}" --name "${name}" --runtime "${runtime}" "$@" >"${dir}/cluster.yaml"
}

render_ok() { # render_ok DIR LABEL
  local dir="$1" label="$2" out
  if ! out="$(python3 hack/render.py --cluster "${dir}/cluster.yaml" 2>&1)"; then
    bad "${label}: render failed: ${out}"
    return
  fi
  ok "${label}: $(head -1 <<<"${out}" | sed 's/ into .*:/:/')"
  local leftovers olds
  leftovers="$(grep -rn '@@' "${dir}" --exclude=cluster.yaml | head -3)"
  [ -z "${leftovers}" ] && ok "${label}: no @@ left" || bad "${label}: leftover @@: ${leftovers}"
  olds="$(grep -rnE "${OLD}" "${dir}" | head -3)"
  [ -z "${olds}" ] && ok "${label}: no old cluster names, owner or lab addresses" || bad "${label}: old literals: ${olds}"
  if [ "${HAVE_YAML}" = true ]; then
    local yerr
    yerr="$(python3 - "${dir}" <<'PY'
import os, sys, yaml
bad = []
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        p = os.path.join(d, f)
        # Helm chart templates (Go templates) and ApplicationSet templates are not plain YAML.
        if not f.endswith((".yaml", ".yml")) or "/chart/templates/" in p or f.endswith(".tmpl.yaml"):
            continue
        try:
            list(yaml.safe_load_all(open(p)))
        except Exception as e:
            bad.append(f"{p}: {str(e).splitlines()[0]}")
print("\n".join(bad))
PY
)"
    [ -z "${yerr}" ] && ok "${label}: every YAML file parses" || bad "${label}: YAML: ${yerr}"
  fi
  local sh
  for sh in $(find "${dir}" -name '*.sh'); do
    bash -n "${sh}" && ok "${label}: bash -n ${sh#"${dir}"/}" || bad "${label}: bash -n ${sh}"
  done
}

expect() { # expect DIR LABEL WANT_PATH|!PATH ...
  local dir="$1" label="$2"; shift 2
  local p
  for p in "$@"; do
    if [[ "${p}" == !* ]]; then
      [ ! -e "${dir}/${p#!}" ] && ok "${label}: no ${p#!}" || bad "${label}: ${p#!} should not be rendered"
    else
      [ -e "${dir}/${p}" ] && ok "${label}: has ${p}" || bad "${label}: missing ${p}"
    fi
  done
}

has() { # has FILE REGEX LABEL
  grep -qE -- "$2" "$1" && ok "$3" || bad "$3 ($1 lacks /$2/)"
}


# Shared by several cases (each was set in the section that first used it).
LAB="${TMP}/lab"
K="${TMP}/eks"
ISS=https://oidc.eks.us-east-1.amazonaws.com/id
INF=https://infisical.aws.example.dev/api
CERT=arn:aws:acm:us-east-1:111111111111:certificate/abc
GATE_SET=(--set clearance.gate.enabled=true --set 'clearance.protectedEnvironments=[hangar-prod/prod]'
  --set versions.clearance.cmpImage=ghcr.io/acme/clearance-cmp@sha256:aaaa --set versions.clearance.waitImage=ghcr.io/acme/clearance-wait@sha256:bbbb --set versions.clearance.previousWaitImage=)
AGENT_SET=(--set clearance.gate.url=http://clearance.hangar-dev.local --set clearance.gate.hostAlias=192.0.2.1=clearance.hangar-dev.local
  --set 'clearance.gate.apps=[gate-api]' --set clearance.gate.agent.apiURL=http://clearance-api.hangar-dev.local
  --set 'clearance.gate.agent.projects=[gate-api]' --set 'clearance.gate.agent.protectedNamespaces=[app-gate-api-prod]'
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc --set versions.clearance.argocdAgentChart=0.55.0)
i44() { # i44 NAME [more --set flags]: a prod cluster with the gate and its agent
  local d="${TMP}/$1"; shift
  new "${d}" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" "${AGENT_SET[@]}" "$@"
}
i44_refused() { # i44_refused NAME TEXT LABEL: render and check both refuse, naming TEXT
  local out
  out="$(python3 hack/render.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: rendered"; return; }
  grep -qF -- "$2" <<<"${out}" || { bad "$3: render's refusal: ${out}"; return; }
  out="$(python3 hack/check.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: check accepted it"; return; }
  grep -qF -- "$2" <<<"${out}" && ok "$3 is refused" || bad "$3: check's refusal: ${out}"
}
OPT_PROV='clearance.extraProviders=[{name: argocd-agent-dev, version: "0.51.0", principals: [clearance-system/clearance-argocd-agent], protection: ["clearance-system/clearance-argocd-agent=hangar-dev"]}]'
OPT_SET=(--set clearance.gate.enabled=true --set clearance.gate.lowerZone=true --set clearance.gate.tenantPlugin=false
  --set versions.clearance.cmpImage=ghcr.io/acme/clearance-cmp@sha256:aaaa --set versions.clearance.waitImage=ghcr.io/acme/clearance-wait@sha256:bbbb --set versions.clearance.previousWaitImage=
  --set versions.clearance.argocdAgentImage=ghcr.io/acme/clearance-argocd-agent@sha256:cccc
  --set clearance.gate.agent.apiURL=http://clearance-api.clearance-system.svc:8080 --set 'clearance.gate.agent.projects=[rehearsal]'
  --set 'clearance.gate.agent.protectedNamespaces=[rehearsal]' --set clearance.gate.agent.environment=dev --set clearance.gate.agent.optIn=true
  --set "${OPT_PROV}")
RULE1='clearance.gate.agent.rule={version: 1, select: [{name: rehearsal, projects: [rehearsal], namespaces: [rehearsal]}, {name: prod-label, projects: [rehearsal], labels: {hangar.io/env: "prod"}}], exempt: [{application: argocd-apps/web-prod, reason: "a migration to the new chart", expires: "2026-12-19", ref: W-45}]}'
rule() { # rule NAME [more --set flags]: the dev opt-in rehearsal (OPT_SET) with more settings
  local d="${TMP}/$1"; shift
  new "${d}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "$@"
}
rule_refused() { # rule_refused NAME TEXT LABEL: check and render both refuse, naming TEXT
  local out
  out="$(python3 hack/check.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: check accepted it"; return; }
  grep -qF -- "$2" <<<"${out}" || { bad "$3: check's refusal: ${out}"; return; }
  out="$(python3 hack/render.py --cluster "${TMP}/$1/cluster.yaml" 2>&1)" && { bad "$3: rendered"; return; }
  grep -qF -- "$2" <<<"${out}" && ok "$3 is refused" || bad "$3: render's refusal: ${out}"
}
# Public keys only (clearance ledger keygen prints them): the log's verifier key and the witness's cosignature key.
LOGK='hangarplatform.dev/clearance/hangar-dev+108edc37+AetdxRXum9f4nBr0a6ahyidBM9om7vJErTsu6/TYqQkc'
WITK='hangarplatform.dev/witness/hangar-prod+df3c5653+BFmnD24M4mdUFnMP9nWpmurlGFfwfX3QK3zYcpjFtlEW'
WITNESS_IMG=ghcr.io/acme/clearance-witness@sha256:2222222222222222222222222222222222222222222222222222222222222222
LEDGER_SET=(--set clearance.ledger.enabled=true --set "clearance.ledger.witnesses=[{name: hangar-prod, vkey: ${WITK}, url: http://witness.hangar-prod.local}]"
  --set clearance.ledger.hostAlias=192.0.2.9=witness.hangar-prod.local)
WIT_SET=(--set clearance.witness.enabled=true --set clearance.witness.name=hangar-prod --set "clearance.witness.logsVkeys=[${LOGK}]"
  --set "versions.clearance.witnessImage=${WITNESS_IMG}" --set registries.flight.host=ghcr.io --set registries.flight.namespace=acme-flight
  --set promotion.promoter.repo=acme-flight/promoter --set admission.flight.enabled=true)
CA=55-clearance/clearance/application.yaml
OBS_SET=(--set clearance.observe.enabled=true --set 'clearance.observe.protectedNamespaces=[app-a-prod]' --set 'clearance.observe.kubeletNodes=[node-a]' --set clearance.observe.serviceIP=10.96.200.50
  --set versions.clearance.observeK8sImage=ghcr.io/acme/clearance-observe-k8s@sha256:3333333333333333333333333333333333333333333333333333333333333333)
AWS_IMG=ghcr.io/acme/clearance-observe-aws@sha256:4444444444444444444444444444444444444444444444444444444444444444
AWS_SET=(--set clearance.observeAWS.enabled=true --set clearance.observeAWS.account=111122223333 --set clearance.observeAWS.queueURL=https://sqs.us-east-1.amazonaws.com/111122223333/observe
  --set clearance.observeAWS.roleARN=arn:aws:iam::111122223333:role/observe --set 'clearance.observeAWS.applyRoles=[deployer]'
  --set 'clearance.observeAWS.governedAccounts=[444455556666]' --set 'clearance.extraAuditors=[clearance-system/clearance-observe-aws]'
  --set versions.clearance.observeAWSImage="${AWS_IMG}")
SLACK_COMMON=(--set versions.clearance.chart=0.47.1 --set 'clearance.people=[alice]' --set clearance.slack.enabled=true
  --set clearance.slack.publicUrl=https://slack.clearance.example.com --set clearance.slack.slackClientId=1234.5678
  --set 'clearance.slack.routes={groups: {"group:default/payments": C0123456789}, security: C0SECURITY, ops: C0OPSOPSOPS}')
SLACK_DNS=(--set clearance.slack.tls.mode=dns01-route53 --set clearance.slack.tls.dns01.hostedZoneID=Z0123456789ABC
  --set clearance.slack.tls.dns01.email=ops@example.com --set clearance.slack.tls.dns01.roleARN=arn:aws:iam::111122223333:role/dns01
  --set clearance.slack.idp.hostAlias=192.0.2.10)
refuse() { # refuse LABEL BASE-DIR YAML-TO-APPEND...
  local label="$1" base="$2"; shift 2
  local d
  d="$(mktemp -d "${TMP}/refuse-XXXXXX")"
  mkdir -p "${d}"
  cp "${base}/cluster.yaml" "${d}/cluster.yaml"
  printf '%s\n' "$@" >>"${d}/cluster.yaml"
  if python3 hack/check.py --cluster "${d}/cluster.yaml" >/dev/null 2>"${d}/err"; then
    bad "check accepted: ${label}"
  else
    ok "refuses ${label}: $(head -1 "${d}/err" | cut -c8-110)"
  fi
}
