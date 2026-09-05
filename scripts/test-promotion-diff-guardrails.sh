#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-promotion-diff.sh"
TEST_DIR="$(mktemp -d)"
BASE_ROOT="${TEST_DIR}/base"
HEAD_ROOT="${TEST_DIR}/head"
MOCK_GIT="${TEST_DIR}/git"
BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
DIGEST_A="sha256:1111111111111111111111111111111111111111111111111111111111111111"
DIGEST_B="sha256:2222222222222222222222222222222222222222222222222222222222222222"
COMMIT_A="1111111111111111111111111111111111111111"
COMMIT_B="2222222222222222222222222222222222222222"
trap 'rm -rf "$TEST_DIR"' EXIT

write_values() {
  local root="$1"
  local environment="$2"
  local commit="$3"
  local digest="$4"

  mkdir -p "${root}/${environment}"
  printf '%s\n' \
    'replicaCount: 2' \
    '' \
    'image:' \
    "  repository: ${REPOSITORY}" \
    "  tag: sha-${commit}" \
    "  digest: ${digest}" \
    '  pullPolicy: IfNotPresent' \
    > "${root}/${environment}/values.yaml"
}

reset_case() {
  rm -rf "$BASE_ROOT" "$HEAD_ROOT"
  for environment in dev stage prod; do
    write_values "$BASE_ROOT" "$environment" "$COMMIT_A" "$DIGEST_A"
    write_values "$HEAD_ROOT" "$environment" "$COMMIT_A" "$DIGEST_A"
  done
}

cat > "$MOCK_GIT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  cat-file)
    [[ "${3:-}" == "${MOCK_BASE_SHA}^{commit}" || "${3:-}" == "${MOCK_HEAD_SHA}^{commit}" ]]
    ;;
  diff)
    printf '%s' "${MOCK_DIFF:-}"
    exit "${MOCK_DIFF_STATUS:-0}"
    ;;
  show)
    reference="${2:-}"
    sha="${reference%%:*}"
    path="${reference#*:gitops/environments/}"
    if [[ "$sha" == "$MOCK_BASE_SHA" ]]; then
      root="$MOCK_BASE_ROOT"
    elif [[ "$sha" == "$MOCK_HEAD_SHA" ]]; then
      root="$MOCK_HEAD_ROOT"
    else
      exit 1
    fi
    command cat "${root}/${path}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_GIT"

run_validator() {
  env \
    EVENT_NAME=pull_request \
    BASE_SHA="$BASE_SHA" \
    HEAD_SHA="$HEAD_SHA" \
    PROMOTION_GIT_BIN="$MOCK_GIT" \
    MOCK_BASE_SHA="$BASE_SHA" \
    MOCK_HEAD_SHA="$HEAD_SHA" \
    MOCK_BASE_ROOT="$BASE_ROOT" \
    MOCK_HEAD_ROOT="$HEAD_ROOT" \
    MOCK_DIFF="${MOCK_DIFF:-}" \
    MOCK_DIFF_STATUS="${MOCK_DIFF_STATUS:-0}" \
    "$VALIDATOR"
}

expect_rejected() {
  local name="$1"
  local reason="$2"
  local output

  echo "Testing negative promotion diff case: $name"
  if output="$(run_validator 2>&1)"; then
    echo "FAIL: promotion diff validator accepted: $name" >&2
    exit 1
  fi
  grep -Fq -- "$reason" <<< "$output" || {
    echo "FAIL: promotion diff validator rejected '$name' for the wrong reason" >&2
    echo "$output" >&2
    exit 1
  }
  echo "PASS: $name"
}

reset_case
MOCK_DIFF=""
run_validator >/dev/null
echo "PASS: pull request without environment changes"

reset_case
write_values "$HEAD_ROOT" dev "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/dev/values.yaml\n'
run_validator >/dev/null
echo "PASS: ordered dev promotion"

reset_case
write_values "$HEAD_ROOT" dev "$COMMIT_B" "$DIGEST_B"
write_values "$HEAD_ROOT" stage "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/stage/values.yaml\n'
run_validator >/dev/null
echo "PASS: ordered stage promotion"

reset_case
write_values "$HEAD_ROOT" stage "$COMMIT_B" "$DIGEST_B"
write_values "$HEAD_ROOT" prod "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/prod/values.yaml\n'
run_validator >/dev/null
echo "PASS: ordered prod promotion"

reset_case
write_values "$HEAD_ROOT" stage "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/stage/values.yaml\n'
expect_rejected "stage before dev" "stage promotion requires the same image to be present in dev"

reset_case
write_values "$HEAD_ROOT" prod "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/prod/values.yaml\n'
expect_rejected "prod before stage" "prod promotion requires the same image to be present in stage"

reset_case
write_values "$HEAD_ROOT" dev "$COMMIT_B" "$DIGEST_B"
write_values "$HEAD_ROOT" stage "$COMMIT_B" "$DIGEST_B"
MOCK_DIFF=$'M\tgitops/environments/dev/values.yaml\nM\tgitops/environments/stage/values.yaml\n'
expect_rejected "two environments in one pull request" "A pull request may promote exactly one environment"

reset_case
write_values "$HEAD_ROOT" dev "$COMMIT_B" "$DIGEST_B"
sed -i 's/replicaCount: 2/replicaCount: 3/' "$HEAD_ROOT/dev/values.yaml"
MOCK_DIFF=$'M\tgitops/environments/dev/values.yaml\n'
expect_rejected "non-image change in promotion values" "Promotion PR may change only image repository, tag, and digest"

reset_case
MOCK_DIFF=$'D\tgitops/environments/prod/values.yaml\n'
expect_rejected "deleted environment values" "Promotion PR may only modify an existing environment values file"

reset_case
MOCK_DIFF=""
MOCK_DIFF_STATUS=1
expect_rejected "unavailable pull request diff" "Unable to compare pull request environment changes"
MOCK_DIFF_STATUS=0

reset_case
EVENT_NAME=push BASE_SHA="" HEAD_SHA="" PROMOTION_GIT_BIN="$MOCK_GIT" "$VALIDATOR" >/dev/null
echo "PASS: non-pull-request event does not require a base revision"

echo "Promotion diff positive and negative tests passed"
