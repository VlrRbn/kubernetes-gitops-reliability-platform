#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLEANER="${SCRIPT_DIR}/cleanup-kyverno-audit-policies.sh"
TEST_DIR="$(mktemp -d)"
STATE_DIR="${TEST_DIR}/state"
MOCK_KUBECTL="${TEST_DIR}/kubectl"
MOCK_LOG="${TEST_DIR}/kubectl.log"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$STATE_DIR"

cat > "$MOCK_KUBECTL" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
command_name="${1:-}"
resource="${2:-}"
name="${3:-}"
state_file="${MOCK_STATE_DIR:?}/${name}.json"

case "${command_name} ${resource}" in
  "get clusterpolicy")
    [[ "${MOCK_GET_ERROR_POLICY:-}" != "$name" ]] || exit 1
    if [[ -f "$state_file" ]]; then
      command cat "$state_file"
    fi
    ;;
  "delete clusterpolicy")
    [[ -f "$state_file" ]] || exit 1
    command rm -f "$state_file"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_KUBECTL"

write_policy() {
  local name="$1"
  local action="$2"
  printf '%s\n' \
    '{' \
    '  "spec": {' \
    '    "rules": [' \
    "      {\"validate\": {\"failureAction\": \"${action}\"}}" \
    '    ]' \
    '  }' \
    '}' \
    > "${STATE_DIR}/${name}.json"
}

write_verify_policy() {
  local name="$1"
  local action="$2"
  printf '%s\n' \
    '{' \
    '  "spec": {' \
    '    "rules": [' \
    "      {\"verifyImages\": [{\"failureAction\": \"${action}\"}]}" \
    '    ]' \
    '  }' \
    '}' \
    > "${STATE_DIR}/${name}.json"
}

run_cleaner() {
  env KUBECTL_BIN="$MOCK_KUBECTL" MOCK_STATE_DIR="$STATE_DIR" MOCK_LOG="$MOCK_LOG" \
    "$CLEANER" "$@"
}

write_policy temporary-audit Audit
run_cleaner temporary-audit
[[ ! -f "${STATE_DIR}/temporary-audit.json" ]]
grep -Fq 'delete clusterpolicy temporary-audit' "$MOCK_LOG"
echo "PASS: temporary Audit policy was removed"

write_verify_policy temporary-signature-audit Audit
run_cleaner temporary-signature-audit
[[ ! -f "${STATE_DIR}/temporary-signature-audit.json" ]]
echo "PASS: temporary verifyImages Audit policy was removed"

: > "$MOCK_LOG"
write_policy active-enforce Enforce
if run_cleaner active-enforce >"${TEST_DIR}/enforce.out" 2>&1; then
  echo "FAIL: cleanup accepted an Enforce policy" >&2
  exit 1
fi
[[ -f "${STATE_DIR}/active-enforce.json" ]]
if grep -Fq 'delete clusterpolicy active-enforce' "$MOCK_LOG"; then
  echo "FAIL: cleanup deleted an Enforce policy" >&2
  exit 1
fi
grep -Fq 'retaining non-Audit policy' "${TEST_DIR}/enforce.out"
echo "PASS: Enforce policy was retained"

: > "$MOCK_LOG"
write_policy mixed-audit Audit
write_policy mixed-enforce Enforce
if run_cleaner mixed-audit mixed-enforce >/dev/null 2>&1; then
  echo "FAIL: mixed cleanup did not report retained Enforce policy" >&2
  exit 1
fi
[[ ! -f "${STATE_DIR}/mixed-audit.json" ]]
[[ -f "${STATE_DIR}/mixed-enforce.json" ]]
echo "PASS: interrupted partial transition removed only Audit policy"

: > "$MOCK_LOG"
run_cleaner absent-policy
if grep -Fq 'delete clusterpolicy absent-policy' "$MOCK_LOG"; then
  echo "FAIL: cleanup attempted to delete an absent policy" >&2
  exit 1
fi
echo "PASS: absent temporary policy required no cleanup"

: > "$MOCK_LOG"
write_policy inspection-error Audit
if MOCK_GET_ERROR_POLICY=inspection-error run_cleaner inspection-error >/dev/null 2>&1; then
  echo "FAIL: cleanup ignored a policy inspection error" >&2
  exit 1
fi
[[ -f "${STATE_DIR}/inspection-error.json" ]]
if grep -Fq 'delete clusterpolicy inspection-error' "$MOCK_LOG"; then
  echo "FAIL: cleanup deleted a policy with unknown state" >&2
  exit 1
fi
echo "PASS: inspection error retained the unknown policy state"

echo "Kyverno bootstrap cleanup lifecycle tests passed"
