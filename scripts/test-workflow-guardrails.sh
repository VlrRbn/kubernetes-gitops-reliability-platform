#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-secure-image-workflow.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/secure-image.yml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_rejected() {
  local name="$1"
  local candidate="$2"
  local expected_reason="$3"
  local output

  echo "Testing negative case: $name"

  if output="$("$VALIDATOR" "$candidate" 2>&1)"; then
    echo "FAIL: validator accepted negative case: $name" >&2
    exit 1
  fi

  echo "$output"

  if ! grep -Fq -- "$expected_reason" <<< "$output"; then
    echo "FAIL: validator rejected '$name' for the wrong reason" >&2
    echo "Expected: $expected_reason" >&2
    exit 1
  fi

  echo "PASS: $name"
}

"$VALIDATOR" "$WORKFLOW"

cp "$WORKFLOW" "${TEST_DIR}/missing-scheduled-scan.yml"
sed -i '/^  schedule:$/,+1d' "${TEST_DIR}/missing-scheduled-scan.yml"
expect_rejected \
  "missing scheduled vulnerability scan" \
  "${TEST_DIR}/missing-scheduled-scan.yml" \
  "Scheduled vulnerability scans are required"

cp "$WORKFLOW" "${TEST_DIR}/missing-manual-scan.yml"
sed -i '/^  workflow_dispatch:$/d' "${TEST_DIR}/missing-manual-scan.yml"
expect_rejected \
  "missing manual vulnerability scan" \
  "${TEST_DIR}/missing-manual-scan.yml" \
  "Manual vulnerability scans are required"

cp "$WORKFLOW" "${TEST_DIR}/shared-main-concurrency.yml"
# The mutation targets literal GitHub Actions expressions.
# shellcheck disable=SC2016
sed -i 's/${{ github.event_name }}-//' "${TEST_DIR}/shared-main-concurrency.yml"
expect_rejected \
  "scheduled scan sharing publication concurrency" \
  "${TEST_DIR}/shared-main-concurrency.yml" \
  "Scheduled scans must not cancel pull request or publication workflows"

cp "$WORKFLOW" "${TEST_DIR}/outdated-go-version.yml"
sed -i 's/GO_VERSION: 1.26.6/GO_VERSION: 1.26.5/' \
  "${TEST_DIR}/outdated-go-version.yml"
expect_rejected \
  "outdated vulnerable Go version" \
  "${TEST_DIR}/outdated-go-version.yml" \
  "Go must be pinned to the reviewed version 1.26.6"

cp "$WORKFLOW" "${TEST_DIR}/unpinned-action.yml"
sed -i -E 's|actions/checkout@[0-9a-f]{40}|actions/checkout@v5|' "${TEST_DIR}/unpinned-action.yml"
expect_rejected \
  "unpinned action" \
  "${TEST_DIR}/unpinned-action.yml" \
  "GitHub Actions must be pinned to a full commit SHA"

cp "$WORKFLOW" "${TEST_DIR}/non-blocking-scan.yml"
sed -i 's/exit-code: "1"/exit-code: "0"/' "${TEST_DIR}/non-blocking-scan.yml"
expect_rejected \
  "non-blocking vulnerability scan" \
  "${TEST_DIR}/non-blocking-scan.yml" \
  "Trivy findings must fail the workflow"

cp "$WORKFLOW" "${TEST_DIR}/ignore-unfixed.yml"
sed -i 's/ignore-unfixed: false/ignore-unfixed: true/' "${TEST_DIR}/ignore-unfixed.yml"
expect_rejected \
  "ignored unfixed vulnerabilities" \
  "${TEST_DIR}/ignore-unfixed.yml" \
  "Unfixed vulnerabilities must not be ignored"

cp "$WORKFLOW" "${TEST_DIR}/mutable-tag.yml"
# The mutation targets the literal GitHub Actions expression.
# shellcheck disable=SC2016
sed -i 's/sha-${GITHUB_SHA}/latest/g' "${TEST_DIR}/mutable-tag.yml"
expect_rejected \
  "mutable image tag" \
  "${TEST_DIR}/mutable-tag.yml" \
  "Container images must use the full immutable commit SHA tag"

