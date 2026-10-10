# 55-autopilot

Autopilot runs AI agent workloads on Hangar, bounded and audited (hangar `docs/autopilot/design.md`). This directory
exists only on a cluster that sets `components.autopilot: true` in `cluster.yaml`, and `hack/customize-cluster.sh`
refuses that on any cluster without the control-plane role: runs are dev-only.

What lands here, by roadmap task:

| Task | What | Where |
|---|---|---|
| AP-A1 | `autopilot-system` (Clearance and the model proxy) and `autopilot-runs` (AgentRun XRs), both pod-security `restricted` | `namespaces/` |
| AP-A2 | Clearance, as an InfraService | not yet |
| AP-A3 | the AgentRun XRD and Composition (through `20-service-catalog/`), function-agentrun, the provider-kubernetes ClusterRole with its admission policy | not yet |

## Letting runs onto this cluster

Runs are isolated by NetworkPolicy, so a cluster that does not enforce it must never take one. Before any run:

1. Run the canary with your own kubeconfig: `autopilot/tools/netpol_canary.py --context <this cluster>`. It renders a
   run's real policies, probes from inside them, and pairs every denial with a no-policy control.
2. On a pass, set `airframe.autopilotReady: true` on this cluster's record in the hub's `clusters.yaml`, citing the
   result, and sync `cluster-registry` (manual on purpose: the sync is the attestation). The registry chart refuses the
   flag on a cluster without the control-plane role, and the AgentRun composition (AP-A3) refuses a run without it.
