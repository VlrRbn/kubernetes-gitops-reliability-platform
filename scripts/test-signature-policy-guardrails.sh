#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-signature-policy.sh"
POLICY="${ROOT_DIR}/platform/kyverno/policies/verify-signed-images.yaml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_rejected() {
  local name="$1"
  local candidate="$2"
  local expected_reason="$3"
  local output

  echo "Testing negative signature policy case: $name"
  if output="$("$VALIDATOR" "$candidate" 2>&1)"; then
    echo "FAIL: validator accepted negative case: $name" >&2
    exit 1
  fi
  printf '%s\n' "$output"
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: validator rejected '$name' for the wrong reason" >&2
    echo "Expected: $expected_reason" >&2
    exit 1
  }
  echo "PASS: $name"
}

"$VALIDATOR" "$POLICY"

cp "$POLICY" "$TEST_DIR/fail-open-webhook.yaml"
sed -i 's/failurePolicy: Fail/failurePolicy: Ignore/' "$TEST_DIR/fail-open-webhook.yaml"
expect_rejected "fail-open webhook" "$TEST_DIR/fail-open-webhook.yaml" \
  "Signature verifier errors must fail closed"

cp "$POLICY" "$TEST_DIR/audit-only.yaml"
sed -i 's/failureAction: Enforce/failureAction: Audit/' "$TEST_DIR/audit-only.yaml"
expect_rejected "audit-only signature policy" "$TEST_DIR/audit-only.yaml" \
  "Signature verification must be enforced"

cp "$POLICY" "$TEST_DIR/optional-signature.yaml"
sed -i 's/required: true/required: false/' "$TEST_DIR/optional-signature.yaml"
expect_rejected "optional signature" "$TEST_DIR/optional-signature.yaml" \
  "Every matching image must be verified"

cp "$POLICY" "$TEST_DIR/mutated-digest.yaml"
sed -i 's/mutateDigest: false/mutateDigest: true/' "$TEST_DIR/mutated-digest.yaml"
expect_rejected "admission-mutated digest" "$TEST_DIR/mutated-digest.yaml" \
  "Admission must not replace the reviewed GitOps digest"

cp "$POLICY" "$TEST_DIR/narrow-image-scope.yaml"
sed -i 's/            - "\*"/            - "ghcr.io\/vlrrbn\/kubernetes-gitops-reliability-platform*"/' \
  "$TEST_DIR/narrow-image-scope.yaml"
expect_rejected "images outside the project bypassing verification" \
  "$TEST_DIR/narrow-image-scope.yaml" \
  "All workload images must require a trusted signature"

cp "$POLICY" "$TEST_DIR/wildcard-subject.yaml"
sed -i 's|subject: https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main|subject: "*"|' \
  "$TEST_DIR/wildcard-subject.yaml"
expect_rejected "wildcard signer subject" "$TEST_DIR/wildcard-subject.yaml" \
  "Signer subject must be restricted to secure-image.yml on main"

cp "$POLICY" "$TEST_DIR/wildcard-issuer.yaml"
sed -i 's|issuer: https://token.actions.githubusercontent.com|issuer: "*"|' \
  "$TEST_DIR/wildcard-issuer.yaml"
expect_rejected "wildcard signer issuer" "$TEST_DIR/wildcard-issuer.yaml" \
  "Signer issuer must be restricted to GitHub Actions OIDC"

cp "$POLICY" "$TEST_DIR/skipped-images.yaml"
sed -i '/imageReferences:/i\          skipImageReferences:\n            - "ghcr.io/example/**"' \
  "$TEST_DIR/skipped-images.yaml"
expect_rejected "signature verification exclusion" "$TEST_DIR/skipped-images.yaml" \
  "Signature verification exclusions are forbidden"

echo "Signature policy guardrail tests passed"
