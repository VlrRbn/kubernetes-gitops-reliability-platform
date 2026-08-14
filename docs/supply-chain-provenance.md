# Supply Chain Provenance

The supply-chain capability binds a published GHCR image digest to the trusted
GitHub Actions workflow that built, scanned, and published it. It uses Cosign
keyless signing, so the repository stores no long-lived signing private key.

## Signing Boundary

Only the `Publish reviewed image` job runs for pushes to protected `main`. That
job receives `packages: write` and `id-token: write`; all pull-request jobs remain
read-only and cannot request a signing identity.

After GHCR returns the published digest, the workflow:

1. installs Cosign `v3.1.3` through a commit-pinned installer;
2. signs `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:...`;
3. verifies the signature against both:
   - issuer `https://token.actions.githubusercontent.com`;
   - identity `https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main`;
4. fails the publication job if no matching signature is found.

Signing the registry digest avoids trusting a mutable tag-to-digest mapping.
The image remains promoted with both its source commit tag and immutable digest.

## Admission Verification Status

Workflow signing and verification are complete. Admission verification is
intentionally deferred because Kyverno `v1.18.2` `ClusterPolicy verifyImages`
does not discover the default OCI 1.1 referring artifacts published by Cosign
`v3.1.3` in GHCR. Cosign verifies the same keyless signature successfully, but
Kyverno reports `no signatures found`. The incompatibility is tracked in
[Kyverno issue #16854](https://github.com/kyverno/kyverno/issues/16854).

The project does not switch Cosign to the deprecated legacy bundle and signing
configuration modes as a workaround. Keeping the default Cosign v3 format
avoids adding a temporary compatibility path to the trusted publication job.

This limitation affects only signer-identity enforcement at Kubernetes
admission. The following controls remain active:

- the trusted workflow signs and verifies the exact published GHCR digest;
- GitOps promotion carries the immutable tag and digest through dev, stage,
  and prod;
- Kyverno requires full `sha256` image digests;
- Kyverno continues to enforce restricted workload and read-only filesystem
  policies.

## Resume Criteria

Admission signature enforcement resumes only after a stable Kyverno release
can consume the default Cosign v3 signature format. The complete sequence is:

```text
upgrade the pinned Kyverno release
  -> prove a signed GHCR digest is accepted
  -> prove an unsigned GHCR digest is rejected
  -> promote one signed identity through dev, stage, and prod
  -> audit signature verification for every live workload
  -> enforce Kyverno image signature verification
```

Any discovery error, verifier error, or failed negative test blocks enforcement.
The repository does not claim cluster-side provenance enforcement until this
sequence passes end to end.

## Trust And Availability Trade-offs

Keyless signing removes private-key storage and rotation, but it depends on
GitHub OIDC and the public Sigstore services. The certificate binds the signature
to a workflow identity; repository and branch protection remain part of that
trust boundary. Signature verification will fail closed when the configured
verifier cannot establish the required identity.

The publication workflow proves image authenticity at build time. Kubernetes
admission currently proves image immutability, but not signer identity. This
capability does not implement progressive delivery, automated rollback, or a
private Sigstore deployment.
