# tests/cases/05-lab-gateway.sh (see tests/run.sh)
# group: render
# secs: 1
# needs: lab
has "${LAB}/dev/55-autopilot/gateway/autopilot-api.yaml" 'value: "http://autopilot\.hangar-dev\.local"' "lab: Clearance's URL stays http"
# R-10c/e: the gateway is autopilot-gateway (label, Deployment, SA, Service); the old `clearance` aliases (Service, host,
# principal, Application name) are gone since R-10e.
G="${LAB}/dev/55-autopilot/gateway"
has "${G}/gateway.yaml" '^  name: autopilot-gateway$' "lab: gateway Deployment is autopilot-gateway"
has "${G}/gateway.yaml" 'serviceAccountName: autopilot-gateway' "lab: gateway runs as SA autopilot-gateway"
has "${G}/gateway.yaml" 'selector: \{app.kubernetes.io/name: autopilot-gateway\}' "lab: Services select the new label"
has "${G}/gateway.yaml" 'gateway-v0.9.1@sha256:a0797bd4d75902d3cce91f11e8ac669c550121a6b3ca4f9aedd327b596afd5cc' "lab: gateway image pinned"
has "${G}/autopilot-api.yaml" 'gateway-v0.9.1@sha256:a0797bd4d75902d3cce91f11e8ac669c550121a6b3ca4f9aedd327b596afd5cc' "lab: read API on the same image"
has "${G}/autopilot-api.yaml" 'AUTOPILOT_GATEWAY_URL' "lab: read API uses AUTOPILOT_GATEWAY_URL"
if grep -rn 'app.kubernetes.io/name: clearance[},]' "${G}" >/dev/null; then bad "lab: a gateway object still carries the label clearance"; else ok "lab: no gateway object carries the label clearance"; fi
if grep -q '^  name: clearance$' "${G}/gateway.yaml"; then bad "lab: the clearance Service alias is still rendered"; else ok "lab: no clearance Service alias (R-10e)"; fi
if grep -q 'clearance\.hangar-dev\.local' "${G}/routes.yaml" "${G}/gateway.yaml"; then bad "lab: the gateway still answers on clearance.<domain>"; else ok "lab: the gateway's route and resource URL are autopilot.<domain> only"; fi
has "${G}/routes.yaml" '    - autopilot\.hangar-dev\.local' "lab: the gateway route's host is autopilot.<domain>"
has "${G}/application.yaml" '^  name: autopilot-gateway$' "lab: the Argo Application is autopilot-gateway"
if grep -rq 'autopilot-system:clearance\|autopilot-system/clearance\|name: clearance, namespace: autopilot-system' "${LAB}/dev/50-glidepath" "${LAB}/dev/55-autopilot" "${LAB}/dev/55-clearance"; then bad "lab: the old principal is still named"; else ok "lab: no list names the old principal"; fi
has "${G}/argo-sync.yaml" "autopilot-system:autopilot-gateway'" "lab: argo-sync admits the new principal"
has "${LAB}/dev/50-glidepath/glidepath-control-plane/values.yaml" 'system:serviceaccount:autopilot-system:autopilot-gateway' "lab: glidepath-api delegates the new principal"
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'principals": \["autopilot-system/autopilot-gateway"\]' "lab: the provider registers the gateway's principal only"
# clearance-api headroom: 512Mi limit, 128Mi request, GOMEMLIMIT below the limit (the chart default OOMKilled in a loop)
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'limits: \{memory: 512Mi\}' "lab: clearance-api memory limit is 512Mi"
has "${LAB}/dev/55-clearance/clearance/application.yaml" 'requests: \{cpu: 25m, memory: 128Mi\}' "lab: clearance-api memory request is 128Mi"
has "${LAB}/dev/55-clearance/clearance/application.yaml" '^          goMemLimit: 400MiB$' "lab: clearance-api sets GOMEMLIMIT with the chart's goMemLimit"
# Chart 0.54.0 adds its own GOMEMLIMIT: one from extraEnv too makes the env name repeat, and Argo CD's dry run refuses the patch.
if grep -rqE 'name: GOMEMLIMIT' "${LAB}/dev/55-clearance/clearance/application.yaml"; then bad "lab: clearance sets GOMEMLIMIT in extraEnv (duplicate env name with the chart's)"; else ok "lab: clearance has no extraEnv GOMEMLIMIT"; fi
has "${LAB}/dev/10-crds-operators/crossplane/functions.yaml" 'function-agentrun@sha256:30324c992ab970427abe6a9f959c5d6199ab39bece35393593e9037932b065e9' "lab: function-agentrun v0.4.0"
