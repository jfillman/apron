#!/usr/bin/env bash
# Build signing-pki/fulcio-chain.pem and signing-pki/trusted-root.json in a cluster's repo from the public certificates
# committed there (docs/signing-pki.md). Public material only: this script refuses a file holding a private key, and
# never reads Infisical or the cluster.
#
#   hack/build-trust-root.sh <cluster repo dir> --new-start <RFC3339> --legacy-end <RFC3339> [--fulcio-url U] [--rekor-url U]
#
# Inputs, in <cluster repo dir>/signing-pki/:
#   root.pem                 Hangar Root CA (public certificate)
#   intermediate.pem         "Hangar Fulcio <cluster>" (public certificate)
#   rekor.pub                the new Rekor signing key's PUBLIC half (openssl pkey -in signer.pem -pubout)
#   legacy-fulcio-root.pem   the self-generated root served before the cutover (the fulcio-root-ca ConfigMap's cert.pem)
#   legacy-rekor.pub         the old Rekor key (GET /api/v1/log/publicKey before the cutover)
# Outputs: fulcio-chain.pem (intermediate then root, what Fulcio serves and fulcio-root-ca publishes) and trusted-root.json.
# The windows: the new chain and key are trusted from --new-start; the legacy root and key until --legacy-end, which must
# be after the last signature the old Fulcio and Rekor make (the flip, plus an hour).
# Needs `clearance` on PATH (a release asset of jfillman/clearance, v0.34.0 or later).
set -euo pipefail
dir="${1:?usage: $0 <cluster repo dir> --new-start T --legacy-end T}"; shift
new_start="" legacy_end="" fulcio_url="http://fulcio-server.fulcio-system.svc" rekor_url="http://rekor-server.rekor-system.svc"
while [ $# -gt 0 ]; do
  case "$1" in
    --new-start) new_start="${2:?}"; shift 2 ;;
    --legacy-end) legacy_end="${2:?}"; shift 2 ;;
    --fulcio-url) fulcio_url="${2:?}"; shift 2 ;;
    --rekor-url) rekor_url="${2:?}"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "${new_start}" ] && [ -n "${legacy_end}" ] || { echo "--new-start and --legacy-end are required (RFC3339, e.g. 2026-11-10T14:00:00Z)" >&2; exit 2; }
d="${dir}/signing-pki"
for f in root.pem intermediate.pem rekor.pub legacy-fulcio-root.pem legacy-rekor.pub; do
  [ -s "${d}/${f}" ] || { echo "missing ${d}/${f}" >&2; exit 1; }
  if grep -q "PRIVATE KEY" "${d}/${f}"; then echo "${d}/${f} holds a private key: refusing" >&2; exit 1; fi
done
command -v clearance >/dev/null || { echo "clearance is not on PATH" >&2; exit 1; }
cat "${d}/intermediate.pem" "${d}/root.pem" > "${d}/fulcio-chain.pem.tmp"
clearance trust-root build \
  --fulcio "${d}/fulcio-chain.pem.tmp,start=${new_start}" \
  --fulcio "${d}/legacy-fulcio-root.pem,end=${legacy_end}" \
  --rekor "${d}/rekor.pub,start=${new_start}" \
  --rekor "${d}/legacy-rekor.pub,end=${legacy_end}" \
  --fulcio-uri "${fulcio_url}" --rekor-url "${rekor_url}" \
  --out "${d}/trusted-root.json.tmp"
mv "${d}/fulcio-chain.pem.tmp" "${d}/fulcio-chain.pem"
mv "${d}/trusted-root.json.tmp" "${d}/trusted-root.json"
echo "wrote ${d}/fulcio-chain.pem and ${d}/trusted-root.json"
