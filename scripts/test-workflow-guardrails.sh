#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-secure-image-workflow.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/secure-image.yml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
YAML_CHART="${TEST_DIR}/yaml-validator"

mkdir -p "${YAML_CHART}/files" "${YAML_CHART}/templates"
printf '%s\n' \
  'apiVersion: v2' \
  'name: workflow-yaml-validator' \
  'version: 0.1.0' \
  > "${YAML_CHART}/Chart.yaml"
# These are literal Helm template expressions, not shell expansions.
# shellcheck disable=SC2016
printf '%s\n' \
  '{{- $workflow := .Files.Get "files/workflow.yml" | fromYaml }}' \
  '{{- if hasKey $workflow "Error" }}{{ fail (get $workflow "Error") }}{{ end }}' \
  'apiVersion: v1' \
  'kind: ConfigMap' \
  'metadata:' \
  '  name: workflow-yaml-validator' \
  > "${YAML_CHART}/templates/validate.yaml"

assert_valid_workflow_yaml() {
  local candidate="$1"

  cp "$candidate" "${YAML_CHART}/files/workflow.yml"
  helm template workflow-yaml-validator "$YAML_CHART" >/dev/null || {
    echo "FAIL: negative fixture is not valid YAML: $candidate" >&2
    exit 1
  }
}

replace_job_permissions_with_scalar() {
  local candidate="$1"
  local job_name="$2"
  local scalar="$3"
  local rewritten="${candidate}.rewritten"

  awk -v job_marker="  ${job_name}:" -v scalar="$scalar" '
    $0 == job_marker { in_job = 1 }
    in_job && $0 == "    permissions:" {
      print "    permissions: " scalar
      skip_entries = 1
      next
    }
    skip_entries && /^      [a-z][a-z-]*: (read|write|none)$/ { next }
    skip_entries { skip_entries = 0 }
    { print }
  ' "$candidate" > "$rewritten"
  mv "$rewritten" "$candidate"
}

