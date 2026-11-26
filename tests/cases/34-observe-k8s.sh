# tests/cases/34-observe-k8s.sh (see tests/run.sh)
# group: render
# secs: 4
# needs: ledger
echo "== 1c-2. the Kubernetes audit collector (clearance O-3)"
new "${TMP}/obs-prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${OBS_SET[@]}"
render_ok "${TMP}/obs-prod" "collector on"
OA="${TMP}/obs-prod/57-clearance-observe/application.yaml"
has "${OA}" 'tag: "v[0-9.]+@sha256:[0-9a-f]{64}"' "collector on: the image is pinned by digest"
has "${OA}" 'clusterIP: "10.96.200.50"' "collector on: the pinned ClusterIP"
has "${OA}" 'kubeletNodes: \["node-a"\]' "collector on: the kubelet nodes"
has "${OA}" 'namespace: argocd-apps$' "collector on: the Argo CD namespace"
has "${OA}" 'system:serviceaccount:argocd-apps:argocd-application-controller' "collector on: that instance's controller"
expect "${TMP}/led-prod" "collector off" '!57-clearance-observe/application.yaml'
new "${TMP}/obs-bad" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set clearance.observe.enabled=true --set 'clearance.observe.protectedNamespaces=[app-a-prod]'
# Capture first: under pipefail, the render's own exit 1 would fail a `render | grep` even when grep matches.
OBS_ERR="$(python3 hack/render.py --cluster "${TMP}/obs-bad/cluster.yaml" 2>&1 || true)"
grep -q 'clearance.observe.serviceIP is required' <<<"${OBS_ERR}" && ok "collector on without a serviceIP refuses" || bad "collector on without a serviceIP should be refused by name: ${OBS_ERR}"
