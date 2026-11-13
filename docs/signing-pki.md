# Signing PKI (C-2a)

Status: **Built, not live.** Everything here is off by default and a cluster that sets none of it renders byte for byte
as before. The procedure is Glidepath's
[Signing PKI cutover](https://github.com/<owner>/glidepath/blob/main/docs/admin/signing-pki-cutover.md); this page is
the Apron side: the flags, the files and what each one renders.

## The flags (`cluster.yaml`)

| Key | Renders | Needs |
|---|---|---|
| `signing.trustedRoot: true` | `sigstore.managedKeys.trustedRootJson` in the control plane's values: the ConfigMap `hangar-trusted-root` (platform-catalog), the Sigstore TrustedRoot every Glidepath verify task and `glidepath-api` prefer when it exists | `signing-pki/trusted-root.json` |
| `signing.managedKeys: true` | `sigstore.managedKeys.enabled` and `rootCaPem`: the bootstrap hooks stop minting, ExternalSecrets build `fulcio-secret`, `fulcio-server-config` and `rekor-signer` from Infisical, and `fulcio-root-ca` becomes the new chain | `signing-pki/fulcio-chain.pem`, the four Infisical entries below |
| `clearance.attestation.keyless: true` | the Clearance chart's `attestation.keyless.fulcioUrl`, `attestation.rekorUrl`, `attestation.keyless.audience`, and the core's egress to Fulcio (fulcio-system, 5555) and Rekor (rekor-system, 3000) | `components.clearance`, a Clearance chart that accepts in-cluster `http` URLs (the clearance release that contains jfillman/clearance#77), Fulcio and Rekor on this cluster (`components.glidepath`) |

`clearance.attestation.fulcioUrl`, `.rekorUrl` and `.audience` override the defaults (`http://fulcio-server.fulcio-system.svc`,
`http://rekor-server.rekor-system.svc`, `sigstore`). `apron check` refuses each flag off the control plane.

Order matters: `signing.trustedRoot` first (safe: verifiers learn the new chain and keep the legacy one), then
`signing.managedKeys`, then `clearance.attestation.keyless`.

## The core's identity

Nothing to add to Fulcio's `config.yaml`: it already lists the cluster's issuer (`fulcio.publicIssuers`, the public
issuer, and the in-cluster default) as `type: kubernetes` with client-id `sigstore`, and sets no subject rule, so the core
is admitted. Its certificate's SAN is `https://kubernetes.io/namespaces/<clearance namespace>/serviceaccounts/clearance-core`
(namespace `clearance-system` on hangar-dev since R-10d; attestations made before the move carry `autopilot-system`, so a verifier of old and new evidence accepts both) and the issuer extension is the issuer that signed its token. Verifiers pin
exactly those with `clearance attest verify --identity ... --issuer ...`. clearance-api verifies stored attestations with the same
pinned pair and `signing-pki/trusted-root.json`, as public material in a ConfigMap (`api.attest.*`; [clearance-map.md](clearance-map.md)).

## `signing-pki/` (the cluster repo, next to `cluster.yaml`)

Public files only. `apron render` refuses a `signing-pki/` file that contains a private key, and never writes there.

| File | What | From |
|---|---|---|
| `root.pem` | Hangar Root CA certificate | the owner's key ceremony |
| `intermediate.pem` | "Hangar Fulcio `<cluster>`" certificate | the ceremony |
| `rekor.pub` | the new Rekor signing key's public half | `openssl pkey -in signer.pem -pubout` (owner) |
| `legacy-fulcio-root.pem` | the self-generated root served until the cutover | `kubectl -n platform-catalog get cm fulcio-root-ca -o jsonpath='{.data.cert\.pem}'`, before the flip |
| `legacy-rekor.pub` | the old Rekor key | `GET /api/v1/log/publicKey` on Rekor, before the flip |
| `fulcio-chain.pem`, `trusted-root.json` | generated | `hack/build-trust-root.sh <cluster repo> --new-start T --legacy-end T --rekor-start <legacy root start>` (needs `clearance`). Without `--rekor-start`, signatures from before the cutover stop verifying, because Rekor re-signs old entries with its new key when they are read |

## The Infisical entries (the owner creates them)

Project `glidepath-<cluster>`, environment `shared`, path `/`, read by `platform-secret-store`:
`hangar-fulcio-<cluster>-chain` (the chain PEM), `hangar-fulcio-<cluster>-key` (the encrypted intermediate key),
`hangar-fulcio-<cluster>-key-password`, `hangar-rekor-<cluster>-signer` (the Rekor private key, PKCS#8 PEM). Apron
creates none of them and no private key ever passes through this repo.
