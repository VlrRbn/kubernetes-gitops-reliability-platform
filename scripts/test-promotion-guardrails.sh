#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROMOTER="${SCRIPT_DIR}/promote-image.sh"
TEST_DIR="$(mktemp -d)"
MOCK_RESOLVER="${TEST_DIR}/mock-resolver.sh"
MOCK_SIGNATURE_VERIFIER="${TEST_DIR}/mock-signature-verifier.sh"
SIGNATURE_LOG="${TEST_DIR}/signature.log"
COMMIT_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DIGEST_A="sha256:1111111111111111111111111111111111111111111111111111111111111111"
trap 'rm -rf "$TEST_DIR"' EXIT

cp -R "${ROOT_DIR}/gitops/environments" "${TEST_DIR}/base"

cat > "$MOCK_RESOLVER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${2:-}" in
  sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
    echo "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_RESOLVER"

cat > "$MOCK_SIGNATURE_VERIFIER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s@%s\n' "${1:-}" "${2:-}" >> "${MOCK_SIGNATURE_LOG:?}"
case "${MOCK_SIGNATURE_MODE:-trusted}" in
  trusted)
    ;;
  unsigned)
    echo "no signatures found" >&2
    exit 1
    ;;
  wrong_identity)
    echo "subject mismatch" >&2
    exit 1
    ;;
  wrong_issuer)
    echo "issuer mismatch" >&2
    exit 1
    ;;
  registry_error)
    echo "registry lookup failed" >&2
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$MOCK_SIGNATURE_VERIFIER"

expect_rejected() {
  local name="$1"
  local expected_reason="$2"
  shift 2
  local output

  echo "Testing negative promotion case: $name"
  if output="$("$@" 2>&1)"; then
    echo "FAIL: promoter accepted negative case: $name" >&2
    exit 1
  fi
  echo "$output"
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: promoter rejected '$name' for the wrong reason" >&2
    echo "Expected: $expected_reason" >&2
    exit 1
  }
  echo "PASS: $name"
}

cp -R "${TEST_DIR}/base" "${TEST_DIR}/positive"
MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/positive" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" dev "$COMMIT_A" >/dev/null

MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/positive" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" stage "$COMMIT_A" >/dev/null

MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/positive" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" prod "$COMMIT_A" >/dev/null

for environment in dev stage prod; do
  grep -Fq "tag: sha-${COMMIT_A}" "${TEST_DIR}/positive/${environment}/values.yaml"
  grep -Fq "digest: ${DIGEST_A}" "${TEST_DIR}/positive/${environment}/values.yaml"
done
[[ "$(grep -Fxc -- "ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@${DIGEST_A}" "$SIGNATURE_LOG")" -eq 3 ]]
echo "PASS: trusted signed digest preserved dev to stage to prod order"

expect_signature_rejected_unchanged() {
  local name="$1"
  local mode="$2"
  local expected_reason="$3"
  local case_root="${TEST_DIR}/${mode}-${RANDOM}"
  local before="${TEST_DIR}/${mode}-${RANDOM}.before"

  cp -R "${TEST_DIR}/base" "$case_root"
  cp "${case_root}/dev/values.yaml" "$before"

  expect_rejected \
    "$name" \
    "$expected_reason" \
    env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" MOCK_SIGNATURE_MODE="$mode" \
    GITOPS_ROOT="$case_root" DIGEST_RESOLVER="$MOCK_RESOLVER" \
    SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
    "$PROMOTER" dev "$COMMIT_A"

  cmp --silent "$before" "${case_root}/dev/values.yaml" || {
    echo "FAIL: failed signature verification changed dev values for: $name" >&2
    exit 1
  }
  echo "PASS: failed verification left target values byte-for-byte unchanged"
}

expect_signature_rejected_unchanged \
  "tag and digest match but signature is absent" \
  unsigned \
  "no signatures found"

expect_signature_rejected_unchanged \
  "wrong workflow identity" \
  wrong_identity \
  "subject mismatch"

expect_signature_rejected_unchanged \
  "wrong OIDC issuer" \
  wrong_issuer \
  "issuer mismatch"

expect_signature_rejected_unchanged \
  "unverifiable digest fails closed" \
  registry_error \
  "registry lookup failed"

expect_rejected \
  "unknown environment" \
  "Target environment must be dev, stage, or prod" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/base" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" qa "$COMMIT_A"

expect_rejected \
  "short commit SHA" \
  "Image commit must be a full lowercase 40-character SHA" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/base" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" dev deadbeef

expect_rejected \
  "stage before dev" \
  "stage promotion requires the same image to be present in dev" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/base" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" stage "$COMMIT_A"

expect_rejected \
  "prod before stage" \
  "prod promotion requires the same image to be present in stage" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/base" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" prod "$COMMIT_A"

expect_rejected \
  "unresolvable image" \
  "Unable to resolve the GHCR digest" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/base" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" dev bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

expect_rejected \
  "no-op promotion" \
  "dev already references sha-${COMMIT_A}@${DIGEST_A}" \
  env MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" GITOPS_ROOT="${TEST_DIR}/positive" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$PROMOTER" dev "$COMMIT_A"

echo "Promotion guardrail positive and negative tests passed"