cp "$WORKFLOW" "${TEST_DIR}/publish-from-branch.yml"
sed -i "s|github.event_name == 'push' && github.ref == 'refs/heads/main'|github.event_name == 'push'|" \
  "${TEST_DIR}/publish-from-branch.yml"
expect_rejected \
  "publication outside main" \
  "${TEST_DIR}/publish-from-branch.yml" \
  "Image publication must be restricted to push events on main"

cp "$WORKFLOW" "${TEST_DIR}/missing-pr.yml"
sed -i '/^  pull_request:$/d' "${TEST_DIR}/missing-pr.yml"
expect_rejected \
  "missing pull request trigger" \
  "${TEST_DIR}/missing-pr.yml" \
  "Pull request checks are required"

cp "$WORKFLOW" "${TEST_DIR}/missing-image-verification.yml"
sed -i '\|run: ./scripts/verify-environment-images\.sh|d' \
  "${TEST_DIR}/missing-image-verification.yml"
expect_rejected \
  "missing environment image verification" \
  "${TEST_DIR}/missing-image-verification.yml" \
  "CI must run immutable environment image verification"

cp "$WORKFLOW" "${TEST_DIR}/hardcoded-image-version.yml"
# The mutation targets a literal GitHub Actions expression.
# shellcheck disable=SC2016
sed -i 's|VERSION=sha-${{ github\.sha }}|VERSION=0.2.0|' \
  "${TEST_DIR}/hardcoded-image-version.yml"
expect_rejected \
  "hardcoded image version metadata" \
  "${TEST_DIR}/hardcoded-image-version.yml" \
  "Image version metadata must use the full commit SHA"

cp "$WORKFLOW" "${TEST_DIR}/missing-signing-oidc.yml"
sed -i '/^[[:space:]]*id-token: write$/d' "${TEST_DIR}/missing-signing-oidc.yml"
expect_rejected \
  "missing signing OIDC permission" \
  "${TEST_DIR}/missing-signing-oidc.yml" \
  "id-token: write must be granted exactly once"

cp "$WORKFLOW" "${TEST_DIR}/signing-oidc-outside-publish.yml"
sed -i '/^[[:space:]]*id-token: write$/d' "${TEST_DIR}/signing-oidc-outside-publish.yml"
sed -i '0,/^  contents: read$/s//  contents: read\n  id-token: write/' \
  "${TEST_DIR}/signing-oidc-outside-publish.yml"
expect_rejected \
  "signing OIDC permission outside the publish job" \
  "${TEST_DIR}/signing-oidc-outside-publish.yml" \
  "id-token: write must be granted exactly once, to the trusted publish job"

cp "$WORKFLOW" "${TEST_DIR}/signing-tag-instead-of-digest.yml"
# The mutation targets literal workflow shell expressions.
# shellcheck disable=SC2016
sed -i 's|cosign sign --yes "${IMAGE_REPOSITORY,,}@${IMAGE_DIGEST}"|cosign sign --yes "$IMAGE_REF"|' \
  "${TEST_DIR}/signing-tag-instead-of-digest.yml"
expect_rejected \
  "signing a mutable tag instead of the published digest" \
  "${TEST_DIR}/signing-tag-instead-of-digest.yml" \
  "Cosign must sign the exact published digest"

cp "$WORKFLOW" "${TEST_DIR}/permissive-signer-identity.yml"
# The mutation targets the literal GitHub Actions expression.
# shellcheck disable=SC2016
sed -i 's|https://github.com/${{ github.repository }}/.github/workflows/secure-image.yml@refs/heads/main|.*|' \
  "${TEST_DIR}/permissive-signer-identity.yml"
expect_rejected \
  "permissive signer identity" \
  "${TEST_DIR}/permissive-signer-identity.yml" \
  "The signer identity must be restricted to secure-image.yml on main"

cp "$WORKFLOW" "${TEST_DIR}/missing-signature-verification.yml"
# The mutation targets a literal workflow shell expression.
# shellcheck disable=SC2016
sed -i '/--certificate-oidc-issuer "$CERTIFICATE_OIDC_ISSUER"/d' \
  "${TEST_DIR}/missing-signature-verification.yml"
expect_rejected \
  "missing signature issuer verification" \
  "${TEST_DIR}/missing-signature-verification.yml" \
  "Cosign verification must require the GitHub OIDC issuer"

echo "Workflow guardrail negative tests passed"
