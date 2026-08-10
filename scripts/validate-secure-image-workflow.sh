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

[[ -f "$WORKFLOW" ]] || fail "Secure image workflow not found: $WORKFLOW"

grep -Eq '^  pull_request:[[:space:]]*$' "$WORKFLOW" || fail "Pull request checks are required"
grep -Eq '^  push:[[:space:]]*$' "$WORKFLOW" || fail "Push trigger is required for publication"
require_literal "      - main" "Push publication must target main only"
grep -Fq 'pull_request_target:' "$WORKFLOW" && fail "pull_request_target is forbidden for untrusted changes"

while IFS= read -r action; do
  grep -Eq '^[[:space:]]+uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+# v[0-9]' <<< "$action" ||
    fail "GitHub Actions must be pinned to a full commit SHA with a reviewed version comment: $action"
done < <(grep -E '^[[:space:]]+uses:' "$WORKFLOW")

require_literal "  contents: read" "Default repository permissions must remain read-only"
[[ "$(grep -Fc '      packages: write' "$WORKFLOW")" -eq 1 ]] ||
  fail "packages: write must be granted exactly once, to the publish job"
require_literal "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
  "Image publication must be restricted to push events on main"

require_literal "  GO_VERSION: 1.26.5" "Go must be pinned to the reviewed version 1.26.5"
require_literal "  TRIVY_VERSION: v0.73.0" "Trivy must be pinned to the reviewed version v0.73.0"
require_literal "  SYFT_VERSION: v1.50.0" "Syft must be pinned to the reviewed version v1.50.0"
require_literal '          exit-code: "1"' "Trivy findings must fail the workflow"
require_literal "          ignore-unfixed: false" "Unfixed vulnerabilities must not be ignored"
require_literal "          severity: HIGH,CRITICAL" "Trivy must block HIGH and CRITICAL vulnerabilities"
require_literal '          upload-release-assets: false' "SBOM release upload must remain disabled"
# The validator must match the workflow expression literally.
# shellcheck disable=SC2016
require_literal '          echo "ref=ghcr.io/${repository}:sha-${GITHUB_SHA}" >> "$GITHUB_OUTPUT"' \
  "Container images must use the full immutable commit SHA tag"
require_literal '          push: false' "The build job must not publish before security review"
# The validator must match the shell command literally without executing it.
# shellcheck disable=SC2016
require_literal '          push_output="$(docker push "$IMAGE_REF")"' \
  "The isolated publish job must push the reviewed image"

grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' "$WORKFLOW" &&
  fail "Mutable latest image references are forbidden"

scan_line="$(grep -n 'name: Scan image for high and critical vulnerabilities' "$WORKFLOW" | cut -d: -f1)"
export_line="$(grep -n 'name: Export reviewed image' "$WORKFLOW" | cut -d: -f1)"
[[ -n "$scan_line" && -n "$export_line" && "$scan_line" -lt "$export_line" ]] ||
  fail "The image must be scanned before it is exported for publication"

echo "Secure image workflow contract passed"