expect_rejected() {
  local name="$1"
  local candidate="$2"
  local expected_reason="$3"
  local output

  echo "Testing negative case: $name"
  assert_valid_workflow_yaml "$candidate"

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

assert_valid_workflow_yaml "$WORKFLOW"
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

cp "$WORKFLOW" "${TEST_DIR}/cancellable-main-publication.yml"
# The mutation targets the literal GitHub Actions expression.
# shellcheck disable=SC2016
sed -i "s/cancel-in-progress: \${{ github.event_name == 'pull_request' }}/cancel-in-progress: true/" \
  "${TEST_DIR}/cancellable-main-publication.yml"
expect_rejected \
  "cancellable trusted main publication" \
  "${TEST_DIR}/cancellable-main-publication.yml" \
  "Trusted main publication must not be cancellable"

cp "$WORKFLOW" "${TEST_DIR}/outdated-go-version.yml"
sed -i 's/GO_VERSION: 1.26.6/GO_VERSION: 1.26.5/' \
  "${TEST_DIR}/outdated-go-version.yml"
expect_rejected \
  "outdated vulnerable Go version" \
  "${TEST_DIR}/outdated-go-version.yml" \
  "Go must be pinned to the reviewed version 1.26.6"

cp "$WORKFLOW" "${TEST_DIR}/incompatible-cosign-version.yml"
sed -i 's/COSIGN_VERSION: v2.6.5/COSIGN_VERSION: v3.1.3/' \
  "${TEST_DIR}/incompatible-cosign-version.yml"
expect_rejected \
  "Cosign version incompatible with pinned Kyverno" \
  "${TEST_DIR}/incompatible-cosign-version.yml" \
  "Cosign must be pinned to the reviewed Kyverno-compatible version v2.6.5"

cp "$WORKFLOW" "${TEST_DIR}/unpinned-action.yml"
sed -i -E 's|actions/checkout@[0-9a-f]{40}|actions/checkout@v5|' "${TEST_DIR}/unpinned-action.yml"
expect_rejected \
  "unpinned action" \
  "${TEST_DIR}/unpinned-action.yml" \
  "GitHub Actions must be pinned to a full commit SHA"

cp "$WORKFLOW" "${TEST_DIR}/top-level-write-all.yml"
sed -i '/^permissions:$/ { N; s/^permissions:\n  contents: read$/permissions: write-all/; }' \
  "${TEST_DIR}/top-level-write-all.yml"
expect_rejected \
  "top-level write-all permissions" \
  "${TEST_DIR}/top-level-write-all.yml" \
  "permissions: write-all is forbidden at every workflow scope"

cp "$WORKFLOW" "${TEST_DIR}/checks-write-all.yml"
sed -i '/^    name: Application and chart checks$/a\    permissions: write-all' \
  "${TEST_DIR}/checks-write-all.yml"
expect_rejected \
  "checks job write-all permissions" \
  "${TEST_DIR}/checks-write-all.yml" \
  "permissions: write-all is forbidden at every workflow scope"

cp "$WORKFLOW" "${TEST_DIR}/image-write-all.yml"
replace_job_permissions_with_scalar \
  "${TEST_DIR}/image-write-all.yml" \
  image \
  write-all
expect_rejected \
  "image job write-all permissions" \
  "${TEST_DIR}/image-write-all.yml" \
  "permissions: write-all is forbidden at every workflow scope"

cp "$WORKFLOW" "${TEST_DIR}/publish-write-all.yml"
replace_job_permissions_with_scalar \
  "${TEST_DIR}/publish-write-all.yml" \
  publish \
  write-all
expect_rejected \
  "publish job write-all permissions" \
  "${TEST_DIR}/publish-write-all.yml" \
  "permissions: write-all is forbidden at every workflow scope"

cp "$WORKFLOW" "${TEST_DIR}/top-level-read-all.yml"
sed -i '/^permissions:$/ { N; s/^permissions:\n  contents: read$/permissions: read-all/; }' \
  "${TEST_DIR}/top-level-read-all.yml"
expect_rejected \
  "implicit read-all permissions" \
  "${TEST_DIR}/top-level-read-all.yml" \
  "permissions: read-all is forbidden; permissions must be explicit"

cp "$WORKFLOW" "${TEST_DIR}/checks-contents-write.yml"
sed -i '/^    name: Application and chart checks$/a\    permissions:\n      contents: write' \
  "${TEST_DIR}/checks-contents-write.yml"
expect_rejected \
  "checks job contents write permission" \
  "${TEST_DIR}/checks-contents-write.yml" \
  "Checks job must inherit the top-level read-only permissions"

cp "$WORKFLOW" "${TEST_DIR}/image-actions-write.yml"
sed -i '/^  image:$/,/^  publish:$/ s/^      contents: read$/&\n      actions: write/' \
  "${TEST_DIR}/image-actions-write.yml"
expect_rejected \
  "image job additional actions write permission" \
  "${TEST_DIR}/image-actions-write.yml" \
  "Image job permissions must contain only contents: read"

cp "$WORKFLOW" "${TEST_DIR}/publish-issues-write.yml"
sed -i '/^  publish:$/,$ s/^      packages: write$/&\n      issues: write/' \
  "${TEST_DIR}/publish-issues-write.yml"
expect_rejected \
  "publish job additional issues write permission" \
  "${TEST_DIR}/publish-issues-write.yml" \
  "Publish job permissions must contain exactly contents: read, id-token: write, and packages: write"

cp "$WORKFLOW" "${TEST_DIR}/unreviewed-job-write.yml"
sed -i '/^  image:$/i\  unreviewed:\n    runs-on: ubuntu-24.04\n    permissions:\n      issues: write\n    steps:\n      - run: "true"\n' \
  "${TEST_DIR}/unreviewed-job-write.yml"
expect_rejected \
  "additional write permission in an unreviewed job" \
  "${TEST_DIR}/unreviewed-job-write.yml" \
  "Workflow must contain exactly the reviewed checks, image, and publish jobs"

cp "$WORKFLOW" "${TEST_DIR}/inline-unreviewed-job-write.yml"
sed -i '/^  image:$/i\  unreviewed:\n    runs-on: ubuntu-24.04\n    permissions: {issues: write}\n    steps:\n      - run: "true"\n' \
  "${TEST_DIR}/inline-unreviewed-job-write.yml"
expect_rejected \
  "inline write permission in an unreviewed job" \
  "${TEST_DIR}/inline-unreviewed-job-write.yml" \
  "Workflow must contain exactly the reviewed checks, image, and publish jobs"

cp "$WORKFLOW" "${TEST_DIR}/inline-image-write.yml"
sed -i '/^  image:$/,/^  publish:$/ { /^    permissions:$/ { N; s/^    permissions:\n      contents: read$/    permissions: {contents: write}/; } }' \
  "${TEST_DIR}/inline-image-write.yml"
expect_rejected \
  "inline contents write permission in image job" \
  "${TEST_DIR}/inline-image-write.yml" \
  "Image job permissions must contain only contents: read"

cp "$WORKFLOW" "${TEST_DIR}/non-blocking-scan.yml"
sed -i 's/exit-code: "1"/exit-code: "0"/' "${TEST_DIR}/non-blocking-scan.yml"
expect_rejected \
  "non-blocking vulnerability scan" \
  "${TEST_DIR}/non-blocking-scan.yml" \
  "Trivy findings must fail the workflow"

cp "$WORKFLOW" "${TEST_DIR}/continue-on-error-trivy.yml"
sed -i '/name: Scan image for high and critical vulnerabilities/a\        continue-on-error: true' \
  "${TEST_DIR}/continue-on-error-trivy.yml"
expect_rejected \
  "continue-on-error on Trivy scan" \
  "${TEST_DIR}/continue-on-error-trivy.yml" \
  "Trivy scan failures must block the workflow"

cp "$WORKFLOW" "${TEST_DIR}/continue-on-error-signing.yml"
sed -i '/name: Sign published image identity/a\        continue-on-error: true' \
  "${TEST_DIR}/continue-on-error-signing.yml"
expect_rejected \
  "continue-on-error on Cosign signing" \
  "${TEST_DIR}/continue-on-error-signing.yml" \
  "Cosign signing failures must block the workflow"

cp "$WORKFLOW" "${TEST_DIR}/continue-on-error-verification.yml"
sed -i '/name: Verify published image signature/a\        continue-on-error: true' \
  "${TEST_DIR}/continue-on-error-verification.yml"
expect_rejected \
  "continue-on-error on signature verification" \
  "${TEST_DIR}/continue-on-error-verification.yml" \
  "Signature verification failures must block the workflow"

for security_step in \
  "Scan image for high and critical vulnerabilities" \
  "Sign published image identity" \
  "Verify published image signature"; do
  case_name="$(tr '[:upper:] ' '[:lower:]-' <<< "$security_step")"
  candidate="${TEST_DIR}/expression-continue-${case_name}.yml"
  cp "$WORKFLOW" "$candidate"
  # The mutation targets the literal GitHub Actions expression.
  # shellcheck disable=SC2016
  sed -i "/name: ${security_step}/a\\        continue-on-error: \${{ true }}" "$candidate"
  case "$security_step" in
    "Scan image for high and critical vulnerabilities")
      expected_reason="Trivy scan failures must block the workflow"
      ;;
    "Sign published image identity")
      expected_reason="Cosign signing failures must block the workflow"
      ;;
    "Verify published image signature")
      expected_reason="Signature verification failures must block the workflow"
      ;;
  esac
  expect_rejected \
    "expression-based continue-on-error: ${security_step}" \
    "$candidate" \
    "$expected_reason"
