# GitOps Configuration

The Local Kubernetes Foundation stores environment-specific Helm values here,
but deploys only `dev` directly. The Secure Image Pipeline publishes immutable
GHCR images after changes reach `main`; the following capability will add Argo
CD Applications and digest-based promotion. The placeholder stage/prod tags
are not deployable release evidence and must not be presented as immutable
promotion.
