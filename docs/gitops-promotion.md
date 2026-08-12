# GitOps Promotion

Argo CD reconciles three environment Applications from the protected `main`
branch. Promotion changes only the desired image identity in Git; the workflow
does not run `kubectl` or Helm against an environment cluster.

## Control Plane

- Argo CD `v3.4.6` is downloaded from the official repository and verified by
  SHA256 before installation.
- Argo CD, Dex, and Redis container references from that manifest are replaced
  with reviewed multi-platform registry digests before apply.
- The large CRD bundle uses server-side apply with a dedicated field manager,
  avoiding the client-side `last-applied-configuration` annotation size limit.
  Field ownership conflicts are not forced.
- The bootstrap script refuses every kubectl context except
  `kind-gitops-reliability` by default.
- The built-in Argo CD admin account is disabled after bootstrap.
- The AppProject accepts only this repository and the `dev`, `stage`, and
  `prod` namespaces.
- Argo may reconcile only `Deployment` and `Service` resources. Cluster-scoped
  resources are denied.
- Environment namespaces are bootstrap-owned, so Argo cannot prune them.
- ApplicationSet deletion preserves generated workloads.
- The imperative local demo uses `local-dev`; it never competes with Argo for
  `dev`, `stage`, or `prod` resources.

Argo uses automated prune and self-heal inside this boundary. A reviewed merge
is therefore an authorization to converge the selected environment to the new
Git state. Removing a workload from the chart can prune it; branch protection,
render tests, and `allowEmpty: false` are the safeguards against accidental
deletion.

## Bootstrap

Bootstrap only after the GitOps manifests and digest-pinned values are merged
into `main`:

```bash
make argocd-bootstrap
make argocd-status
```

The bootstrap is idempotent for the disposable local kind cluster. It does not
create cloud resources or expose the Argo CD API outside the cluster.

If the cluster predates this capability and contains the old Helm-managed
`dev/reliability-demo` release, recreate the disposable cluster before
bootstrap:

```bash
make cluster-delete
make argocd-bootstrap
```

## Promotion Sequence

Use the full commit SHA whose image was published by the Secure Image Pipeline:

```bash
make promote \
  TARGET_ENV=dev \
  IMAGE_COMMIT=<full-40-character-commit-sha>
```

Review the resulting environment values diff, commit it on a feature branch,
and merge it through a pull request. After Argo reports dev healthy, promote
the same commit to stage and then prod:

```bash
make promote TARGET_ENV=stage IMAGE_COMMIT=<same-full-commit-sha>
make promote TARGET_ENV=prod IMAGE_COMMIT=<same-full-commit-sha>
```

The promotion command resolves the digest from public GHCR instead of trusting
user-supplied digest text. Stage requires the exact tag and digest already in
dev; prod requires the exact identity already in stage. CI resolves every
configured tag again and rejects a tag/digest mismatch before merge.

Each environment is intentionally promoted in a separate PR. That makes the
Git history the promotion audit trail and allows health evidence to be checked
between environments.
