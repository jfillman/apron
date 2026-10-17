After `apron up` applies the root app-of-apps, these steps stay with a person. `<name>` is this cluster's name.

1. Manual syncs, in this order (they have no automated sync policy on purpose):
   - the infrastructure Applications under `10-crds-operators/` whose `application.yaml` has no `automated:` block
     (Crossplane first, then external-secrets, then the rest), then `40-observability/`;
   - `00-bootstrap/cluster-registry` once the fleet's clusters.yaml carries this cluster (`apron fleet add`);
   - on a control-plane cluster, the Glidepath control-plane and catalog Applications (names in the rendered tree).
   `argocd app sync <app> --kube-context <name>`, or the Argo CD UI.
2. Cluster identity (kiac, kind): `apron identity --out DIR`, then publish the keys:
   `hack/cluster-identity.sh publish --context <name> --issuer <issuer> --out <site dir>` (docs/cluster-identity.md).
3. Readiness flags: after verifying the cluster live, set them to true in the fleet's clusters.yaml
   (`airframe: { cicdReady, crossplaneReady, ... }`, docs/clusters-file.md) and sync the registry.
4. Provider ServiceAccount hash re-pins: Crossplane provider ServiceAccounts carry a revision hash; after the
   providers go Healthy, re-pin any IAM trust or RBAC that names them (`kubectl --context <name> -n crossplane-system
   get sa`), e.g. the cloud roles in Airframe `docs/admin/cloud-credentials.md`.
5. `apron verify --out DIR` for a health summary.
