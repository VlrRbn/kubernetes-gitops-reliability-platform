# Kubernetes GitOps Reliability Platform

A portfolio-grade Kubernetes delivery and reliability project built in small,
verifiable milestones. The final target is GitOps promotion, signed immutable
images, admission policy, telemetry, SLOs, and incident recovery evidence.

## Project Status

The **Local Kubernetes Foundation**, **Secure Image Pipeline**, **GitOps
Promotion**, **Admission Policy**, **Supply Chain Provenance**, and
**Observability** capabilities are complete. Together they provide a local
vertical slice, pull-request evidence, controlled GHCR publication,
environment reconciliation, enforceable workload controls, and SLO telemetry
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
verifies the exact signed digest and expected issuer/identity. Cosign `v2.6.5`
is pinned as the reviewed compatibility line for Kyverno `v1.18.2`. The
cluster-side signature policy and its positive and negative contract tests are
implemented and live enforcement acceptance is complete. See
`docs/supply-chain-provenance.md`.

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
in the Argo-managed environments. It also verifies that every workload image
was signed by `secure-image.yml` on protected `main`. Kyverno `v1.18.2`, Helm
chart `3.8.2`, its controller images, and the test CLI are pinned and verified.
Bootstrap audits newly introduced policies against live workloads before
switching them to `Enforce`; see
`docs/admission-policy.md` for the contract and acceptance procedure.

## Observability And SLOs

The pinned `kube-prometheus-stack` installs Prometheus, Alertmanager, and Grafana
into the disposable kind cluster. Prometheus discovers only labeled `ServiceMonitor`
resources in `dev`, `stage`, and `prod`. Reviewed recording rules calculate
request rate, error rate, five-minute availability, and p95 latency; alerts cover
sustained availability below 99% and p95 latency above 500 ms.

Grafana provisions the version-controlled **Reliability Demo SLOs** dashboard
without an editable sidecar. It shows availability, traffic, errors, latency,
scrape health, and firing alerts for all three environments. Alertmanager uses
a local webhook delivery contract that is exercised by a synthetic alert.
See `docs/observability.md` for bootstrap, access, evidence, and trade-offs.

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

The local foundation is a standalone acceptance path, not the first step of
the GitOps platform bootstrap. `make local-demo` builds an image on the local
machine, loads it directly into kind, and installs a Helm release only in the
`local-dev` namespace. It does not install Argo CD, monitoring, or Kyverno and
does not create the GitOps-managed `dev`, `stage`, or `prod` workloads.

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

The GitOps path uses digest-pinned GHCR images and does not require
`make local-demo`. Install the monitoring foundation before Argo CD because
the application chart contains `ServiceMonitor` resources and a clean cluster
does not yet have that CRD:

```bash
make check
make monitoring-bootstrap
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

Verify alert delivery through the installed monitoring stack and access the
provisioned Grafana dashboard:

```bash
make alertmanager-test
make grafana-password
make grafana-port-forward
```

The port-forward remains attached to the terminal and exposes Grafana at
`http://localhost:3000`.
Sign in as `admin` with the generated password printed by `make grafana-password`.

The required order is:

```text
kind cluster
  -> Prometheus Operator and ServiceMonitor CRDs
  -> Prometheus, Alertmanager, and Grafana
  -> Argo CD
  -> dev, stage, and prod workloads
  -> Kyverno Audit
  -> Kyverno Enforce
  -> SLO and alert-delivery verification
```

`make argocd-bootstrap` intentionally fails when the `ServiceMonitor` CRD is
missing instead of creating Applications that can never sync.
`make kyverno-bootstrap` intentionally fails if Argo CD has not yet created
the three application namespaces.

Delete the complete disposable platform with `make cluster-delete`.
This deletes the entire `gitops-reliability` kind cluster, including
`local-dev` when the standalone local demo was run in that same cluster.

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
| Signed build provenance | Complete |
| Observability and SLOs | Complete |
| Incident exercises | Planned |

See `docs/local-foundation-acceptance.md` for the completed local contract,
`docs/secure-image-pipeline.md` for the image delivery contract, and
`docs/gitops-promotion.md` and `docs/admission-policy.md` for the cluster
delivery controls, and `docs/observability.md` for the monitoring and SLO
contract. `docs/roadmap.md` contains the internal milestone map.
Cosign is temporarily pinned to the reviewed `v2.6.5` compatibility line because
the pinned Kyverno release cannot discover default Cosign v3 OCI 1.1 signature
artifacts in GHCR. The signature policy must pass its live audit before this
repository claims active enforcement; that acceptance is complete and the
boundary is documented in
`docs/supply-chain-provenance.md`.

## Safety Boundary

The local demo and control-plane bootstraps operate only on a kind cluster named
`gitops-reliability`; they do not push images, access AWS, or deploy cloud
infrastructure. GHCR publication happens only in GitHub Actions after a commit
reaches `main`.
