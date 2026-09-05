#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-admission-policy-boundaries.sh"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap-kyverno.sh"
POLICY_DIR="${ROOT_DIR}/platform/kyverno/policies"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_rejected() {
  local name="$1"
  local candidate="$2"
  local expected_reason="$3"
  local output

  echo "Testing negative admission policy case: $name"
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

fresh_scope() {
  local name="$1"
  local candidate="${TEST_DIR}/${name}"

  mkdir -p "$candidate"
  cp "${POLICY_DIR}"/*.yaml "$candidate/"
  printf '%s\n' "$candidate"
}

echo "Testing positive admission policy boundary cases"
"$VALIDATOR" "$POLICY_DIR"
for policy in \
  require-immutable-images \
  require-restricted-workloads \
  verify-signed-images; do
  "$VALIDATOR" "${POLICY_DIR}/${policy}.yaml"
  echo "PASS: ${policy} preserves reviewed fail-closed boundaries"
done

for policy in \
  require-immutable-images \
  require-restricted-workloads \
  verify-signed-images; do
  candidate="$(fresh_scope "background-disabled-${policy}")"
  sed -i 's/background: true/background: false/' "${candidate}/${policy}.yaml"
  expect_rejected \
    "background coverage disabled for ${policy}" \
    "$candidate" \
    "${policy} background coverage must remain enabled"

  candidate="$(fresh_scope "fail-open-webhook-${policy}")"
  sed -i 's/failurePolicy: Fail/failurePolicy: Ignore/' "${candidate}/${policy}.yaml"
  if [[ "$policy" == verify-signed-images ]]; then
    reason="Signature verifier errors must fail closed"
  else
    reason="${policy} webhook errors must fail closed"
  fi
  expect_rejected \
    "fail-open webhook for ${policy}" \
    "$candidate" \
    "$reason"

  candidate="$(fresh_scope "audit-only-${policy}")"
  sed -i '0,/failureAction: Enforce/s//failureAction: Audit/' "${candidate}/${policy}.yaml"
  if [[ "$policy" == verify-signed-images ]]; then
    reason="Signature verification must be enforced"
  else
    first_rule="$(awk '$1 == "-" && $2 == "name:" {print $3; exit}' "${candidate}/${policy}.yaml")"
    reason="${policy}/${first_rule} must enforce validation failures"
  fi
  expect_rejected \
    "audit-only enforcement for ${policy}" \
    "$candidate" \
    "$reason"

  candidate="$(fresh_scope "autogen-disabled-${policy}")"
  sed -i '/^  annotations:$/a\    pod-policies.kyverno.io/autogen-controllers: none' \
    "${candidate}/${policy}.yaml"
  expect_rejected \
    "autogen disabled for ${policy}" \
    "$candidate" \
    "${policy} must not disable Kyverno autogen coverage"
done

candidate="$(fresh_scope exclude-any-prod)"
sed -i '/    - name: require-trusted-main-signature/a\      exclude:\n        any:\n          - resources:\n              namespaces:\n                - prod' \
  "${candidate}/verify-signed-images.yaml"
expect_rejected \
  "exclude.any bypass for prod" \
  "$candidate" \
  "Rule-level exclusions are forbidden for managed admission policies"

candidate="$(fresh_scope exclude-all-stage)"
sed -i '/    - name: require-sha256-digest/a\      exclude:\n        all:\n          - resources:\n              namespaces:\n                - stage' \
  "${candidate}/require-immutable-images.yaml"
expect_rejected \
  "exclude.all bypass for stage" \
  "$candidate" \
  "Rule-level exclusions are forbidden for managed admission policies"

candidate="$(fresh_scope apply-one-rule)"
sed -i '/^  background: true$/a\  applyRules: One' \
  "${candidate}/require-restricted-workloads.yaml"
expect_rejected \
  "policy-level applyRules bypass" \
  "$candidate" \
  "require-restricted-workloads contains unreviewed policy-level settings"

candidate="$(fresh_scope conditional-signature-rule)"
sed -i '/    - name: require-trusted-main-signature/a\      preconditions:\n        all:\n          - key: "{{ request.operation }}"\n            operator: Equals\n            value: CREATE' \
  "${candidate}/verify-signed-images.yaml"
expect_rejected \
  "conditional signature verification bypass" \
  "$candidate" \
  "verify-signed-images/require-trusted-main-signature contains unreviewed rule settings"

for namespace in dev stage prod; do
  candidate="$(fresh_scope "missing-${namespace}")"
  sed -i "/                - ${namespace}$/d" "${candidate}/verify-signed-images.yaml"
  expect_rejected \
    "managed namespace removed: ${namespace}" \
    "$candidate" \
    "verify-signed-images/require-trusted-main-signature must cover exactly dev, stage, and prod"
done

candidate="$(fresh_scope policy-exception)"
printf '%s\n' \
  'apiVersion: policies.kyverno.io/v2' \
  'kind: PolicyException' \
  'metadata:' \
  '  name: bypass-managed-signature-policy' \
  '  namespace: dev' \
  'spec:' \
  '  exceptions:' \
  '    - policyName: verify-signed-images' \
  '      ruleNames:' \
  '        - require-trusted-main-signature' \
  '  match:' \
  '    any:' \
  '      - resources:' \
  '          kinds:' \
  '            - Pod' \
  > "${candidate}/managed-policy-exception.yaml"
expect_rejected \
  "PolicyException bypass for a managed policy" \
  "$candidate" \
  "PolicyException bypasses are forbidden in the managed admission policy scope"

candidate="$(fresh_scope unexpected-cluster-resource)"
printf '%s\n' \
  'apiVersion: rbac.authorization.k8s.io/v1' \
  'kind: ClusterRoleBinding' \
  'metadata:' \
  '  name: unexpected-policy-directory-resource' \
  'roleRef:' \
  '  apiGroup: rbac.authorization.k8s.io' \
  '  kind: ClusterRole' \
  '  name: cluster-admin' \
  'subjects:' \
  '  - kind: ServiceAccount' \
  '    name: default' \
  '    namespace: dev' \
  > "${candidate}/unexpected-cluster-role-binding.yaml"
expect_rejected \
  "non-policy resource in managed admission scope" \
  "$candidate" \
  "Only reviewed ClusterPolicy resources are allowed in the managed admission policy scope: ClusterRoleBinding"

candidate="$(fresh_scope missing-managed-policy)"
rm "${candidate}/require-restricted-workloads.yaml"
expect_rejected \
  "incomplete managed admission policy scope" \
  "$candidate" \
  "Managed admission policy scope must contain exactly the three reviewed ClusterPolicies"

# These checks intentionally match literal shell variable expressions.
# shellcheck disable=SC2016
grep -Fq '"$POLICY_VALIDATOR" "$POLICY_DIR"' "$BOOTSTRAP" || {
  echo "FAIL: Kyverno bootstrap does not validate the managed policy directory" >&2
  exit 1
}
# shellcheck disable=SC2016
validator_line="$(grep -nF '"$POLICY_VALIDATOR" "$POLICY_DIR"' "$BOOTSTRAP" | cut -d: -f1)"
# shellcheck disable=SC2016
chart_download_line="$(grep -nF 'helm pull "$KYVERNO_CHART"' "$BOOTSTRAP" | cut -d: -f1)"
[[ -n "$validator_line" && -n "$chart_download_line" && "$validator_line" -lt "$chart_download_line" ]] || {
  echo "FAIL: Kyverno bootstrap must validate policies before downloading or installing the chart" >&2
  exit 1
}

echo "Admission policy guardrail tests passed"
