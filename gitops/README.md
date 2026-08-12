# GitOps Configuration

Environment values contain both the immutable GHCR tag and its registry digest.
Argo CD renders the chart with the digest, while the tag preserves the source
commit identity for operators. The promotion helper advances one published
identity through `dev`, `stage`, and `prod`; stage/prod cannot skip their source
environment. CI independently resolves every tag and rejects digest mismatch.

The local Helm demo deploys into `local-dev`, overrides the image, and clears
its digest explicitly. It does not share resources with the Argo-managed
environment contract.