done

for job_name in image publish; do
  candidate="${TEST_DIR}/continue-on-error-${job_name}-job.yml"
  cp "$WORKFLOW" "$candidate"
  sed -i "/^  ${job_name}:$/a\\    continue-on-error: true" "$candidate"
  expect_rejected \
    "continue-on-error on ${job_name} job" \
    "$candidate" \
    "${job_name^} job failures must block the workflow"
done

for security_step in \
  "Scan image for high and critical vulnerabilities" \
  "Sign published image identity" \
  "Verify published image signature"; do
  case_name="$(tr '[:upper:] ' '[:lower:]-' <<< "$security_step")"
  candidate="${TEST_DIR}/disabled-${case_name}.yml"
  cp "$WORKFLOW" "$candidate"
  sed -i "/name: ${security_step}/a\\        if: false" "$candidate"
  expect_rejected \
    "disabled security step: ${security_step}" \
    "$candidate" \
    "Security-critical workflow steps must not be disabled or conditionally skipped: ${security_step}"
done

cp "$WORKFLOW" "${TEST_DIR}/missing-trivy-step.yml"
sed -i '/      - name: Scan image for high and critical vulnerabilities/,/      - name: Generate SPDX JSON SBOM/{/      - name: Generate SPDX JSON SBOM/!d;}' \
  "${TEST_DIR}/missing-trivy-step.yml"
