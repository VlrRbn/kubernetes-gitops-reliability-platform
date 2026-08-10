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

echo "Workflow guardrail negative tests passed"
