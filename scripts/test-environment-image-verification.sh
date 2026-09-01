#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/verify-environment-images.sh"
TEST_DIR="$(mktemp -d)"
GITOPS_ROOT="${TEST_DIR}/environments"
MOCK_RESOLVER="${TEST_DIR}/mock-resolver.sh"
MOCK_SIGNATURE_VERIFIER="${TEST_DIR}/mock-signature-verifier.sh"
SIGNATURE_LOG="${TEST_DIR}/signature.log"
COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
trap 'rm -rf "$TEST_DIR"' EXIT

for environment in dev stage prod; do
  mkdir -p "${GITOPS_ROOT}/${environment}"
  {
    echo "image:"
    echo "  repository: ${REPOSITORY}"
    echo "  tag: sha-${COMMIT}"
    echo "  digest: ${DIGEST}"
  } > "${GITOPS_ROOT}/${environment}/values.yaml"
done

cat > "$MOCK_RESOLVER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${1:-}" == "${REPOSITORY}" ]]
[[ "\${2:-}" == "sha-${COMMIT}" ]]
echo "${DIGEST}"
EOF

cat > "$MOCK_SIGNATURE_VERIFIER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s@%s\n' "${1:-}" "${2:-}" >> "${MOCK_SIGNATURE_LOG:?}"
if [[ "${MOCK_SIGNATURE_MODE:-trusted}" == "unsigned" ]]; then
  echo "no signatures found" >&2
  exit 1
fi
EOF
chmod +x "$MOCK_RESOLVER" "$MOCK_SIGNATURE_VERIFIER"

echo "Testing positive environment case: all configured digests are signed"
MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" \
  GITOPS_ROOT="$GITOPS_ROOT" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" \
  SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$VERIFIER" >/dev/null
[[ "$(wc -l < "$SIGNATURE_LOG")" -eq 3 ]]
[[ "$(grep -Fxc -- "${REPOSITORY}@${DIGEST}" "$SIGNATURE_LOG")" -eq 3 ]]
echo "PASS: dev, stage, and prod signatures verified"

echo "Testing negative environment case: matching tag and digest without signature"
if MOCK_SIGNATURE_LOG="$SIGNATURE_LOG" \
  MOCK_SIGNATURE_MODE=unsigned \
  GITOPS_ROOT="$GITOPS_ROOT" \
  DIGEST_RESOLVER="$MOCK_RESOLVER" \
  SIGNATURE_VERIFIER="$MOCK_SIGNATURE_VERIFIER" \
  "$VERIFIER" >"${TEST_DIR}/unsigned.out" 2>&1; then
  echo "FAIL: environment verifier accepted an unsigned digest" >&2
  exit 1
fi
grep -Fq "no signatures found" "${TEST_DIR}/unsigned.out"
grep -Fq "Trusted signature verification failed for dev" "${TEST_DIR}/unsigned.out"
echo "PASS: matching tag and digest without signature was rejected"

echo "Environment image signature verification tests passed"