expect_rejected \
  "missing Trivy security step" \
  "${TEST_DIR}/missing-trivy-step.yml" \
  "Security-critical workflow step is missing: Scan image for high and critical vulnerabilities"

cp "$WORKFLOW" "${TEST_DIR}/missing-signing-step.yml"
sed -i '/      - name: Sign published image identity/,/      - name: Verify published image signature/{/      - name: Verify published image signature/!d;}' \
  "${TEST_DIR}/missing-signing-step.yml"
expect_rejected \
  "missing Cosign signing step" \
  "${TEST_DIR}/missing-signing-step.yml" \
  "Security-critical workflow step is missing: Sign published image identity"

cp "$WORKFLOW" "${TEST_DIR}/missing-verification-step.yml"
sed -i '/      - name: Verify published image signature/,/      - name: Record published identity/{/      - name: Record published identity/!d;}' \
  "${TEST_DIR}/missing-verification-step.yml"
expect_rejected \
  "missing signature verification step" \
  "${TEST_DIR}/missing-verification-step.yml" \
  "Security-critical workflow step is missing: Verify published image signature"

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
  "CI must run signed environment image verification"

cp "$WORKFLOW" "${TEST_DIR}/missing-promotion-diff-validation.yml"
sed -i '/      - name: Validate ordered environment promotion/,/      - name: Set up Go/{/      - name: Set up Go/!d;}' \
  "${TEST_DIR}/missing-promotion-diff-validation.yml"
expect_rejected \
  "missing ordered promotion validation" \
  "${TEST_DIR}/missing-promotion-diff-validation.yml" \
  "CI must enforce ordered environment promotion"

cp "$WORKFLOW" "${TEST_DIR}/shallow-promotion-checkout.yml"
sed -i '0,/fetch-depth: 0/s//fetch-depth: 1/' "${TEST_DIR}/shallow-promotion-checkout.yml"
expect_rejected \
  "pull request base commit unavailable" \
  "${TEST_DIR}/shallow-promotion-checkout.yml" \
  "Pull request checks must fetch the reviewed base commit"

cp "$WORKFLOW" "${TEST_DIR}/missing-environment-cosign.yml"
sed -i '/name: Install Cosign for environment verification/,+3d' \
  "${TEST_DIR}/missing-environment-cosign.yml"
expect_rejected \
  "missing reviewed Cosign for environment verification" \
  "${TEST_DIR}/missing-environment-cosign.yml" \
  "CI must install reviewed Cosign before environment signature verification"

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

cp "$WORKFLOW" "${TEST_DIR}/package-permission-outside-publish.yml"
sed -i '/^[[:space:]]*packages: write$/d' \
  "${TEST_DIR}/package-permission-outside-publish.yml"
sed -i '/name: Application and chart checks/a\    permissions:\n      contents: read\n      packages: write' \
  "${TEST_DIR}/package-permission-outside-publish.yml"
expect_rejected \
  "packages write permission outside the publish job" \
  "${TEST_DIR}/package-permission-outside-publish.yml" \
  "packages: write must be granted exactly once, to the publish job"

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
