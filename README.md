# Kubernetes GitOps Reliability Platform

A portfolio-grade Kubernetes delivery and reliability project built in small,
verifiable milestones. The final target is GitOps promotion, signed immutable
images, admission policy, telemetry, SLOs, and incident recovery evidence.

## Project Status

The **Local Kubernetes Foundation** is complete and proves a vertical slice
without cloud infrastructure. The **Secure Image Pipeline** adds pull-request
evidence and controlled GHCR publication:

```text
Go service
  -> hardened multi-stage container
  -> local kind image
  -> Helm release in namespace dev
  -> health/readiness/application/metrics smoke test
```

The service intentionally supports controlled failure modes for later SRE
exercises:

| Variable | Default | Contract |
| --- | ---: | --- |
| `PORT` | `8080` | `1..65535` |
| `APP_DELAY_MS` | `0` | `0..60000` |
| `APP_ERROR_RATE` | `0` | `0..1` |
| `APP_READY` | `true` | Boolean |

Invalid values fail closed during startup and through Helm schema validation.

## Secure Image Pipeline

Every pull request runs the project checks, builds the image, blocks on
`HIGH`/`CRITICAL` Trivy findings, and generates an SPDX JSON SBOM.
A separate job publishes the exact reviewed image only after the commit reaches `main`.
Images use `sha-<full-commit-sha>` tags; the pipeline does not publish `latest`.

The publish job alone receives `packages: write`. GitHub Actions, Go, Helm,
Trivy, and Syft versions are pinned. See `docs/secure-image-pipeline.md`
for the delivery contract and its explicit supply-chain boundary.

## Security Defaults

- exact digest for the Go builder image;
- `scratch` runtime image with no shell or package manager;
- non-root UID/GID `65532`;
- read-only root filesystem;
- no privilege escalation or Linux capabilities;
- `RuntimeDefault` seccomp profile;
- no mounted Kubernetes service-account token;
- CPU and memory requests/limits;
- liveness and readiness probes.

## Prerequisites

```text
Docker
kubectl
kind
Helm 3 or newer
Go 1.26+ or Docker for Go checks
curl
```

## Run The Local Foundation

Run checks first:

```bash
make check
```

Run the complete local vertical slice:

```bash
make local-demo
```

Inspect the deployment:

```bash
kubectl get pods,service,deployment -n dev
kubectl describe deployment reliability-demo -n dev
```

Delete only the disposable local cluster:

```bash
make cluster-delete
```

## Environment Values

Environment-specific values live under `gitops/environments/`. The Local
Kubernetes Foundation deploys only `dev`. Stage and prod values are render-tested
placeholders; they do not yet represent a promoted immutable image.

## Capability Status

| Capability | Status |
| --- | --- |
| Local Kubernetes deployment | Complete |
| GHCR image pipeline | Complete |
| SPDX JSON SBOM generation | Complete |
| Argo CD promotion | Planned |
| Admission policies | Planned |
| Signed build provenance | Planned |
| Observability and SLOs | Planned |
| Incident exercises | Planned |

See `docs/local-foundation-acceptance.md` for the completed local contract,
`docs/secure-image-pipeline.md` for the image delivery contract, and
`docs/roadmap.md` for the internal milestone map.

## Safety Boundary

The local demo creates and deletes only a kind cluster named `gitops-reliability`;
it does not push images, access AWS, or deploy cloud infrastructure.
GHCR publication happens only in GitHub Actions after a commit reaches `main`.
