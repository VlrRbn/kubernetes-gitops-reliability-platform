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
7. Sign the exact registry digest with a keyless GitHub OIDC identity and verify
   the resulting signature before the publish job succeeds.

The published identity is:

```text
ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform:sha-<full-commit-sha>
```

The pipeline does not publish a mutable `latest` tag. The publish job is the
only job granted `packages: write`; pull-request jobs retain read-only repository
permissions. The same trusted job alone receives `id-token: write`, which is
required for short-lived keyless signing and is never available to pull-request
jobs. All referenced actions use full commit SHAs with reviewed version comments.

Cosign verification requires both the GitHub Actions issuer and the exact
`secure-image.yml` workflow identity on `main`. The workflow signs the digest
returned by GHCR, not the human-readable tag.

## Continuous Vulnerability Re-evaluation

The same pinned build and Trivy scan runs every day at `06:00 UTC` and can be
started manually with `workflow_dispatch`. Trivy remains pinned to the reviewed
binary version while its vulnerability database is refreshed, allowing newly
published `HIGH` or `CRITICAL` findings in the current `main` binary to fail CI
before an unrelated pull request is merged.

Scheduled and manual runs never publish an image because publication requires a
`push` event on `main`. Their concurrency key includes the event type, so they
cannot cancel an in-progress pull-request check or trusted publication run.

## Evidence And Retention

- The SPDX JSON SBOM is retained as a workflow artifact for 14 days.
- The reviewed Docker archive is retained for one day and exists only to pass
  the exact scanned bytes into the isolated publish job.
- The final GHCR digest is written to the workflow summary.

Verified evidence from 2026-08-10:

- [pull-request validation](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/actions/runs/31383846632)
  completed the checks, vulnerability scan, and SBOM generation without publishing;
- [main publication](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/actions/runs/31384026828)
  published the reviewed archive with no workflow annotations;
- commit `96201f3b7aca24bd6781889911588f10a63c0a17` produced public image tag
  `sha-96201f3b7aca24bd6781889911588f10a63c0a17`;
- the registry returned digest
  `sha256:2b3fb9dd442fe6fc24ff9b3c47f7678cf5593f5fdf9b123b74b83cbac557e8d7`;
- `main` requires both `Application and chart checks` and `Build, scan, and inventory image`,
  with strict branch updates, linear history, admin enforcement, and no force-push or branch deletion.

The workflow run and immutable GHCR identity remain useful evidence after the
short-lived workflow artifacts expire.

## Local Contract Test

```bash
make check
```

The workflow tests include negative cases for an unpinned action, a
non-blocking vulnerability scan, ignored unfixed findings, a mutable image tag,
publication outside `main`, and a missing pull-request trigger.
Negative cases also reject missing signing OIDC permission, signing a tag
instead of the published digest, a permissive signer identity, and missing
issuer verification.
