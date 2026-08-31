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
make monitoring-bootstrap
make argocd-bootstrap
make argocd-status
```

Monitoring is installed first because the application chart renders a
`ServiceMonitor` in every environment. Argo bootstrap fails before installing
the control plane when that CRD is missing; this prevents a clean cluster from
creating three permanently failed sync operations.

The bootstrap is idempotent for the disposable local kind cluster. It does not
create cloud resources or expose the Argo CD API outside the cluster.

If the cluster predates this capability and contains the old Helm-managed
`dev/reliability-demo` release, recreate the disposable cluster before
bootstrap:

```bash
make cluster-delete
make monitoring-bootstrap
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

## Verified Promotion Evidence

The complete chain was exercised on 2026-08-12 with source image commit
`752506d83fcb9435c4245e1337edd3ce6adf27a1` and registry digest
`sha256:ff919acbb4974a679b1816262acac0c8f2e7701a983e472da95a336cde9aa504`:

1. [PR #6](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/pull/6)
   promoted the image to dev. Argo reconciled merge commit
   `3174f8650f6434e2f684d69fdee4df68daf9f3f7` to `Synced / Healthy` before
   the dev smoke test passed.
2. [PR #7](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/pull/7)
   promoted the same tag and digest to stage. Argo reconciled merge commit
   `0c9c25ca0984b61e1ce3ed0434d56a773dbd08c4` to `Synced / Healthy` before
   the stage smoke test passed.
3. [PR #8](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/pull/8)
   promoted the same identity to prod. Argo reconciled merge commit
   `6203e04ce20aa509bac6290118ae272bd7dae01a` to `Synced / Healthy` before
   the prod smoke test passed.

The [final main workflow](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/actions/runs/31605961036)
completed all checks, image scanning, SBOM generation, and publication without annotations.
Registry verification then confirmed the same immutable tag and digest in all three
environment values, while the live Deployments referenced the repository by that digest.

This evidence distinguishes the source image commit from the three promotion
merge commits: promotion changes desired Git state but does not rebuild the image.
