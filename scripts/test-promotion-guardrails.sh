#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROMOTER="${SCRIPT_DIR}/promote-image.sh"
TEST_DIR="$(mktemp -d)"
MOCK_RESOLVER="${TEST_DIR}/mock-resolver.sh"
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
GITOPS_ROOT="${TEST_DIR}/positive" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" dev "$COMMIT_A" >/dev/null

GITOPS_ROOT="${TEST_DIR}/positive" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" stage "$COMMIT_A" >/dev/null
  
GITOPS_ROOT="${TEST_DIR}/positive" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" prod "$COMMIT_A" >/dev/null

for environment in dev stage prod; do
  grep -Fq "tag: sha-${COMMIT_A}" "${TEST_DIR}/positive/${environment}/values.yaml"
  grep -Fq "digest: ${DIGEST_A}" "${TEST_DIR}/positive/${environment}/values.yaml"
done

expect_rejected \
  "unknown environment" \
  "Target environment must be dev, stage, or prod" \
  env GITOPS_ROOT="${TEST_DIR}/base" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" qa "$COMMIT_A"

expect_rejected \
  "short commit SHA" \
  "Image commit must be a full lowercase 40-character SHA" \
  env GITOPS_ROOT="${TEST_DIR}/base" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" dev deadbeef

expect_rejected \
  "stage before dev" \
  "stage promotion requires the same image to be present in dev" \
  env GITOPS_ROOT="${TEST_DIR}/base" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" stage "$COMMIT_A"

expect_rejected \
  "prod before stage" \
  "prod promotion requires the same image to be present in stage" \
  env GITOPS_ROOT="${TEST_DIR}/base" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" prod "$COMMIT_A"

expect_rejected \
  "unresolvable image" \
  "Unable to resolve the GHCR digest" \
  env GITOPS_ROOT="${TEST_DIR}/base" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" dev bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

expect_rejected \
  "no-op promotion" \
  "dev already references sha-${COMMIT_A}@${DIGEST_A}" \
  env GITOPS_ROOT="${TEST_DIR}/positive" DIGEST_RESOLVER="$MOCK_RESOLVER" \
  "$PROMOTER" dev "$COMMIT_A"

echo "Promotion guardrail positive and negative tests passed"
