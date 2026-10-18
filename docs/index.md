# Apron

Apron deploys Hangar onto a Kubernetes cluster. It renders the cluster's own GitOps repo from a small `cluster.yaml`,
then onboards the cluster: two Argo CD instances (`argocd` for the platform, `argocd-apps` for apps), the root
app-of-apps, and a stop for the few secrets a person must plant. Onboarding an existing cluster is the primary path;
`kiac` and `kind` create a local cluster first and then run the same onboarding.

A cluster has one name, chosen by you, and everything else derives from it: its kubectl context, fleet record,
Infisical projects, ServiceAccount issuer and hostnames. Apron's code, templates and docs contain no cluster names.

- [The `apron` CLI](cli.md): `init`, `up`, `render`, `fleet`, `identity`, `verify`, `resume`, `down`.
- [After `apron up`](after-up.md): the steps that stay with a person.
- [The fleet file](clusters-file.md): the hub's `clusters.yaml`, one record per cluster.
- [Cluster identity](cluster-identity.md): each cluster's issuer, and how the hub trusts Tower's cluster.

The repository README has the install walkthrough, profiles and runtimes, and the repo layout.
