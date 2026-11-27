# tests/cases/18-gate-on.sh (see tests/run.sh)
# group: render
# secs: 26
# needs: clearance-gate
echo "== 1b. the Argo CD gate(clearance.gate.enabled: the plugin sidecar and the ApplicationSet's plugin source)"
new "${TMP}/gate" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local
render_ok "${TMP}/gate" "gate on"
AS="${TMP}/gate/02-argocd-apps/tenant-onboarding/chart/applicationset.tmpl.yaml"
has "${AS}" 'name: clearance$' "gate on: the ApplicationSet has the Clearance plugin source"
has "${AS}" 'regexMatch "\^hangar\[-\]prod\[/\]prod\$"' "gate on: only clearance.protectedEnvironments are gated, as a regex with no backslash"
has "${AS}" 'name: valueFiles, string: "hangar-prod/base.yaml,hangar-prod/\{\{.env\}\}/values.yaml,hangar-prod/\{\{.env\}\}/release.yaml"' \
  "gate on: the plugin gets all three value files and skips absent ones (the Helm source's ignoreMissingValueFiles)"
has "${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml" 'name: clearance-cmp' "gate on: repo-server has the plugin sidecar"
has "${AS}" 'regexMatch "\^\.\*\$" .appName' "gate on without gate.apps: every app in a protected environment"
CMPENV="${TMP}/gate/01-argocd-platform/argocd-apps-install/application.yaml"
has "${CMPENV}" 'name: CLEARANCE_CHART_REPOS, value: "https://github.com/acme/airframe.git"' "gate on: the sidecar's chart allow list is the cluster's airframe repository, set by the platform"
new "${TMP}/gate-more" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set clearance.gate.url=http://clearance.hangar-dev.local \
  --set 'allowedChartRepos=[https://github.com/acme/team-charts.git]'
render_ok "${TMP}/gate-more" "gate on with allowedChartRepos"
has "${TMP}/gate-more/01-argocd-platform/argocd-apps-install/application.yaml" 'name: CLEARANCE_CHART_REPOS, value: "https://github.com/acme/airframe.git,https://github.com/acme/team-charts.git"' "allowedChartRepos: the plugin's list is airframe plus those repositories (the union Argo CD allows)"
has "${TMP}/gate-more/02-argocd-apps/tenant-appprojects/applicationset.yaml" 'allowedChartRepos: \["https://github.com/acme/team-charts.git"\]' "allowedChartRepos: the tenant AppProjects get the same repositories"
has "${TMP}/gate/02-argocd-apps/tenant-appprojects/applicationset.yaml" 'allowedChartRepos: \[\]' "no allowedChartRepos: the AppProjects allow only Airframe's"
new "${TMP}/gate-badrepo" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'allowedChartRepos=["https://x.test/a,b"]'
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-badrepo/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "allowedChartRepos: 'https://x.test/a,b' is a repository URL" <<<"${BADERR}"; then ok "allowedChartRepos entry with a comma is refused with its validation error"; else bad "allowedChartRepos comma entry: rc=${BADRC} ${BADERR}"; fi
for BAD in 'allowedChartRepos={a: b}' 'allowedChartRepos=https://x.test/a'; do
  new "${TMP}/gate-badtype" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
    --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-badtype/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -q "allowedChartRepos must be a list of repository URL strings" <<<"${BADERR}"; then ok "${BAD}: refused as not a list of strings"; else bad "${BAD}: rc=${BADRC} ${BADERR}"; fi
done
new "${TMP}/gate-nohost" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${GATE_SET[@]}" --set 'allowedChartRepos=[https:///only/a/path]'
BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-nohost/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
if [ "${BADRC}" -ne 0 ] && grep -q "has no host name" <<<"${BADERR}"; then ok "allowedChartRepos entry with no host name is refused with its validation error"; else bad "allowedChartRepos no host: rc=${BADRC} ${BADERR}"; fi
DEFREPO="$(sed -n 's/^  repoURL: //p' "${TMP}/gate/cluster-defaults.yaml" | head -1)"
if [ -n "${DEFREPO}" ] && grep -qF "name: CLEARANCE_CHART_REPOS, value: \"${DEFREPO}\"" "${CMPENV}"; then ok "gate on: the allow list names the same repository as cluster-defaults.yaml's defaultChart"; else bad "gate on: allow list differs from defaultChart.repoURL (${DEFREPO})"; fi
if grep -n 'CLEARANCE_CHART_REPOS' "${AS}" | grep -v '^[0-9]*: *#' | grep -q .; then bad "gate on: the allow list is set in the ApplicationSet (a plugin parameter a tenant value could reach)"; else ok "gate on: the allow list is not an ApplicationSet parameter"; fi
for P in chartRepo chartRevision chartPath; do
  has "${AS}" "name: ${P}, string: '\{\{ dig .* \| replace \"'\" \"''\" \}\}'\}" "gate on: plugin parameter ${P} doubles a quote in its value, so identity.yaml cannot add a parameter"
done
[ ! -e "${TMP}/gate/56-clearance-gate/agent/application.yaml" ] && ok "gate on without gate.agent: no agent" || bad "gate on without gate.agent: the agent rendered"
