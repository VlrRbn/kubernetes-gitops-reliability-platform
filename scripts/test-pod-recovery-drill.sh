#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRILL="${SCRIPT_DIR}/run-pod-recovery-drill.sh"
TEST_DIR="$(mktemp -d)"
MOCK_BIN="${TEST_DIR}/bin"
MOCK_STATE="${TEST_DIR}/state"
MOCK_LOG="${TEST_DIR}/kubectl.log"
EVIDENCE_DIR="${TEST_DIR}/evidence"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$MOCK_BIN"

cat > "${MOCK_BIN}/kind" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == "get clusters" ]] || exit 1
echo gitops-reliability
EOF

cat > "${MOCK_BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "$*" >> "$MOCK_LOG"

case "$*" in
  "config current-context")
    echo "${MOCK_CONTEXT:-kind-gitops-reliability}"
    ;;
  "get application reliability-demo-dev --namespace argocd --output=json")
    printf '{"status":{"sync":{"status":"%s"},"health":{"status":"%s"}}}\n' \
      "${MOCK_SYNC_STATUS:-Synced}" "${MOCK_HEALTH_STATUS:-Healthy}"
    ;;
  "get clusterpolicy --output=json")
    ready="${MOCK_POLICY_READY_STATUS:-True}"
    cat <<JSON
{"items":[{"metadata":{"name":"require-immutable-images"},"status":{"conditions":[{"type":"Ready","status":"${ready}"}]}},{"metadata":{"name":"require-restricted-workloads"},"status":{"conditions":[{"type":"Ready","status":"${ready}"}]}},{"metadata":{"name":"verify-signed-images"},"status":{"conditions":[{"type":"Ready","status":"${ready}"}]}}]}
JSON
    ;;
  "get deployment reliability-demo --namespace dev --output=json")
    cat <<JSON
{"metadata":{"labels":{"app.kubernetes.io/managed-by":"${MOCK_MANAGED_BY:-Helm}"}},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"${MOCK_IMAGE:-ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:1111111111111111111111111111111111111111111111111111111111111111}"}]}}},"status":{"readyReplicas":${MOCK_READY_REPLICAS:-1},"availableReplicas":${MOCK_AVAILABLE_REPLICAS:-1}}}
JSON
    ;;
  "get deployment reliability-demo --namespace dev --output=jsonpath={.spec.template.spec.containers[0].image}")
    echo -n "${MOCK_IMAGE:-ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    ;;
  "get pods --namespace dev --selector app.kubernetes.io/name=reliability-demo,app.kubernetes.io/instance=reliability-demo --output=json")
    if [[ -f "$MOCK_STATE" ]]; then
      name=reliability-demo-new
      uid=new-uid
      timestamp=2026-08-30T18:01:00Z
    else
      name=reliability-demo-old
      uid=old-uid
      timestamp=2026-08-30T18:00:00Z
    fi
    cat <<JSON
{"items":[{"metadata":{"name":"${name}","uid":"${uid}","creationTimestamp":"${timestamp}"},"spec":{"containers":[{"image":"ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    ;;
  "delete pod reliability-demo-old --namespace dev --wait=false")
    touch "$MOCK_STATE"
    echo "pod/reliability-demo-old deleted"
    ;;
  "rollout status --namespace dev deployment/reliability-demo --timeout=10s")
    echo "deployment reliability-demo successfully rolled out"
    ;;
  "get policyreport --namespace dev --output=json")
    if [[ "${MOCK_EMPTY_POLICY_REPORTS:-false}" == "true" ]]; then
      echo '{"items":[]}'
    else
      echo '{"items":[{"summary":{"pass":4,"fail":0,"warn":0,"error":0,"skip":0}}]}'
    fi
    ;;
  *)
    echo "Unexpected kubectl call: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "${MOCK_BIN}/smoke-test" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "${NAMESPACE}:${RELEASE_NAME}" > "$SMOKE_LOG"
echo "Smoke test passed for namespace ${NAMESPACE}"
EOF

chmod +x "${MOCK_BIN}/kind" "${MOCK_BIN}/kubectl" "${MOCK_BIN}/smoke-test"

run_drill() {
  env \
    PATH="${MOCK_BIN}:$PATH" \
    KUBECTL_BIN="${MOCK_BIN}/kubectl" \
    KIND_BIN="${MOCK_BIN}/kind" \
    SMOKE_TEST_BIN="${MOCK_BIN}/smoke-test" \
    MOCK_STATE="$MOCK_STATE" \
    MOCK_LOG="$MOCK_LOG" \
    SMOKE_LOG="${TEST_DIR}/smoke.log" \
    EVIDENCE_DIR="$EVIDENCE_DIR" \
    RECOVERY_TIMEOUT_SECONDS=10 \
    POLL_INTERVAL_SECONDS=0 \
    "$@" \
    "$DRILL"
}

expect_rejected() {
  local name="$1"
  local expected_reason="$2"
  shift 2
  local output

  rm -f "$MOCK_STATE" "$MOCK_LOG"
  echo "Testing negative recovery-drill case: $name"
  if output="$(run_drill "$@" 2>&1)"; then
    echo "FAIL: recovery drill accepted negative case: $name" >&2
    exit 1
  fi
  echo "$output"
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: recovery drill rejected '$name' for the wrong reason" >&2
    echo "Expected: $expected_reason" >&2
    exit 1
  }
  if [[ -f "$MOCK_LOG" ]] && grep -Fq 'delete pod' "$MOCK_LOG"; then
    echo "FAIL: negative case reached Pod deletion: $name" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_rejected \
  "missing confirmation" \
  "Set CONFIRM_POD_DELETE='DELETE ONE DEV POD'" \
  CONFIRM_POD_DELETE=

expect_rejected \
  "non-dev target" \
  "Pod recovery drills are restricted to dev" \
  TARGET_ENV=prod CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "different kind cluster" \
  "Pod recovery drills are restricted to the gitops-reliability cluster" \
  CLUSTER_NAME=other-lab CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "different workload" \
  "Pod recovery drills are restricted to the reliability-demo workload" \
  WORKLOAD_NAME=another-app CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "wrong Kubernetes context" \
  "Refusing context 'production'; expected 'kind-gitops-reliability'" \
  MOCK_CONTEXT=production CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "unhealthy Argo application" \
  "Argo CD application must be Synced and Healthy before fault injection" \
  MOCK_HEALTH_STATUS=Degraded CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "unready admission policy" \
  "All three reviewed Kyverno ClusterPolicies must be Ready before fault injection" \
  MOCK_POLICY_READY_STATUS=False CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "unavailable Deployment" \
  "Target Deployment must be fully available before fault injection" \
  MOCK_READY_REPLICAS=0 MOCK_AVAILABLE_REPLICAS=0 CONFIRM_POD_DELETE='DELETE ONE DEV POD'

expect_rejected \
  "mutable Deployment image" \
  "Target Deployment image is not pinned by sha256 digest" \
  MOCK_IMAGE=nginx:latest CONFIRM_POD_DELETE='DELETE ONE DEV POD'

rm -f "$MOCK_STATE" "$MOCK_LOG"
run_drill CONFIRM_POD_DELETE='DELETE ONE DEV POD' >/dev/null

[[ "$(grep -c 'delete pod reliability-demo-old' "$MOCK_LOG")" -eq 1 ]] || {
  echo "FAIL: positive drill did not delete exactly one expected Pod" >&2
  exit 1
}
grep -Fxq 'dev:reliability-demo' "${TEST_DIR}/smoke.log" || {
  echo "FAIL: positive drill did not run the dev smoke test" >&2
  exit 1
}
evidence_file="$(find "$EVIDENCE_DIR" -maxdepth 1 -type f -name 'pod-recovery-dev-*.md' -print -quit)"
[[ -n "$evidence_file" ]] || {
  echo "FAIL: positive drill did not create evidence" >&2
  exit 1
}
grep -Fq -- '- Result: PASS' "$evidence_file"
grep -Fq -- "- Argo CD: \`Synced / Healthy\`" "$evidence_file"
grep -Fq -- '- Smoke test: PASS' "$evidence_file"

echo "Pod recovery drill positive and negative tests passed"
