# Local Kubernetes Foundation Acceptance Criteria

The foundation is complete when all of the following are demonstrated locally:

- Go configuration tests cover valid and invalid fault inputs.
- HTTP tests cover health, readiness, injected errors, and metrics.
- The builder image is pinned to an immutable digest.
- The runtime image is `scratch` and runs as UID/GID `65532`.
- The Helm chart renders dev, stage, and prod values.
- Schema validation rejects invalid replicas, error rate, and image digest.
- Rendered manifests disable service-account token mounting, privilege
  escalation, writable root filesystems, and Linux capabilities.
- A kind cluster accepts the locally built image.
- Helm deploys the dev release and waits for readiness.
- The smoke test reaches `/`, `/healthz`, `/readyz`, and `/metrics`.
