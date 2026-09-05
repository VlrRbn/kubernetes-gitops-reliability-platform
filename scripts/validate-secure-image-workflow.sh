#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW="${1:-${ROOT_DIR}/.github/workflows/secure-image.yml}"
STRUCTURE_DIR="$(mktemp -d)"
STRUCTURE_JSON="${STRUCTURE_DIR}/workflow.json"

trap 'rm -rf "$STRUCTURE_DIR"' EXIT

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

job_block() {
  local job_name="$1"
  awk -v marker="  ${job_name}:" '
    $0 == marker { in_job = 1 }
    in_job && $0 != marker && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job { print }
  ' "$WORKFLOW"
}

validate_permission_structure() {
  for command in helm python3; do
    command -v "$command" >/dev/null 2>&1 ||
      fail "${command} is required for structural workflow permission validation"
  done

  mkdir -p "${STRUCTURE_DIR}/files" "${STRUCTURE_DIR}/templates"
  printf '%s\n' \
    'apiVersion: v2' \
    'name: secure-image-workflow-validator' \
    'version: 0.1.0' \
    > "${STRUCTURE_DIR}/Chart.yaml"
  cp "$WORKFLOW" "${STRUCTURE_DIR}/files/workflow.yml"
  # These are literal Helm template expressions, not shell expansions.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '{{- .Files.Get "files/workflow.yml" | fromYaml | toJson }}' \
    > "${STRUCTURE_DIR}/templates/workflow.yaml"

  if ! helm template secure-image-workflow-validator "$STRUCTURE_DIR" > "$STRUCTURE_JSON"; then
    fail "Secure image workflow YAML could not be parsed structurally"
  fi

  python3 - "$STRUCTURE_JSON" <<'PYTHON'
import json
import sys


def fail(reason):
    print(f"FAIL: {reason}", file=sys.stderr)
    raise SystemExit(1)


workflow = None
with open(sys.argv[1], encoding="utf-8") as rendered:
    for line in rendered:
        line = line.strip()
        if line.startswith("{"):
            workflow = json.loads(line)
            break

if not isinstance(workflow, dict) or "Error" in workflow:
    fail("Secure image workflow YAML could not be parsed structurally")

permissions = workflow.get("permissions")
if permissions == "write-all":
    fail("permissions: write-all is forbidden at every workflow scope")
if permissions == "read-all":
    fail("permissions: read-all is forbidden; permissions must be explicit")

jobs = workflow.get("jobs")
if not isinstance(jobs, dict) or set(jobs) != {"checks", "image", "publish"}:
    fail("Workflow must contain exactly the reviewed checks, image, and publish jobs")

checks = jobs.get("checks")
image = jobs.get("image")
publish = jobs.get("publish")
if not all(isinstance(job, dict) for job in (checks, image, publish)):
    fail("Workflow jobs must use reviewed mapping definitions")

checks_permissions = checks.get("permissions")
image_permissions = image.get("permissions")
publish_permissions = publish.get("permissions")
for job_permissions in (checks_permissions, image_permissions, publish_permissions):
    if job_permissions == "write-all":
        fail("permissions: write-all is forbidden at every workflow scope")
    if job_permissions == "read-all":
        fail("permissions: read-all is forbidden; permissions must be explicit")

permission_maps = [
    value
    for value in (permissions, checks_permissions, image_permissions, publish_permissions)
    if isinstance(value, dict)
]
if (
    sum(mapping.get("id-token") == "write" for mapping in permission_maps) != 1
    or not isinstance(publish_permissions, dict)
    or publish_permissions.get("id-token") != "write"
):
    fail("id-token: write must be granted exactly once, to the trusted publish job")
if (
    sum(mapping.get("packages") == "write" for mapping in permission_maps) != 1
    or not isinstance(publish_permissions, dict)
    or publish_permissions.get("packages") != "write"
):
    fail("packages: write must be granted exactly once, to the publish job")

if permissions != {"contents": "read"}:
    fail("Top-level permissions must contain only contents: read")
if "permissions" in checks:
    fail("Checks job must inherit the top-level read-only permissions")
if image_permissions != {"contents": "read"}:
    fail("Image job permissions must contain only contents: read")
if publish_permissions != {
    "contents": "read",
    "id-token": "write",
    "packages": "write",
}:
    fail(
        "Publish job permissions must contain exactly contents: read, "
        "id-token: write, and packages: write"
    )
PYTHON
}

require_blocking_security_step() {
  local step_name="$1"
  local failure_reason="$2"
  local block

  block="$(step_block "$step_name")"
  [[ -n "$block" ]] || fail "Security-critical workflow step is missing: $step_name"
  if grep -Eq '^[[:space:]]+continue-on-error:' <<< "$block"; then
    fail "$failure_reason"
  fi
  if grep -Eq '^[[:space:]]+if:' <<< "$block"; then
    fail "Security-critical workflow steps must not be disabled or conditionally skipped: $step_name"
  fi
}

require_blocking_job() {
  local job_name="$1"
  local block

  block="$(job_block "$job_name")"
  [[ -n "$block" ]] || fail "Required workflow job is missing: $job_name"
  if grep -Eq '^    continue-on-error:' <<< "$block"; then
    fail "${job_name^} job failures must block the workflow"
  fi
}

[[ -f "$WORKFLOW" ]] || fail "Secure image workflow not found: $WORKFLOW"
validate_permission_structure

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
require_blocking_job "image"
require_blocking_job "publish"
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
require_literal "          fetch-depth: 0" \
  "Pull request checks must fetch the reviewed base commit"
require_literal "      - name: Validate ordered environment promotion" \
  "CI must enforce ordered environment promotion"
# The validator must match GitHub Actions expressions literally.
# shellcheck disable=SC2016
require_literal '          EVENT_NAME: ${{ github.event_name }}' \
  "Promotion validation must distinguish pull request events"
# shellcheck disable=SC2016
require_literal '          BASE_SHA: ${{ github.event.pull_request.base.sha }}' \
  "Promotion validation must use the reviewed pull request base SHA"
# shellcheck disable=SC2016
require_literal '          HEAD_SHA: ${{ github.sha }}' \
  "Promotion validation must use the checked pull request revision"
require_literal "        run: ./scripts/validate-promotion-diff.sh" \
  "CI must run the promotion diff validator"
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
