# tests/cases/12-cert-manager.sh (see tests/run.sh)
# group: render
# secs: 10
# needs: lab
echo "== 1-cm. cert-manager's DNS-01 self-check resolvers (certManager.dns01RecursiveNameservers, off by default)"
# Unset: the cert-manager Application carries neither chart value (the pod's resolv.conf, as before). Set: the chart's
# dns01RecursiveNameservers (the list, comma-joined) and dns01RecursiveNameserversOnly, which render the controller's
# --dns01-recursive-nameservers and --dns01-recursive-nameservers-only. apron check refuses anything but a list of host:port.
CMA="10-crds-operators/cert-manager/application.yaml"
for d in "${LAB}/dev" "${LAB}/prod"; do
  if grep -q 'dns01Recursive' "${d}/${CMA}"; then bad "cert-manager default (${d##*/}): resolver values rendered"
  else ok "cert-manager default (${d##*/}): no resolver values (resolv.conf)"; fi
done
CMD="${TMP}/certmanager-dns01"
new "${CMD}/on" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set 'certManager.dns01RecursiveNameservers=["192.0.2.53:53", "[2001:db8::53]:53", "resolver.example.net:5353"]'
render_ok "${CMD}/on" "dev certManager.dns01RecursiveNameservers"
has "${CMD}/on/${CMA}" '^        dns01RecursiveNameservers: "192\.0\.2\.53:53,\[2001:db8::53\]:53,resolver\.example\.net:5353"$' \
  "cert-manager: the resolvers render comma-joined in list order"
has "${CMD}/on/${CMA}" '^        dns01RecursiveNameserversOnly: true$' "cert-manager: the self-check uses only those resolvers"
if [ "${HAVE_YAML}" = true ]; then
  out="$(python3 - "${CMD}/on/${CMA}" "${LAB}/dev/${CMA}" <<'PY' 2>&1
import sys, yaml
on, off = (yaml.safe_load(open(p))["spec"]["source"]["helm"]["valuesObject"] for p in sys.argv[1:])
want = dict(off, dns01RecursiveNameservers="192.0.2.53:53,[2001:db8::53]:53,resolver.example.net:5353", dns01RecursiveNameserversOnly=True)
if on != want:
    print(f"valuesObject {on} (want {want})")
    sys.exit(1)
PY
  )" && ok "cert-manager: the knob adds exactly the two chart values" || bad "cert-manager: ${out}"
fi
new "${CMD}/empty" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set 'certManager.dns01RecursiveNameservers=[]'
render_ok "${CMD}/empty" "dev certManager.dns01RecursiveNameservers: []"
grep -q 'dns01Recursive' "${CMD}/empty/${CMA}" && bad "cert-manager: an empty list rendered resolver values" \
  || ok "cert-manager: an empty list renders nothing"
cm_refused() { # cm_refused LABEL WANT --set ...
  local label="$1" want="$2"; shift 2
  new "${CMD}/bad" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "$@"
  out="$(python3 hack/render.py --cluster "${CMD}/bad/cluster.yaml" 2>&1)" && bad "${label} rendered" \
    || { grep -qF -- "${want}" <<<"${out}" && ok "${label} is refused" || bad "${label}: ${out}"; }
}
cm_refused "a resolver without a port" "entry '192.0.2.53': not host:port" --set 'certManager.dns01RecursiveNameservers=["192.0.2.53"]'
cm_refused "a port out of range" "port 65536 is not 1-65535" --set 'certManager.dns01RecursiveNameservers=["192.0.2.53:65536"]'
cm_refused "a bad IPv4 address" "192.0.2.300 is not an IPv4 address" --set 'certManager.dns01RecursiveNameservers=["192.0.2.300:53"]'
cm_refused "an unbracketed IPv6 address" "not host:port" --set 'certManager.dns01RecursiveNameservers=["2001:db8::53:53"]'
cm_refused "a DoH URL" "not host:port" --set 'certManager.dns01RecursiveNameservers=["https://resolver.example.net/dns-query"]'
cm_refused "a resolver listed twice" "lists a resolver twice" --set 'certManager.dns01RecursiveNameservers=["192.0.2.53:53", "192.0.2.53:53"]'
cm_refused "a string, not a list" "is a list of host:port resolvers" --set 'certManager.dns01RecursiveNameservers=192.0.2.53:53'
cm_refused "resolvers without cert-manager" "needs components.certManager" --set components.certManager=false \
  --set 'certManager.dns01RecursiveNameservers=["192.0.2.53:53"]'
