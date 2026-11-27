# tests/cases/41-coverage-cache.sh (see tests/run.sh)
# group: render
# secs: 7
# needs: lab
echo "== 1c-4b. clearance-api's coverage cache (clearance.api.coverageCacheSeconds, off by default)"
new "${TMP}/cov-on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set clearance.api.coverageCacheSeconds=30
render_ok "${TMP}/cov-on" "coverage cache on"
python3 hack/check.py --cluster "${TMP}/cov-on/cluster.yaml" >/dev/null && ok "coverage cache on passes check" || bad "coverage cache on fails check"
has "${TMP}/cov-on/${CA}" '^          coverageCacheSeconds: 30$' "coverage cache on: the chart's api.coverageCacheSeconds is 30"
if grep -rq 'coverageCacheSeconds' "${LAB}/dev" "${LAB}/prod"; then bad "coverage cache default: coverageCacheSeconds rendered"; else ok "coverage cache default: not rendered (chart default, off)"; fi
mkdir -p "${TMP}/cov-offdev"
cp "${LAB}/dev/cluster.yaml" "${TMP}/cov-offdev/cluster.yaml"
printf 'clearance:\n  api: {coverageCacheSeconds: 0}\n' >>"${TMP}/cov-offdev/cluster.yaml"
render_ok "${TMP}/cov-offdev" "coverage cache explicitly 0"
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/cov-offdev" >/dev/null; then ok "coverage cache 0 == absent, byte for byte"; else bad "coverage cache 0 differs from absent"; fi
