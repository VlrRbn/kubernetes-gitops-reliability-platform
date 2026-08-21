# Kubernetes GitOps Reliability Platform

A portfolio-grade Kubernetes delivery and reliability project built in small,
verifiable milestones. The final target is GitOps promotion, signed immutable
images, admission policy, telemetry, SLOs, and incident recovery evidence.

## Project Status

The **Local Kubernetes Foundation**, **Secure Image Pipeline**, **GitOps
Promotion**, and **Admission Policy** capabilities are complete. Together they
provide a local vertical slice, pull-request evidence, controlled GHCR
publication, environment reconciliation, and enforceable workload controls
without cloud infrastructure:

```text
Go service
  -> hardened multi-stage container
  -> local kind image
  -> Helm release in namespace local-dev
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
The same pinned scan runs daily with a refreshed vulnerability database so new
findings are reported even when no pull request is open.

The publish job alone receives `packages: write`. GitHub Actions, Go, Helm,
Trivy, and Syft versions are pinned. See `docs/secure-image-pipeline.md`
for the delivery contract and its explicit supply-chain boundary.

Published images are also signed keylessly with the GitHub Actions OIDC
identity of `secure-image.yml` on protected `main`. The workflow immediately
verifies the exact signed digest and expected issuer/identity. Cluster-side
signature enforcement remains deferred by the documented Kyverno/Cosign OCI
1.1 compatibility blocker; see `docs/supply-chain-provenance.md`.

## GitOps Promotion

Argo CD reconciles digest-pinned Helm releases for `dev`, `stage`, and `prod`
from protected `main`. Promotion resolves the public GHCR digest and enforces
the order `dev → stage → prod`; each environment change remains a separate PR.
The restricted AppProject denies cluster-scoped resources and permits only the
chart's `Deployment` and `Service` resources. See
`docs/gitops-promotion.md` for bootstrap, promotion, and deletion trade-offs.

## Admission Policy

Kyverno rejects mutable image references and workloads that violate the
Kubernetes restricted Pod Security Standard or use writable root filesystems
in the Argo-managed environments. Kyverno `v1.18.2`, Helm chart `3.8.2`, its
controller images, and the test CLI are pinned and verified. Bootstrap audits
the live workloads before switching policies to `Enforce`; see
`docs/admission-policy.md` for the contract and acceptance procedure.

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
jq
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
kubectl get pods,service,deployment -n local-dev
kubectl describe deployment reliability-demo -n local-dev
```

Delete only the disposable local cluster:

```bash
make cluster-delete
```

## Run The GitOps Platform

The GitOps path is separate from `make local-demo`. Run the checks, create the
kind cluster, and bootstrap Argo CD first:

```bash
make check
make argocd-bootstrap
```

Wait until all three generated Applications report `Synced` and `Healthy`:

```bash
kubectl get applications --namespace argocd --watch
```

Stop the watch with `Ctrl+C`, then install Kyverno. The bootstrap first audits
the existing `dev`, `stage`, and `prod` workloads and switches the policies to
`Enforce` only when the audit has no violations:

```bash
make kyverno-bootstrap
make admission-status
```

Confirm that Argo CD and all application environments remain healthy:

```bash
make argocd-status
NAMESPACE=dev make smoke-test
NAMESPACE=stage make smoke-test
NAMESPACE=prod make smoke-test
```

The required order is:

```text
kind cluster
  -> Argo CD
  -> dev, stage, and prod workloads
  -> Kyverno Audit
  -> Kyverno Enforce
```

`make kyverno-bootstrap` intentionally fails if Argo CD has not yet created
the three application namespaces.

Delete the complete disposable platform with `make cluster-delete`.

## Environment Values

Environment-specific values live under `gitops/environments/`. The Local
Kubernetes Foundation deploys to the separate `local-dev` namespace. Argo CD
exclusively owns `dev`, `stage`, and `prod`; their values contain real
digest-pinned GHCR images.

## Capability Status

| Capability | Status |
| --- | --- |
| Local Kubernetes deployment | Complete |
| GHCR image pipeline | Complete |
| SPDX JSON SBOM generation | Complete |
| Argo CD promotion | Complete |
| Admission policies | Complete |
| Signed build provenance | Signing complete; admission verification blocked upstream |
| Observability and SLOs | Planned |
| Incident exercises | Planned |

See `docs/local-foundation-acceptance.md` for the completed local contract,
`docs/secure-image-pipeline.md` for the image delivery contract, and
`docs/gitops-promotion.md` and `docs/admission-policy.md` for the cluster
delivery controls. `docs/roadmap.md` contains the internal milestone map.
Kyverno admission verification of Cosign v3 signatures is intentionally
deferred because the pinned Kyverno release cannot discover the default OCI
1.1 signature artifacts in GHCR. The exact boundary and exit criteria are
documented in `docs/supply-chain-provenance.md`.

## Safety Boundary

The local demo and control-plane bootstraps operate only on a kind cluster named
`gitops-reliability`; they do not push images, access AWS, or deploy cloud
infrastructure. GHCR publication happens only in GitHub Actions after a commit
reaches `main`.
