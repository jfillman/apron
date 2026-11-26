# tests/cases/31-owned-project.sh (see tests/run.sh)
# group: render
# secs: 16
# needs: gate-opt
OC="${TMP}/gate-opt/55-clearance/clearance/application.yaml"
[ "$(grep -c 'app.kubernetes.io/name: argocd-repo-server' "${OC}")" = 1 ] && ok "gate with the core here: the core admits the repo-server" || bad "gate with the core here: the repo-server rule is missing or doubled"
[ "$(grep -c 'app.kubernetes.io/name: clearance-argocd-agent' "${OC}")" = 2 ] && ok "gate with the core here: the core and clearance-api admit the agent" || bad "gate with the core here: the agent rules are not exactly two (core, api)"
has "${TMP}/gate-opt/56-clearance-gate/admission.yaml" 'validationActions: \[Warn, Audit\]' "gate.lowerZone: Warn and Audit by default"
# clearance.gate.agent.ownedProject (W-40): the agent's own Namespaces and AppProjects, as an Application ahead of the agent
OWN_SET=(--set 'clearance.gate.agent.ownedProject={create: true}')
new "${TMP}/gate-own" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "${OWN_SET[@]}"
render_ok "${TMP}/gate-own" "gate agent ownedProject.create"
expect "${TMP}/gate-own" "ownedProject.create" 56-clearance-gate/agent/owned.yaml
OWNF="${TMP}/gate-own/56-clearance-gate/agent/owned.yaml"
has "${OWNF}" '^kind: Namespace$' "ownedProject: a Namespace"
has "${OWNF}" '^  name: "rehearsal"$' "ownedProject: the protected namespace's name"
has "${OWNF}" '^kind: AppProject$' "ownedProject: an AppProject"
has "${OWNF}" '^  namespace: argocd-apps$' "ownedProject: the AppProject is in argocd-apps (where the agent reads)"
has "${OWNF}" '^    - \{server: https://kubernetes.default.svc, namespace: "rehearsal"\}$' "ownedProject: the project deploys only into the protected namespace"
has "${OWNF}" '^    - "https://github.com/acme/gitops-cluster-hangar-dev"$' "ownedProject: sourceRepos defaults to the cluster's gitops repository"
has "${OWNF}" 'sync-options: Prune=false,Delete=false' "ownedProject: never pruned or deleted by Argo CD"
if [ "$(grep -c 'sync-wave: "-1"' "${OWNF}")" = 1 ] && [ "$(grep -c 'sync-wave: "0"' "${OWNF}")" = 1 ]; then ok "ownedProject: Namespace wave -1, AppProject wave 0"; else bad "ownedProject: waves are not Namespace -1, AppProject 0"; fi
OWNA="${TMP}/gate-own/56-clearance-gate/agent/application.yaml"
has "${OWNA}" '^  sources:$' "ownedProject: the agent Application has two sources (one sync, so the wave order holds)"
has "${OWNA}" '^    path: 56-clearance-gate/agent$' "ownedProject: the first source is the agent folder (owned.yaml)"
has "${OWNA}" '^    chart: clearance-argocd-agent$' "ownedProject: the chart is the second source"
if grep -q '^  source:$' "${OWNA}"; then bad "ownedProject: the agent Application still has a single source"; else ok "ownedProject: no single source left beside sources"; fi
if grep -q 'sync-wave' "${OWNA}"; then bad "ownedProject: the agent Application carries a wave itself"; else ok "ownedProject: no wave on the Application (waves order the resources inside one sync)"; fi
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); s=d["spec"]["sources"]; assert len(s)==2 and s[0]["path"]=="56-clearance-gate/agent" and s[1]["chart"]=="clearance-argocd-agent" and s[1]["helm"]["releaseName"]=="clearance-argocd-agent" and "source" not in d["spec"], d["spec"]' "${OWNA}" && ok "ownedProject: the agent Application parses with the git source then the chart" || bad "ownedProject: the agent Application's sources are wrong"; fi
has "${TMP}/gate-opt/56-clearance-gate/agent/application.yaml" '^  source:$' "ownedProject unset: the agent Application keeps its single source"
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=list(yaml.safe_load_all(open(sys.argv[1]))); assert [x["kind"] for x in d]==["Namespace","AppProject"] and d[1]["spec"]["destinations"]==[{"server":"https://kubernetes.default.svc","namespace":"rehearsal"}], d' "${OWNF}" && ok "ownedProject: owned.yaml parses as Namespace then AppProject" || bad "ownedProject: owned.yaml does not parse as Namespace, AppProject"; fi
for F in 56-clearance-gate/application.yaml 56-clearance-gate/admission.yaml 56-clearance-gate/clearancegrant-crd.yaml; do
  cmp -s "${TMP}/gate-own/${F}" "${TMP}/gate-opt/${F}" && ok "ownedProject: ${F} is byte for byte as without it" || bad "ownedProject: ${F} differs from the render without it"
