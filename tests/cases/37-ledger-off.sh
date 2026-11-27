# tests/cases/37-ledger-off.sh (see tests/run.sh)
# group: render
# secs: 7
# needs: lab
# Off by default, and keys present but off render what absent keys render.
new "${TMP}/led-abs" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev --set versions.clearance.witnessImage=
mkdir -p "${TMP}/led-offprod" "${TMP}/led-offdev"
cp "${LAB}/prod/cluster.yaml" "${TMP}/led-offprod/cluster.yaml"
printf 'clearance:\n  ledger: {enabled: false}\n  witness: {enabled: false}\n' >>"${TMP}/led-offprod/cluster.yaml"
cp "${LAB}/dev/cluster.yaml" "${TMP}/led-offdev/cluster.yaml"
printf 'clearance:\n  ledger: {enabled: false}\n  witness: {enabled: false}\n' >>"${TMP}/led-offdev/cluster.yaml"
render_ok "${TMP}/led-offprod" "ledger and witness explicitly off (prod)"
render_ok "${TMP}/led-offdev" "ledger and witness explicitly off (dev)"
expect "${TMP}/led-offprod" "witness off" '!56-clearance-witness'
expect "${TMP}/led-offdev" "ledger off" '!55-clearance/clearance-config/ledger-key.yaml'
if grep -rnE 'ledger|witness' "${TMP}/led-offdev/${CA}" "${TMP}/led-offprod/30-policy/kyverno-policies/flight-images.yaml" 2>/dev/null | grep -v '^[^:]*:[0-9]*: *#' | grep -q .; then
  bad "ledger/witness off: a value leaked into the core's Application or Flight admission"
else
  ok "ledger/witness off: nothing in the core's Application or Flight admission"
fi
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/dev" "${TMP}/led-offdev" >/dev/null; then ok "ledger/witness keys off == absent (dev), byte for byte"; else bad "ledger/witness off differs from absent (dev)"; fi
if diff -r --exclude=cluster.yaml --exclude=.apron-rendered "${LAB}/prod" "${TMP}/led-offprod" >/dev/null; then ok "ledger/witness keys off == absent (prod), byte for byte"; else bad "ledger/witness off differs from absent (prod)"; fi
# Refusals: render-time (image) and check-time.
new "${TMP}/led-noimg" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${WIT_SET[@]}" --set 'versions.clearance.witnessImage='
if python3 hack/render.py --cluster "${TMP}/led-noimg/cluster.yaml" >/dev/null 2>&1; then bad "witness on without versions.clearance.witnessImage rendered"; else ok "witness on without versions.clearance.witnessImage is refused"; fi
