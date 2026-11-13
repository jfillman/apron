# Renaming the `autopilot-clearance` Argo CD Application to `autopilot-gateway` (R-10e)

The gateway's Application is `autopilot-gateway` in the templates. A cluster that rendered the old template still has
`autopilot-clearance` (project default, source `55-autopilot/gateway`, destination `autopilot-system`). Argo CD cannot
rename an Application, so the old one is removed and the new one adopts its objects. Nothing here may delete live
objects: the gateway's database (`Cluster/autopilot-pg`, annotated `Prune=false,Delete=false`), its Secrets and its
Deployments must survive.

Why this is safe on the clusters this repo renders: the old Application has no `resources-finalizer.argocd.argoproj.io`
and no `prune` in its syncPolicy, and the root Application has no prune either. Deleting an Application without that
finalizer does not touch the objects it managed (the same as `kubectl delete app --cascade=orphan`). Check both first.

1. Read-only checks (stop if any answer differs):
   - `kubectl -n argocd get app autopilot-clearance -o jsonpath='{.metadata.finalizers}'` prints nothing.
   - `kubectl -n argocd get app autopilot-clearance -o jsonpath='{.spec.syncPolicy}'` has no `prune`.
   - `kubectl -n argocd get app autopilot-clearance -o jsonpath='{.status.resources[*].name}'` lists the objects; keep
     the list (31 on hangar-dev at R-10e) to compare in step 5.
2. Merge the gitops change. The root Application creates `autopilot-gateway`, which syncs the same folder and
   re-stamps the objects' tracking annotation with its own name. The old Application stays (the root does not prune).
3. Wait for `autopilot-gateway` to be Synced and Healthy.
4. Remove the old Application: `kubectl -n argocd delete app autopilot-clearance`. Confirm first that the finalizers
   in step 1 are still empty; if a finalizer was added, remove it (`kubectl -n argocd patch app autopilot-clearance
   --type=merge -p '{"metadata":{"finalizers":null}}'`) before deleting, or the delete would cascade.
5. Verify: `kubectl -n argocd get app autopilot-gateway -o jsonpath='{.status.resources[*].name}'` lists the same
   objects as step 1 (minus the retired ones below), `kubectl -n autopilot-system get cluster.postgresql.cnpg.io
   autopilot-pg` is unchanged (same age), the gateway and autopilot-api Deployments did not restart.
6. Objects the templates no longer render are not pruned. Delete them by hand once the run pods and clients have moved
   (R-10e): `kubectl -n autopilot-system delete service clearance`.

A cluster rendered for the first time from these templates has no old Application: steps 1, 4 and 6 do not apply.
