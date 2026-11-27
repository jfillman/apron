# tests/cases/44-lab-networking.sh (see tests/run.sh)
# group: render
# secs: 32
# needs: eks ledger
echo "== 3a. lab-only networking (runtime.labNetworking: kiac and kind only; docs/lab-networking.md)"
# EKS: no hostAlias entry, no *.local host, no RFC1918 literal from a lab knob, in any rendered file.
labscan() { # labscan DIR: prints one line per violation
  python3 - "$1" <<'PY'
import os, re, sys
try:
    import yaml
except ImportError:
    yaml = None
rfc = re.compile(r"(?<![0-9.])(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)(?![0-9.])")
def walk(o, p, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "hostAliases" and isinstance(v, list) and any(isinstance(e, dict) and "ip" in e for e in v):
                out.append(f"{p}: hostAliases entry")
            walk(v, p, out)
    elif isinstance(o, list):
        for e in o:
            walk(e, p, out)
out = []
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        p = os.path.join(d, f)
        if f == "cluster.yaml" or not f.endswith((".yaml", ".yml", ".sh", ".md")):
            continue
        text = open(p).read()
        code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
        if re.search(r"(?<!cluster)(?<!svc)\.local\b", code):
            out.append(f"{p}: .local host")
        if rfc.search(code) and "networkpolicy" not in p.lower() and "install.yaml" not in p and "kubeadm" not in p:
            out.append(f"{p}: RFC1918 literal {rfc.search(code).group(1)}")
        if yaml and f.endswith((".yaml", ".yml")) and "/chart/templates/" not in p and not f.endswith(".tmpl.yaml"):
            try:
                for doc in yaml.safe_load_all(text):
                    walk(doc, p, out)
            except Exception:
                pass
        if re.search(r'^\s*(- )?ip: "?\d', text, re.M) and "install.yaml" not in p:
            out.append(f"{p}: ip: literal")
print("\n".join(out))
PY
}
for c in dev prod man; do
  [ -d "${K}/${c}" ] || continue
  r="$(labscan "${K}/${c}")"
  [ -z "${r}" ] && ok "eks-${c}: no hostAliases, .local host or lab address rendered" || bad "eks-${c}: lab plumbing rendered: $(head -3 <<<"${r}")"
done
# the lab renders keep them (the knobs are set in the ledger fixtures above)
grep -rqE 'hostAliases: \[\{' "${TMP}/led-dev" && ok "lab (kiac): the host alias knobs still render" || bad "lab: host alias knobs no longer render"
# a non-lab runtime refuses every lab-only knob by name, and (--no-check) still renders none of them
for knob in tower.hostAliasIP=192.0.2.5 fleet.hubAddress=192.0.2.6 clearance.gate.hostAlias=192.0.2.1=clearance.example.dev \
            clearance.ledger.hostAlias=192.0.2.9=witness.example.dev clearance.slack.idp.hostAlias=192.0.2.10; do
  key="${knob%%=*}"
  rm -rf "${TMP}/eks-knob"
  new "${TMP}/eks-knob" dev eks-knob eks --repo-url https://github.com/acme/gitops-eks-knob --scm-owner acme \
    --domain eks-knob.aws.example.dev --set infisical.host=false --set infisical.url="${INF}" --set "issuer=${ISS}/DDD4" \
    --tower-cluster eks-man --set tower.domain=eks-man.aws.example.dev --set "${knob}"
  cp "${TMP}/eks-knob/cluster.yaml" "${TMP}/eks-knob.yaml"
  err="$(python3 hack/check.py --cluster "${TMP}/eks-knob.yaml" 2>&1 >/dev/null)"
  grep -q "${key} is lab-only networking" <<<"${err}" && ok "eks: ${key} refused by name" || bad "eks: ${key} not refused (${err})"
  python3 hack/render.py --cluster "${TMP}/eks-knob/cluster.yaml" --no-check >/dev/null 2>&1
  r="$(labscan "${TMP}/eks-knob")"
  [ -f "${TMP}/eks-knob/root-app-of-apps.yaml" ] && [ -z "${r}" ] && ok "eks: ${key} set, check bypassed: still no lab plumbing rendered" || bad "eks: ${key} rendered anyway: $(head -2 <<<"${r}")"
done
# Clearance Slack off a lab: gateway-existing only; dns01-route53 and idp.hostAlias are the lab path
EKS_SLACK=(--repo-url https://github.com/acme/gitops-eks-knob --scm-owner acme
  --domain eks-knob.aws.example.dev --set infisical.host=false --set infisical.url="${INF}" --set "issuer=${ISS}/DDD4"
  --tower-cluster eks-man --set tower.domain=eks-man.aws.example.dev --set "tower.issuer=${ISS}/DDD5" "${SLACK_COMMON[@]}")
rm -rf "${TMP}/eks-slack"
new "${TMP}/eks-slack" dev eks-knob eks "${EKS_SLACK[@]}"
python3 hack/check.py --cluster "${TMP}/eks-slack/cluster.yaml" >/dev/null 2>"${TMP}/eks-slack.err" && ok "eks: slack on with gateway-existing passes check" || bad "eks: slack gateway-existing refused: $(head -1 "${TMP}/eks-slack.err")"
render_ok "${TMP}/eks-slack" "eks slack (gateway-existing)"
r="$(labscan "${TMP}/eks-slack")"
[ -z "${r}" ] && ok "eks slack: no lab plumbing rendered" || bad "eks slack: lab plumbing rendered: $(head -2 <<<"${r}")"
for extra in "clearance.slack.tls.mode=dns01-route53 clearance.slack.tls.dns01.hostedZoneID=Z0123456789ABC clearance.slack.tls.dns01.email=ops@example.com clearance.slack.tls.dns01.roleARN=arn:aws:iam::111122223333:role/x"; do
  rm -rf "${TMP}/eks-slack-dns"
  new "${TMP}/eks-slack-dns" dev eks-knob eks "${EKS_SLACK[@]}" $(printf -- '--set %s ' ${extra})
  err="$(python3 hack/check.py --cluster "${TMP}/eks-slack-dns/cluster.yaml" 2>&1 >/dev/null)"
  grep -q "is the lab path" <<<"${err}" && ok "eks: slack dns01-route53 refused as the lab path" || bad "eks: slack dns01 not refused (${err})"
done
rm -rf "${TMP}/eks-slack-alias"
new "${TMP}/eks-slack-alias" dev eks-knob eks "${EKS_SLACK[@]}" --set clearance.slack.idp.hostAlias=192.0.2.10
python3 hack/render.py --cluster "${TMP}/eks-slack-alias/cluster.yaml" --no-check >/dev/null 2>&1
r="$(labscan "${TMP}/eks-slack-alias")"
[ -f "${TMP}/eks-slack-alias/root-app-of-apps.yaml" ] && [ -z "${r}" ] && ok "eks slack: idp.hostAlias set, check bypassed: not rendered" || bad "eks slack: idp.hostAlias rendered: $(head -2 <<<"${r}")"
# real DNS is required where there is no lab: no <name>.local defaults
python3 hack/new_cluster.py --profile dev --name eks-nodns --runtime eks --repo-url https://github.com/acme/g --scm-owner acme >"${TMP}/nodns.yaml"
err="$(python3 hack/check.py --cluster "${TMP}/nodns.yaml" 2>&1 >/dev/null)"
grep -q "domain is required on runtime eks" <<<"${err}" && ok "eks: no domain is refused (no <name>.local default)" || bad "eks: no domain accepted (${err})"
python3 hack/new_cluster.py --profile dev --name eks-local --runtime eks --repo-url https://github.com/acme/g --scm-owner acme --domain eks-local.local >"${TMP}/localdns.yaml"
err="$(python3 hack/check.py --cluster "${TMP}/localdns.yaml" 2>&1 >/dev/null)"
grep -q "domain 'eks-local.local' is a .local name" <<<"${err}" && ok "eks: a .local domain is refused" || bad "eks: .local domain accepted (${err})"
# an existing cluster that IS a lab opts in explicitly, and then gets the lab defaults
python3 hack/new_cluster.py --profile dev --name lab-existing --runtime existing --repo-url https://github.com/acme/g --scm-owner acme \
  --tower-cluster hangar-prod --set runtime.labNetworking=true --set tower.hostAliasIP=192.0.2.5 >"${TMP}/existing-lab.yaml"
python3 hack/check.py --cluster "${TMP}/existing-lab.yaml" >/dev/null 2>&1 && ok "existing + runtime.labNetworking: true: lab knobs accepted" || bad "existing lab opt-in refused"
for rt in kiac kind; do
  has "runtimes/${rt}.yaml" '^  labNetworking: true' "runtime ${rt}: labNetworking is true"
done
for rt in eks existing; do
  has "runtimes/${rt}.yaml" '^  labNetworking: false' "runtime ${rt}: labNetworking is false"
done
