# Secure Image Pipeline

The secure image workflow creates review evidence on every pull request and
publishes only after the same commit reaches `main`.

## Delivery Contract

1. Run the Go, Helm, shell, and negative guardrail tests.
2. Build one local image tagged with the full commit SHA.
3. Fail on any `HIGH` or `CRITICAL` Trivy finding, including unfixed findings.
4. Generate an SPDX JSON SBOM with a pinned Syft release.
5. Export the scanned image as a short-lived workflow artifact.
6. On `main` only, load that artifact and publish it to GHCR.

The published identity is:

```text
ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform:sha-<full-commit-sha>
```

The pipeline does not publish a mutable `latest` tag. The publish job is the
only job granted `packages: write`; pull-request jobs retain read-only repository
permissions. All referenced actions use full commit SHAs with reviewed version comments.

## Evidence And Retention

- The SPDX JSON SBOM is retained as a workflow artifact for 14 days.
- The reviewed Docker archive is retained for one day and exists only to pass
  the exact scanned bytes into the isolated publish job.
- The final GHCR digest is written to the workflow summary.

## Local Contract Test

```bash
make check
```

The workflow tests include negative cases for an unpinned action, a
non-blocking vulnerability scan, ignored unfixed findings, a mutable image tag,
publication outside `main`, and a missing pull-request trigger.
