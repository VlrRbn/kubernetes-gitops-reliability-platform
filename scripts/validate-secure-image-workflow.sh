#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${1:-${ROOT_DIR}/.github/workflows/secure-image.yml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_literal() {
  local value="$1"
  local reason="$2"
  grep -Fq -- "$value" "$WORKFLOW" || fail "$reason"
}

step_block() {
  local step_name="$1"
  awk -v marker="      - name: ${step_name}" '
    $0 == marker { in_step = 1 }
    in_step && $0 != marker && /^      - name:/ { exit }
    in_step { print }
  ' "$WORKFLOW"
}

require_blocking_security_step() {
  local step_name="$1"
  local failure_reason="$2"
  local block

  block="$(step_block "$step_name")"
  [[ -n "$block" ]] || fail "Security-critical workflow step is missing: $step_name"
  if grep -Eq '^[[:space:]]+continue-on-error:[[:space:]]*true[[:space:]]*$' <<< "$block"; then
    fail "$failure_reason"
  fi
  if grep -Eq '^[[:space:]]+if:' <<< "$block"; then
    fail "Security-critical workflow steps must not be disabled or conditionally skipped: $step_name"
  fi
}

[[ -f "$WORKFLOW" ]] || fail "Secure image workflow not found: $WORKFLOW"

grep -Eq '^  pull_request:[[:space:]]*$' "$WORKFLOW" || fail "Pull request checks are required"
grep -Eq '^  push:[[:space:]]*$' "$WORKFLOW" || fail "Push trigger is required for publication"
grep -Eq '^  schedule:[[:space:]]*$' "$WORKFLOW" || fail "Scheduled vulnerability scans are required"
require_literal '    - cron: "0 6 * * *"' "Scheduled vulnerability scans must run daily at 06:00 UTC"
grep -Eq '^  workflow_dispatch:[[:space:]]*$' "$WORKFLOW" || fail "Manual vulnerability scans are required"
require_literal "      - main" "Push publication must target main only"
grep -Fq 'pull_request_target:' "$WORKFLOW" && fail "pull_request_target is forbidden for untrusted changes"

# The validator must match the GitHub Actions expressions literally.
# shellcheck disable=SC2016
require_literal '  group: secure-image-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}' \
  "Scheduled scans must not cancel pull request or publication workflows"
# Only superseded pull request checks may be cancelled. A trusted main
# publication must complete once it has started.
require_literal "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
  "Trusted main publication must not be cancellable"

while IFS= read -r action; do
  grep -Eq '^[[:space:]]+uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+# v[0-9]' <<< "$action" ||
    fail "GitHub Actions must be pinned to a full commit SHA with a reviewed version comment: $action"
done < <(grep -E '^[[:space:]]+uses:' "$WORKFLOW")

require_literal "  contents: read" "Default repository permissions must remain read-only"
[[ "$(grep -Fc '      packages: write' "$WORKFLOW")" -eq 1 ]] ||
  fail "packages: write must be granted exactly once, to the publish job"
publish_block="$(sed -n '/^  publish:$/,$p' "$WORKFLOW")"
if [[ "$(grep -Fc '      id-token: write' <<< "$publish_block")" -ne 1 ]] ||
  [[ "$(grep -Fc '      id-token: write' "$WORKFLOW")" -ne 1 ]]; then
  fail "id-token: write must be granted exactly once, to the trusted publish job"
fi
require_literal "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
  "Image publication must be restricted to push events on main"

require_literal "  GO_VERSION: 1.26.6" "Go must be pinned to the reviewed version 1.26.6"
require_literal "  TRIVY_VERSION: v0.73.0" "Trivy must be pinned to the reviewed version v0.73.0"
require_literal "  SYFT_VERSION: v1.50.0" "Syft must be pinned to the reviewed version v1.50.0"
require_literal "  COSIGN_VERSION: v2.6.5" "Cosign must be pinned to the reviewed Kyverno-compatible version v2.6.5"
require_blocking_security_step \
  "Scan image for high and critical vulnerabilities" \
  "Trivy scan failures must block the workflow"
require_blocking_security_step \
  "Sign published image identity" \
  "Cosign signing failures must block the workflow"
require_blocking_security_step \
  "Verify published image signature" \
  "Signature verification failures must block the workflow"
require_literal '          exit-code: "1"' "Trivy findings must fail the workflow"
require_literal "          ignore-unfixed: false" "Unfixed vulnerabilities must not be ignored"
require_literal "          severity: HIGH,CRITICAL" "Trivy must block HIGH and CRITICAL vulnerabilities"
require_literal '          upload-release-assets: false' "SBOM release upload must remain disabled"
# The validator must match the workflow expression literally.
# shellcheck disable=SC2016
require_literal '          echo "ref=ghcr.io/${repository}:sha-${GITHUB_SHA}" >> "$GITHUB_OUTPUT"' \
  "Container images must use the full immutable commit SHA tag"
require_literal '          push: false' "The build job must not publish before security review"
# The validator must match the GitHub Actions expression literally.
# shellcheck disable=SC2016
require_literal '            VERSION=sha-${{ github.sha }}' \
  "Image version metadata must use the full commit SHA"
# The validator must match the shell command literally without executing it.
# shellcheck disable=SC2016
require_literal '          push_output="$(docker push "$IMAGE_REF")"' \
  "The isolated publish job must push the reviewed image"
# The validator must match workflow and shell expressions literally.
# shellcheck disable=SC2016
require_literal '        run: cosign sign --yes "${IMAGE_REPOSITORY,,}@${IMAGE_DIGEST}"' \
  "Cosign must sign the exact published digest"
# shellcheck disable=SC2016
require_literal '            --certificate-identity "$CERTIFICATE_IDENTITY"' \
  "Cosign verification must require the expected workflow identity"
# shellcheck disable=SC2016
require_literal '            --certificate-oidc-issuer "$CERTIFICATE_OIDC_ISSUER"' \
  "Cosign verification must require the GitHub OIDC issuer"
# shellcheck disable=SC2016
require_literal '          CERTIFICATE_IDENTITY: https://github.com/${{ github.repository }}/.github/workflows/secure-image.yml@refs/heads/main' \
  "The signer identity must be restricted to secure-image.yml on main"
require_literal '          CERTIFICATE_OIDC_ISSUER: https://token.actions.githubusercontent.com' \
  "The signer issuer must be restricted to GitHub Actions OIDC"
require_literal "      - name: Verify immutable environment images" \
  "CI must verify every environment image against GHCR and its trusted signature"
require_literal "        run: ./scripts/verify-environment-images.sh" \
  "CI must run signed environment image verification"
require_literal "      - name: Install Cosign for environment verification" \
  "CI must install reviewed Cosign before environment signature verification"
# The validator must match the GitHub Actions expression literally.
# shellcheck disable=SC2016
[[ "$(grep -Fc '          cosign-release: ${{ env.COSIGN_VERSION }}' "$WORKFLOW")" -eq 2 ]] ||
  fail "Both environment verification and publication must use the reviewed Cosign release"

grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' "$WORKFLOW" &&
  fail "Mutable latest image references are forbidden"

scan_line="$(grep -n 'name: Scan image for high and critical vulnerabilities' "$WORKFLOW" | cut -d: -f1)"
export_line="$(grep -n 'name: Export reviewed image' "$WORKFLOW" | cut -d: -f1)"
[[ -n "$scan_line" && -n "$export_line" && "$scan_line" -lt "$export_line" ]] ||
  fail "The image must be scanned before it is exported for publication"

echo "Secure image workflow contract passed"
