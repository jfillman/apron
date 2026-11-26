# tests/cases/08-signing.sh (see tests/run.sh)
# group: render
# secs: 4
# needs: lab
echo "== 1a. signing PKI (C-2a: off by default; the flags render the public chain, the trusted root and Clearance's keyless wiring)"
SIGOFF="${LAB}/dev"
if grep -q '^sigstore:' "${SIGOFF}/50-glidepath/glidepath-control-plane/values.yaml"; then bad "signing off: managedKeys rendered"; else ok "signing off: the control plane keeps its bootstrap hooks"; fi
if grep -rq 'fulcio-server.fulcio-system\|keyless:' "${SIGOFF}/55-clearance"; then bad "signing off: keyless wiring rendered"; else ok "signing off: Clearance attests nothing"; fi
SG="${TMP}/signing"
new "${SG}" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme \
  --tower-cluster hangar-prod --set signing.managedKeys=true --set signing.trustedRoot=true --set clearance.attestation.keyless=true
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "signing on without signing-pki/: rendered"; else
  ok "signing on without signing-pki/: refused ($(grep -o 'signing-pki/[a-z.-]* is missing' "${TMP}/sg-out" | head -1))"; fi
mkdir -p "${SG}/signing-pki"
printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
printf '{"mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1"}\n' >"${SG}/signing-pki/trusted-root.json"
render_ok "${SG}" "signing on"
V="${SG}/50-glidepath/glidepath-control-plane/values.yaml"
has "${V}" '^    enabled: true$' "signing on: sigstore.managedKeys.enabled"
has "${V}" '^    rootCaPem: "-----BEGIN CERTIFICATE-----\\nAAAA' "signing on: the chain is the cluster repo's fulcio-chain.pem"
has "${V}" '^    trustedRootJson: "\{' "signing on: the trusted root is published"
C="${SG}/55-clearance/clearance/application.yaml"
has "${C}" 'fulcioUrl: "http://fulcio-server.fulcio-system.svc"' "keyless: the in-cluster Fulcio"
has "${C}" 'rekorUrl: "http://rekor-server.rekor-system.svc"' "keyless: the in-cluster Rekor"
has "${C}" 'audience: "sigstore"' "keyless: the audience Fulcio's issuer entry expects"
has "${C}" 'kubernetes.io/metadata.name: fulcio-system' "keyless: egress to fulcio-system"
has "${C}" 'port: 5555' "keyless: egress on Fulcio's pod port"
has "${C}" 'port: 3000' "keyless: egress on Rekor's pod port"
printf -- '-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "a private key in signing-pki/: rendered"; else ok "a private key in signing-pki/: refused"; fi
printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' >"${SG}/signing-pki/fulcio-chain.pem"
printf -- '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n' >"${SG}/signing-pki/root.pem"
if python3 hack/render.py --cluster "${SG}/cluster.yaml" >"${TMP}/sg-out" 2>&1; then bad "a private key in another signing-pki/ file: rendered"; else ok "a private key in any signing-pki/ file: refused"; fi
# hack/build-trust-root.sh refuses a private key too, before it needs clearance
mkdir -p "${TMP}/bt/signing-pki"
for f in root.pem intermediate.pem rekor.pub legacy-fulcio-root.pem legacy-rekor.pub; do echo x >"${TMP}/bt/signing-pki/${f}"; done
echo '-----BEGIN PRIVATE KEY-----' >"${TMP}/bt/signing-pki/root.pem"
if hack/build-trust-root.sh "${TMP}/bt" --new-start 2026-11-10T00:00:00Z --legacy-end 2026-11-10T02:00:00Z >/dev/null 2>"${TMP}/bt-err"; then
  bad "build-trust-root.sh accepted a private key"; else ok "build-trust-root.sh refuses a private key: $(head -1 "${TMP}/bt-err" | cut -c1-70)"; fi
