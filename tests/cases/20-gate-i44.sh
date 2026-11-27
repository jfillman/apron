# tests/cases/20-gate-i44.sh (see tests/run.sh)
# group: render
# secs: 14
i44 gate-i44 --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.ha.enabled=true \
  --set clearance.gate.agent.statusHeartbeat=5m --set clearance.gate.agent.alerts.enabled=true --set clearance.gate.previousURL=http://clearance-old.hangar-dev.local
render_ok "${TMP}/gate-i44" "gate agent with grantExpiry (audit), ha, statusHeartbeat and alerts"
AGI="${TMP}/gate-i44/56-clearance-gate/agent/application.yaml"
has "${AGI}" '^        grantExpiry: \{"enabled": true, "argocdUser": "system:serviceaccount:argocd-apps:argocd-application-controller"\}$' "grantExpiry: enabled, audit by the chart's default, the policy's controller"
has "${AGI}" '^          previousURL: "http://clearance-old.hangar-dev.local"$' "grantExpiry with previousURL: the webhook exempts the previous URL's wait Job too"
if grep -q '^ *gate:' "${AGI}"; then bad "gate.enforce off: the agent was told the policy enforces"; else ok "gate.enforce off: no gate values in the agent"; fi
if [ "${HAVE_YAML}" = true ]; then
  python3 - "${AGI}" <<'PY' && ok "I-44: the agent's values are the chart's keys" || bad "I-44: the agent's rendered values are wrong"
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))["spec"]["source"]["helm"]["valuesObject"]
assert v["ha"] == {"enabled": True}, v.get("ha")
assert v["statusHeartbeat"] == "5m", v.get("statusHeartbeat")
assert v["alerts"] == {"enabled": True, "labels": {"release": "kube-prometheus-stack"}}, v.get("alerts")
assert v["waitJob"]["previousURL"] == "http://clearance-old.hangar-dev.local", v["waitJob"]
PY
fi
i44 gate-i44-enf --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.grantExpiry.mode=enforce \
  --set clearance.gate.enforce=true --set clearance.gate.argocdServiceAccount=argocd-apps:my-controller
render_ok "${TMP}/gate-i44-enf" "gate.enforce with an enforcing grant-expiry webhook"
AGE="${TMP}/gate-i44-enf/56-clearance-gate/agent/application.yaml"
has "${AGE}" '^        grantExpiry: \{"enabled": true, "enforce": true, "argocdUser": "system:serviceaccount:argocd-apps:my-controller"\}$' "grantExpiry mode enforce: the chart's enforce, the named controller"
has "${AGE}" '^          enforce: true$' "gate.enforce: the agent chart is told the policy denies"
if grep -q 'previousURL' "${AGE}"; then bad "no previousURL: one rendered"; else ok "no previousURL: none in the agent"; fi
i44 gate-i44-enf-audit --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.enforce=true
i44_refused gate-i44-enf-audit "clearance.gate.enforce needs clearance.gate.agent.grantExpiry {enabled: true, mode: enforce}" "gate.enforce with the webhook in audit"
i44 gate-i44-enf-none --set clearance.gate.enforce=true
i44_refused gate-i44-enf-none "clearance.gate.enforce needs clearance.gate.agent.grantExpiry" "gate.enforce without the webhook"
i44 gate-i44-risk --set clearance.gate.enforce=true --set clearance.gate.agent.grantExpiry.acceptResidualRisk=true
render_ok "${TMP}/gate-i44-risk" "gate.enforce without the webhook, acceptResidualRisk"
has "${TMP}/gate-i44-risk/56-clearance-gate/agent/application.yaml" '^        grantExpiry: \{"acceptResidualRisk": true\}$' "acceptResidualRisk alone: only the override renders"
i44 gate-i44-enf-old --set clearance.gate.enforce=true --set versions.clearance.argocdAgentChart=0.54.0
render_ok "${TMP}/gate-i44-enf-old" "gate.enforce on an agent chart before 0.55.0 (no webhook to require)"
i44 gate-i44-mode --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.grantExpiry.mode=strict
i44_refused gate-i44-mode "clearance.gate.agent.grantExpiry.mode is 'strict'" "a grantExpiry mode other than audit or enforce"
i44 gate-i44-enf-off --set clearance.gate.agent.grantExpiry.mode=enforce
i44_refused gate-i44-enf-off "mode: enforce needs grantExpiry.enabled: true" "grantExpiry mode enforce without enabled"
i44 gate-i44-typo --set clearance.gate.agent.grantExpiry.enable=true
i44_refused gate-i44-typo "clearance.gate.agent.grantExpiry.enable is not a setting" "an unknown grantExpiry key"
i44 gate-i44-old --set clearance.gate.agent.grantExpiry.enabled=true --set versions.clearance.argocdAgentChart=0.54.0
i44_refused gate-i44-old "need versions.clearance.argocdAgentChart 0.55.0 or later" "grantExpiry on an agent chart before 0.55.0"
i44 gate-i44-nocm --set clearance.gate.agent.grantExpiry.enabled=true --set components.certManager=false
i44_refused gate-i44-nocm "clearance.gate.agent.grantExpiry needs components.certManager" "grantExpiry without cert-manager"
i44 gate-i44-hb --set clearance.gate.agent.statusHeartbeat=5m30s
i44_refused gate-i44-hb "clearance.gate.agent.statusHeartbeat is '5m30s'" "a statusHeartbeat of two units"
i44 gate-i44-al-hb --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-hb "clearance.gate.agent.alerts needs statusHeartbeat" "alerts without statusHeartbeat"
i44 gate-i44-al-ge --set clearance.gate.agent.statusHeartbeat=5m --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-ge "clearance.gate.agent.alerts needs grantExpiry.enabled" "alerts without the webhook"
i44 gate-i44-al-slow --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.statusHeartbeat=15m --set clearance.gate.agent.alerts.enabled=true
i44_refused gate-i44-al-slow "must be below 15m with alerts" "a statusHeartbeat not below the alert's staleness"
i44 gate-i44-al-obs --set clearance.gate.agent.grantExpiry.enabled=true --set clearance.gate.agent.statusHeartbeat=5m \
  --set clearance.gate.agent.alerts.enabled=true --set components.observability=false
i44_refused gate-i44-al-obs "clearance.gate.agent.alerts needs components.observability" "alerts without kube-prometheus-stack"
