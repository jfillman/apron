# API server audit webhook

`hack/observe-audit.sh` turns on the kube-apiserver audit webhook that feeds Clearance's Kubernetes audit collector. The
flags and files live on the control-plane node, so an Argo CD Application can't set them. Clearance's
`docs/observe-k8s-runbook.md` explains what each piece is for.

## Order

1. `prepare` makes the keys and certificates on your machine and renders the audit policy from the Clearance release tag.
2. `secret` creates the collector's TLS Secret.
3. Deploy the collector with `webhook.service.clusterIP` set to the same IP `prepare` was given.
4. `install --dry-run` shows the manifest change. `install` makes it.
5. `verify`, then check `GET /v1/coverage?scope=<cluster>` on the Clearance core.

## Guardrails

- `install` stops unless the node reached by `--node-exec` is the control plane of `--context`.
- It stops if the node's load is over `--max-load`, or the collector is not ready at the IP in its certificate.
- It proves mutual TLS from the node with the real client certificate before it changes the manifest.
- It backs up the manifest, swaps it in one rename, and restores it if the API server doesn't return with the flags.
- `prepare` refuses a directory that already holds keys, so a rotation is always a new directory.

## After a cluster is recreated

The node files and flags are gone. Run `install` again with the same directory.
