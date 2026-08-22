# Supply Chain Provenance

The supply-chain capability binds a published GHCR image digest to the trusted
GitHub Actions workflow that built, scanned, and published it. It uses Cosign
keyless signing, so the repository stores no long-lived signing private key.

## Signing Boundary

Only the `Publish reviewed image` job runs for pushes to protected `main`. That
job receives `packages: write` and `id-token: write`; all pull-request jobs remain
read-only and cannot request a signing identity.

After GHCR returns the published digest, the workflow:

1. installs Cosign `v2.6.5` through a commit-pinned installer;
2. signs `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:...`;
3. verifies the signature against both:
   - issuer `https://token.actions.githubusercontent.com`;
   - identity `https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main`;
4. fails the publication job if no matching signature is found.

Signing the registry digest avoids trusting a mutable tag-to-digest mapping.
The image remains promoted with both its source commit tag and immutable digest.

## Admission Verification Status

Workflow signing and verification are complete. Cosign `v2.6.5` is a deliberate
compatibility pin. An isolated
[GitHub Actions run](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/actions/runs/32585583626)
signed an exact GHCR digest; Cosign accepted that digest and rejected an
unsigned digest. A subsequent live Kyverno `v1.18.2` admission test accepted
the signed image while rejecting an unsigned image and a wrong workflow
identity. A real registry DNS timeout also blocked admission, confirming the
fail-closed availability trade-off.

The pin avoids unreviewed compatibility flags. It is temporary because Kyverno
`v1.18.2` cannot discover default OCI 1.1 referring artifacts published by
Cosign v3 in GHCR; that incompatibility is tracked in
[Kyverno issue #16854](https://github.com/kyverno/kyverno/issues/16854).

Cluster-side signer-identity enforcement is still staged. The following
controls remain active during the transition:

- the trusted workflow signs and verifies the exact published GHCR digest;
- GitOps promotion carries the immutable tag and digest through dev, stage,
  and prod;
- Kyverno requires full `sha256` image digests;
- Kyverno continues to enforce restricted workload and read-only filesystem
  policies.

## Admission Activation Sequence

The compatibility proof does not by itself authorize immediate enforcement.
The complete sequence is:

```text
merge the reviewed Cosign v2.6.5 workflow pin
  -> publish a v2-signed image from protected main
  -> promote one signed identity through dev, stage, and prod
  -> audit signature verification for every live workload
  -> enforce Kyverno image signature verification
```

Any discovery error, verifier error, or failed negative test blocks enforcement.
The repository does not claim cluster-side provenance enforcement until this
sequence passes end to end. Migration back to Cosign v3 requires a stable
Kyverno release to repeat the signed, unsigned, wrong-identity, and verifier
failure tests before the version pin changes.

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
