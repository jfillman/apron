# tests/cases/33-ledger.sh (see tests/run.sh)
# group: render
# secs: 14
# needs: lab
echo "== 1c. the evidence ledger (clearance C-3): the log on the core's cluster, a witness on the protected one"
new "${TMP}/led-dev" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tower.hostAliasIP=192.0.2.5 "${LEDGER_SET[@]}"
new "${TMP}/led-dev-notower" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod "${LEDGER_SET[@]}" \
  --set clearance.ledger.quorum=all
new "${TMP}/led-prod" prod hangar-prod kind --repo-url https://github.com/acme/gitops-cluster-hangar-prod --scm-owner acme \
  --fleet-hub hangar-dev --fleet-repo-url https://github.com/acme/gitops-cluster-hangar-dev "${WIT_SET[@]}"
render_ok "${TMP}/led-dev" "ledger on (dev, with Tower's host alias)"
render_ok "${TMP}/led-dev-notower" "ledger on (dev, no Tower host alias)"
render_ok "${TMP}/led-prod" "witness on (prod)"
has "${TMP}/led-dev/${CA}" '^        ledger:$' "ledger on: the chart's ledger values"
has "${TMP}/led-dev/${CA}" 'existingSecret: clearance-ledger-key' "ledger on: the log key is the Secret ledger-key.yaml makes"
has "${TMP}/led-dev/${CA}" 'witnessPolicy: "witness hangar-prod hangarplatform.dev/witness/hangar-prod\+df3c5653\+[A-Za-z0-9+/]+ http://witness.hangar-prod.local\\nquorum hangar-prod\\n"' \
  "ledger on: the policy is witness <name> <cosignature vkey> <url>, then quorum"
has "${TMP}/led-dev/${CA}" 'egress: \[\{"to": \[\{"ipBlock": \{"cidr": "192.0.2.9/32"\}\}\], "ports": \[\{"protocol": "TCP", "port": 80\}\]\}\]' \
  "ledger on: the core's egress reaches the witness's address and port only"
has "${TMP}/led-dev/${CA}" 'hostAliases: \[\{ip: "192.0.2.5", hostnames: \["backstage.hangar-prod.local"\]\}, \{"ip": "192.0.2.9", "hostnames": \["witness.hangar-prod.local"\]\}\]' \
  "ledger on: the core keeps Tower's host alias and gains the witness's"
# Tower and the witness on one address: one hostAliases entry, because Kubernetes merges them by ip.
LEDGER_SAME_IP=("${LEDGER_SET[@]/192.0.2.9/192.0.2.5}")
new "${TMP}/led-dev-sameip" dev hangar-dev kiac --repo-url https://github.com/acme/gitops-cluster-hangar-dev --scm-owner acme --tower-cluster hangar-prod \
  --set tower.hostAliasIP=192.0.2.5 "${LEDGER_SAME_IP[@]}"
render_ok "${TMP}/led-dev-sameip" "ledger on (dev, the witness on Tower's address)"
has "${TMP}/led-dev-sameip/${CA}" 'hostAliases: \[\{ip: "192.0.2.5", hostnames: \["backstage.hangar-prod.local", "witness.hangar-prod.local"\]\}\]' "same address as Tower: one entry with both hostnames"
has "${TMP}/led-dev-notower/${CA}" 'hostAliases: \[\{"ip": "192.0.2.9", "hostnames": \["witness.hangar-prod.local"\]\}\]' "ledger on without Tower's alias: the core gets the witness's"
has "${TMP}/led-dev/55-clearance/clearance-config/ledger-key.yaml" 'key: hangar-ledger-hangar-dev-key' "ledger on: the key is Infisical's hangar-ledger-<cluster>-key by default"
has "${TMP}/led-dev/55-clearance/clearance-config/ledger-key.yaml" 'secretKey: ledger-key' "ledger on: the Secret has the key the chart mounts"
expect "${TMP}/led-dev" "ledger on" 55-clearance/clearance-config/ledger-key.yaml '!56-clearance-witness'
WD=56-clearance-witness
expect "${TMP}/led-prod" "witness on" ${WD}/application.yaml ${WD}/witness.yaml ${WD}/routes.yaml '!55-clearance/clearance-config/ledger-key.yaml'
has "${TMP}/led-prod/${WD}/witness.yaml" "image: ${WITNESS_IMG}" "witness on: the pinned image"
has "${TMP}/led-prod/${WD}/witness.yaml" '^    type: Recreate$' "witness on: Recreate (one replica, one claim)"
has "${TMP}/led-prod/${WD}/witness.yaml" 'key: hangar-witness-hangar-prod-key' "witness on: the key is Infisical's hangar-witness-<cluster>-key by default"
has "${TMP}/led-prod/${WD}/witness.yaml" 'secretKey: witness-key' "witness on: the Secret has the key the witness reads"
has "${TMP}/led-prod/${WD}/witness.yaml" '[-][-]logs-file=/etc/clearance-witness/config/logs' "witness on: the flags the chart passes"
has "${TMP}/led-prod/${WD}/witness.yaml" '^  logs: "hangarplatform.dev/clearance/hangar-dev\+108edc37\+' "witness on: the log's public key in the ConfigMap"
has "${TMP}/led-prod/${WD}/witness.yaml" '^  egress: \[\]$' "witness on: no egress at all"
has "${TMP}/led-prod/${WD}/witness.yaml" 'pod-security.kubernetes.io/enforce: restricted' "witness on: restricted namespace"
has "${TMP}/led-prod/${WD}/routes.yaml" '^    - witness.hangar-prod.local$' "witness on: the route's host is witness.<domain>"
has "${TMP}/led-prod/${WD}/routes.yaml" 'value: /add-checkpoint' "witness on: the route carries add-checkpoint"
has "${TMP}/led-prod/30-policy/kyverno-policies/flight-images.yaml" "\"${WITNESS_IMG}\"\]'" "witness on: Flight admission allows exactly the witness image"
if grep -rnE 'PRIVATE KEY|AGE-SECRET-KEY|PRIVATE\+KEY\+' "${TMP}/led-dev" "${TMP}/led-prod" >/dev/null; then bad "ledger/witness: key material in a render"; else ok "ledger/witness: no private key material in a render"; fi
