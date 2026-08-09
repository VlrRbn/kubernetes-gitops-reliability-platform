# GitOps Configuration

The Local Kubernetes Foundation stores environment-specific Helm values here,
but deploys only `dev` directly. The Secure Image Pipeline milestone will add
GHCR and immutable digests; the following milestone will add Argo CD
Applications and digest-based promotion. The placeholder stage/prod tags are
not deployable release evidence and must not be presented as immutable
promotion.
