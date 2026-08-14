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

## Activation Sequence

Image signing must exist before cluster enforcement. The controlled sequence is:

```text
merge signing workflow
  -> publish and verify a signed image
  -> promote the same signed identity through dev, stage, and prod
  -> audit signature verification for all live workloads
  -> enforce Kyverno image signature verification
```

Applying signature enforcement before this sequence would reject rollouts of the
currently promoted image, which predates signing. The Kyverno enforcement policy is
therefore added only after a signed image has completed the normal promotion chain.

## Trust And Availability Trade-offs

Keyless signing removes private-key storage and rotation, but it depends on
GitHub OIDC and the public Sigstore services. The certificate binds the signature
to a workflow identity; repository and branch protection remain part of that
trust boundary. Signature verification will fail closed when the configured
verifier cannot establish the required identity.

This capability proves image authenticity. It does not implement progressive
delivery, automated rollback, or a private Sigstore deployment.
