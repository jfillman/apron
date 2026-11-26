# tests/cases/46-go-gateway-lab.sh (see tests/run.sh)
# group: render
# secs: 10
# needs: lab eks go-gateway
# the production profile renders none of it (the lab-only Go files are named only by a cluster that sets the keys)
PX="${TMP}/prodx"; mkdir -p "${PX}"
cp "${LAB}/prod/cluster.yaml" "${PX}/cluster.yaml"
render_ok "${PX}" "prod profile, no gateway keys"
[ -n "$(find "${PX}/55-autopilot" -type f 2>/dev/null | head -1)" ] && ok "prod profile: the Autopilot files render (the check below is not vacuous)" || ok "prod profile: no Autopilot files (nothing to switch)"
if grep -rq 'autopilot-gateway-go\|gateway-go-v\|autopilot-gateway-migrate' "${PX}" --exclude=cluster.yaml; then bad "prod profile: renders something of the Go gateway or the migrate Job"; else ok "prod profile: nothing of the Go gateway or migrate Job renders"; fi

# A-9 S9 step 2 ("switch") on a lab: the Go gateway serves, the Python Deployments are gone, the lab alias is the one the Python gateway had,
# the migrate Job runs as the PreSync step before the switch, and no egress policy renders (egress.enabled: false, as the Python gateway has none)
LG="${TMP}/labgo"; mkdir -p "${LG}/py" "${LG}/go"
new "${LG}/py" dev lab-go kiac --repo-url https://github.com/acme/g --scm-owner acme --tower-cluster lab-prod \
  --set tower.hostAliasIP=192.0.2.5 --set components.autopilot=true --set components.serviceCatalog.enabled=true --set components.serviceCatalog.scope=full
printf '%s\n' 'autopilot:' '  people: [alice]' >>"${LG}/py/cluster.yaml"
cp "${LG}/py/cluster.yaml" "${LG}/go/cluster.yaml"
printf '%s\n' '  gateway:' '    implementation: go' '    go:' '      tag: gateway-go-v0.1.0' \
  '      digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' '      migrateJob: true' '      registeredVersion: held' \
  '      brokerUrl: http://broker.platform-system.svc:8080' '      githubOwners: [acme]' '      airframeUpperClusters: [lab-prod]' \
  '      agentXRs: {namespaces: [app-agents], names: {reader: app-agents}}' \
  '      plainHttp: {glidepath: true, broker: true, logs: true, catalog: true, jwks: true, clearanceApi: true}' '      egress: {enabled: false}' >>"${LG}/go/cluster.yaml"
python3 hack/check.py --cluster "${LG}/go/cluster.yaml" >/dev/null 2>"${TMP}/lg-check" && ok "lab go: passes check" || bad "lab go: check: $(cat "${TMP}/lg-check")"
render_ok "${LG}/py" "lab (Python gateway)"
render_ok "${LG}/go" "lab (Go gateway, step 2)"
expect "${LG}/go" "lab step 2" 55-autopilot/gateway/gateway-go.yaml 55-autopilot/gateway/autopilot-api-go.yaml 55-autopilot/gateway/gateway-go-extras.yaml \
  55-autopilot/gateway/gateway-go-migrate.yaml '!55-autopilot/gateway/gateway.yaml' '!55-autopilot/gateway/autopilot-api.yaml' '!55-autopilot/gateway/gateway-go-egress.yaml'
LGG="${LG}/go/55-autopilot/gateway"
has "${LGG}/gateway-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "lab step 2: the Go gateway is in wave 2, after the migrate Job (wave 1)"
has "${LGG}/autopilot-api-go.yaml" 'argocd\.argoproj\.io/sync-wave: "2"' "lab step 2: the Go read API is in wave 2, after the migrate Job (wave 1)"
has "${LGG}/gateway-go-migrate.yaml" 'name: autopilot-gateway-migrate-v0-1-0-dddddddd' "lab step 2: the migrate Job is named for the image and stays in the render (it ran in step 1; a new image would run it again)"
if grep -q 'argocd\.argoproj\.io/hook' "${LGG}/gateway-go-migrate.yaml" "${LGG}/gateway-go.yaml" "${LGG}/autopilot-api-go.yaml"; then bad "lab step 2: an Argo CD hook annotation rendered"; else ok "lab step 2: no hooks (nothing relies on a hook running)"; fi
has "${LGG}/gateway-go.yaml" 'strategy: \{type: Recreate\}' "lab step 2: the gateway Deployment is Recreate (the writer lock is released before the next pod starts)"
has "${LGG}/gateway-go.yaml" 'replicas: 1' "lab step 2: one gateway replica"
has "${LGG}/autopilot-api-go.yaml" 'replicas: 2' "lab step 2: two read API replicas"
has "${LGG}/gateway-go.yaml" 'ip: "192\.0\.2\.5"' "lab step 2: the Go gateway gets the lab alias the Python gateway had (tower.hostAliasIP)"
has "${LG}/py/55-autopilot/gateway/gateway.yaml" 'ip: "192\.0\.2\.5"' "lab: the Python gateway has the same alias"
has "${LGG}/gateway-go.yaml" 'image: [^ ]*/autopilot-gateway-go:gateway-go-v0\.1\.0@sha256:d{64}$' "lab step 2: the Go gateway pins tag and digest"
has "${LG}/go/55-clearance/clearance/application.yaml" '"version": "held"' "lab step 2: go.registeredVersion holds the registration (the core's CLEARANCE_PROVIDERS)"
if grep -q 'gateway-go-v0.1.0' "${LG}/go/55-clearance/clearance/application.yaml"; then bad "lab step 2: the Go tag reached the Clearance Application despite registeredVersion"; else ok "lab step 2: the Go tag is not in the Clearance Application"; fi
sed 's/"version": "held"/"version": "PY"/' "${LG}/go/55-clearance/clearance/application.yaml" >"${TMP}/lg-go-app"
V="$(grep -o '"name": "autopilot-gateway", "version": "[^"]*"' "${LG}/py/55-clearance/clearance/application.yaml" | sed 's/.*"version": "\([^"]*\)"/\1/')"
sed "s/\"version\": \"PY\"/\"version\": \"${V}\"/" "${TMP}/lg-go-app" | diff -q - "${LG}/py/55-clearance/clearance/application.yaml" >/dev/null \
  && ok "lab step 2: apart from that held value the Clearance Application is the Python render's (the switch does not touch the core)" || bad "lab step 2: the Clearance Application differs from the Python render"
refuse "an empty registeredVersion" "${K}/go" '      registeredVersion: ""'
for e in EVENTS_RABBITMQ_ENABLED AUTOPILOT_EPHEMERAL CLEARANCE_EPHEMERAL CLEARANCE_DSN CLEARANCE_VERIFIERS AGENT_LOGINS CLEARANCE_GITHUB GATEWAY_API_TABLES; do
  if grep -q "name: ${e}" "${LGG}/gateway-go.yaml" "${LGG}/autopilot-api-go.yaml"; then bad "lab step 2: ${e} is set, and the Go gateway refuses it"; else ok "lab step 2: ${e} (refused by the Go gateway) is not set"; fi
done