done
new "${TMP}/gate-own-multi" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.gate.agent.ownedProject={create: true, sourceRepos: ["https://github.com/acme/one", "https://github.com/acme/two"]}' \
  --set 'clearance.gate.agent.projects=[p-one, p-two]' --set 'clearance.gate.agent.protectedNamespaces=[ns-one, ns-two]'
render_ok "${TMP}/gate-own-multi" "ownedProject, two projects and two namespaces"
OWNM="${TMP}/gate-own-multi/56-clearance-gate/agent/owned.yaml"
[ "$(grep -c '^kind: Namespace$' "${OWNM}")" = 2 ] && [ "$(grep -c '^kind: AppProject$' "${OWNM}")" = 2 ] && ok "ownedProject: a Namespace per namespace, an AppProject per project" || bad "ownedProject: wrong object counts"
[ "$(grep -c 'namespace: "ns-two"}' "${OWNM}")" = 2 ] && ok "ownedProject: each project may deploy into every protected namespace" || bad "ownedProject: destinations are not every namespace for each project"
has "${OWNM}" '^    - "https://github.com/acme/two"$' "ownedProject: sourceRepos as given"
new "${TMP}/gate-own-null" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" "${OWN_SET[@]}" \
  --set 'clearance.gate.agent.projects=["null"]' --set 'clearance.gate.agent.protectedNamespaces=["true"]'
render_ok "${TMP}/gate-own-null" "ownedProject with names YAML would read as null and true"
if $HAVE_YAML; then python3 -c 'import sys,yaml; d=list(yaml.safe_load_all(open(sys.argv[1]))); assert d[0]["metadata"]["name"]=="true" and d[1]["metadata"]["name"]=="null" and d[1]["spec"]["destinations"][0]["namespace"]=="true", d' "${TMP}/gate-own-null/56-clearance-gate/agent/owned.yaml" && ok "ownedProject: names are quoted, so null and true stay strings" || bad "ownedProject: a name was read as a non-string"; fi
new "${TMP}/gate-own-off" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
  --set 'clearance.gate.agent.ownedProject={create: false}'
render_ok "${TMP}/gate-own-off" "ownedProject create false"
expect "${TMP}/gate-own-off" "ownedProject.create false" '!56-clearance-gate/agent/owned.yaml'
expect "${TMP}/gate-opt" "ownedProject unset" '!56-clearance-gate/agent/owned.yaml'
diff -r "${TMP}/gate-own-off/56-clearance-gate" "${TMP}/gate-opt/56-clearance-gate" >/dev/null 2>&1 && cmp -s "${TMP}/gate-own-off/.apron-rendered" "${TMP}/gate-opt/.apron-rendered" && ok "ownedProject create false renders byte for byte what unset does (the gate files and the rendered list; generated passwords elsewhere differ per new_cluster)" || bad "ownedProject create false differs from unset"
for BADP in "clearance.gate.agent.ownedProject=yes|ownedProject is a map" "clearance.gate.agent.ownedProject={create: maybe}|ownedProject.create is true or false" \
            "clearance.gate.agent.ownedProject={create: true, typo: 1}|ownedProject.typo is not a setting" \
            "clearance.gate.agent.ownedProject={create: true, sourceRepos: []}|ownedProject.sourceRepos is a non-empty list" \
            "clearance.gate.agent.projects=[default]|would own the AppProject 'default'" \
            "clearance.gate.agent.protectedNamespaces=[Bad_NS]|needs clearance.gate.agent.protectedNamespaces to be a list of DNS labels"; do
  BAD="${BADP%%|*}"; WANT="${BADP#*|}"
  new "${TMP}/gate-own-bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${OPT_SET[@]}" \
    --set 'clearance.gate.agent.ownedProject={create: true}' --set "${BAD}"
  BADERR="$(python3 hack/render.py --cluster "${TMP}/gate-own-bad/cluster.yaml" 2>&1 >/dev/null)"; BADRC=$?
  if [ "${BADRC}" -ne 0 ] && grep -qF -- "${WANT}" <<<"${BADERR}"; then ok "ownedProject ${BAD}: refused (${WANT})"; else bad "ownedProject ${BAD}: rc=${BADRC} ${BADERR}"; fi
done
