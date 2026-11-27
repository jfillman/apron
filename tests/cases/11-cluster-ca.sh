# tests/cases/11-cluster-ca.sh (see tests/run.sh)
# group: render
# secs: 6
# needs: lab
echo "== 1-ca. trust-manager and the cluster CA (A-19)"
# Off by default: neither renders. On: the chart and its image are pinned (the image by digest), no public-CA package image runs,
# the CA is ECDSA P-256 with its key never rotated, and the Bundle writes ConfigMap hangar-cluster-ca (key ca.crt) to every namespace.
expect "${LAB}/dev" "dev/kiac default" '!10-crds-operators/trust-manager/application.yaml' '!10-crds-operators/cluster-ca/ca.yaml'
expect "${LAB}/prod" "prod/kind default" '!10-crds-operators/trust-manager/application.yaml' '!10-crds-operators/cluster-ca/ca.yaml'
CAD="${TMP}/cluster-ca"
new "${CAD}/on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.trustManager=true --set components.clusterCA=true
render_ok "${CAD}/on" "dev trustManager + clusterCA"
TMA="${CAD}/on/10-crds-operators/trust-manager/application.yaml"
CAY="${CAD}/on/10-crds-operators/cluster-ca/ca.yaml"
TMV="$(sed -n 's/^    chart: \(v[0-9.]*\)$/\1/p' <(sed -n '/^  trustManager:/,/imageDigest/p' versions.yaml))"
TMD="$(sed -n 's/^    imageDigest: \(sha256:[0-9a-f]*\)$/\1/p' <(sed -n '/^  trustManager:/,/imageDigest/p' versions.yaml))"
[ -n "${TMV}" ] && [ -n "${TMD}" ] && ok "versions.trustManager: chart ${TMV}, image ${TMD:0:19}..." || bad "versions.trustManager: no chart or digest read"
has "${TMA}" "targetRevision: ${TMV}$" "trust-manager: the chart is pinned from versions.trustManager.chart"
has "${TMA}" "tag: \"${TMV}\"" "trust-manager: the image tag is the chart version"
has "${TMA}" "digest: \"${TMD}\"" "trust-manager: the image index is pinned by digest"
has "${TMA}" 'namespace: cert-manager$' "trust-manager: installs into cert-manager, its trust namespace"
grep -A1 'defaultPackage:' "${TMA}" | grep -q 'enabled: false' && ok "trust-manager: no public-CA package image" || bad "trust-manager: defaultPackage is not off"
grep -A1 'secretTargets:' "${TMA}" | grep -q 'enabled: false' && ok "trust-manager: no Secret targets" || bad "trust-manager: secretTargets is not off"
has "${CAD}/on/10-crds-operators/cluster-ca/application.yaml" 'path: 10-crds-operators/cluster-ca$' "cluster CA: its own Application"
if [ "${HAVE_YAML}" = true ]; then
  if out="$(python3 - "${CAY}" <<'PY' 2>&1
import sys, yaml
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
bad = []
ca = docs[("Certificate", "hangar-cluster-ca")]
s = ca["spec"]
if not (s.get("isCA") is True and s.get("secretName") == "hangar-cluster-ca" and ca["metadata"].get("namespace") == "cert-manager"):
    bad.append("the CA Certificate is not isCA hangar-cluster-ca in cert-manager")
if s.get("privateKey") != {"algorithm": "ECDSA", "size": 256, "rotationPolicy": "Never"}:
    bad.append(f"CA key {s.get('privateKey')}")
if s.get("duration") != "87600h":
    bad.append("CA duration is not 10 years")
if s.get("issuerRef", {}).get("name") != "hangar-cluster-ca-bootstrap" or s["issuerRef"].get("kind") != "ClusterIssuer":
    bad.append("the CA is not signed by the bootstrap ClusterIssuer")
if docs[("ClusterIssuer", "hangar-cluster-ca-bootstrap")]["spec"] != {"selfSigned": {}}:
    bad.append("the bootstrap issuer is not self-signed")
if docs[("ClusterIssuer", "hangar-cluster-ca")]["spec"] != {"ca": {"secretName": "hangar-cluster-ca"}}:
    bad.append("the CA ClusterIssuer does not sign with hangar-cluster-ca")
b = docs[("Bundle", "hangar-cluster-ca")]
if b["apiVersion"] != "trust.cert-manager.io/v1alpha1":
    bad.append("Bundle apiVersion " + b["apiVersion"])
if b["spec"].get("sources") != [{"secret": {"name": "hangar-cluster-ca", "key": "ca.crt"}}]:
    bad.append(f"Bundle sources {b['spec'].get('sources')} (want only the CA Secret's ca.crt)")
if b["spec"].get("target") != {"configMap": {"key": "ca.crt"}}:
    bad.append(f"Bundle target {b['spec'].get('target')} (want a ConfigMap, key ca.crt, every namespace: no namespaceSelector)")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
  )"; then
    ok "cluster CA: self-signed bootstrap -> CA (P-256, 10y, key kept) -> CA ClusterIssuer; the Bundle publishes only ca.crt to every namespace"
  else
    bad "cluster CA: ${out}"
  fi
fi
for c in "components.clusterCA=true:components.clusterCA needs components.certManager" \
         "components.trustManager=true:components.trustManager needs components.certManager"; do
  new "${CAD}/bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
    --set components.certManager=false --set "${c%%:*}" --set components.trustManager=true
  out="$(python3 hack/render.py --cluster "${CAD}/bad/cluster.yaml" 2>&1)" && bad "${c%%:*} without cert-manager rendered" \
    || { grep -qF "${c#*:}" <<<"${out}" && ok "${c%%:*} without cert-manager is refused" || bad "${c%%:*} without cert-manager: ${out}"; }
done
new "${CAD}/notm" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.clusterCA=true
out="$(python3 hack/render.py --cluster "${CAD}/notm/cluster.yaml" 2>&1)" && bad "clusterCA without trustManager rendered" \
  || { grep -qF "components.clusterCA needs" <<<"${out}" && ok "clusterCA without trustManager is refused" || bad "clusterCA without trustManager: ${out}"; }
new "${CAD}/nodig" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set components.trustManager=true --set versions.trustManager.imageDigest=latest
out="$(python3 hack/render.py --cluster "${CAD}/nodig/cluster.yaml" 2>&1)" && bad "trustManager with no image digest rendered" \
  || { grep -qF "versions.trustManager.imageDigest" <<<"${out}" && ok "trustManager without an image digest is refused" || bad "trustManager without a digest: ${out}"; }
