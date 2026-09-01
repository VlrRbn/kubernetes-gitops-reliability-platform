#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/verify-image-signature.sh"
TEST_DIR="$(mktemp -d)"
MOCK_COSIGN="${TEST_DIR}/cosign"
CALL_LOG="${TEST_DIR}/cosign-call.log"
REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
TRUSTED_IDENTITY="https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main"
TRUSTED_ISSUER="https://token.actions.githubusercontent.com"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$MOCK_COSIGN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "version" ]]; then
  printf 'GitVersion:    %s\n' "${MOCK_COSIGN_VERSION:-v2.6.5}"
  exit 0
fi

[[ "${1:-}" == "verify" ]] || exit 2
printf '%s\n' "$@" > "${MOCK_COSIGN_CALL_LOG:?}"

case "${MOCK_VERIFY_MODE:-trusted}" in
  trusted)
    printf '[{"critical":{"type":"https://sigstore.dev/cosign/sign/v1"}}]\n'
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
  empty)
    echo '[]'
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$MOCK_COSIGN"

expect_rejected() {
  local name="$1"
  local expected_reason="$2"
  shift 2
  local output

  echo "Testing negative signature case: $name"
  if output="$("$@" 2>&1)"; then
    echo "FAIL: signature verifier accepted negative case: $name" >&2
    exit 1
  fi
  echo "$output"
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: signature verifier rejected '$name' for the wrong reason" >&2
    echo "Expected: $expected_reason" >&2
    exit 1
  }
  echo "PASS: $name"
}

echo "Testing positive signature case: trusted signed digest"
COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" \
  "$VERIFIER" "$REPOSITORY" "$DIGEST" >/dev/null
grep -Fxq -- "--certificate-identity" "$CALL_LOG"
grep -Fxq -- "$TRUSTED_IDENTITY" "$CALL_LOG"
grep -Fxq -- "--certificate-oidc-issuer" "$CALL_LOG"
grep -Fxq -- "$TRUSTED_ISSUER" "$CALL_LOG"
grep -Fxq -- "${REPOSITORY}@${DIGEST}" "$CALL_LOG"
echo "PASS: trusted signed digest"

expect_rejected \
  "unsigned digest" \
  "no signatures found" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" MOCK_VERIFY_MODE=unsigned \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

expect_rejected \
  "wrong workflow identity" \
  "subject mismatch" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" MOCK_VERIFY_MODE=wrong_identity \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

expect_rejected \
  "wrong OIDC issuer" \
  "issuer mismatch" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" MOCK_VERIFY_MODE=wrong_issuer \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

expect_rejected \
  "registry verifier error" \
  "registry lookup failed" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" MOCK_VERIFY_MODE=registry_error \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

expect_rejected \
  "empty Cosign verification result" \
  "Cosign returned no trusted signatures" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_CALL_LOG="$CALL_LOG" MOCK_VERIFY_MODE=empty \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

expect_rejected \
  "unreviewed host Cosign version" \
  "Cosign verifier must be the reviewed version v2.6.5" \
  env COSIGN_BIN="$MOCK_COSIGN" MOCK_COSIGN_VERSION=v3.1.3 \
  "$VERIFIER" "$REPOSITORY" "$DIGEST"

echo "Image signature verifier positive and negative tests passed"
