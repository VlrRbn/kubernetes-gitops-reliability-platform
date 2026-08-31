#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
TARGET_ENV="${TARGET_ENV:-dev}"
WORKLOAD_NAME="${WORKLOAD_NAME:-reliability-demo}"
CONFIRM_POD_DELETE="${CONFIRM_POD_DELETE:-}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${ROOT_DIR}/evidence/incident-drills}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KIND_BIN="${KIND_BIN:-kind}"
SMOKE_TEST_BIN="${SMOKE_TEST_BIN:-${SCRIPT_DIR}/smoke-test.sh}"
SELECTOR="app.kubernetes.io/name=${WORKLOAD_NAME},app.kubernetes.io/instance=${WORKLOAD_NAME}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$1"
}

ready_pod() {
  local excluded_uid="${1:-}"

  "$KUBECTL_BIN" get pods \
    --namespace "$TARGET_ENV" \
    --selector "$SELECTOR" \
    --output=json |
    jq --raw-output --arg excluded_uid "$excluded_uid" '
      [
        .items[]
        | select(.metadata.uid != $excluded_uid)
        | select(.status.phase == "Running")
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      ]
      | sort_by(.metadata.creationTimestamp)
      | first
      | select(. != null)
      | [.metadata.name, .metadata.uid, .spec.containers[0].image]
      | @tsv
    '
}

step "Safety"
[[ "$CLUSTER_NAME" == "gitops-reliability" ]] ||
  fail "Pod recovery drills are restricted to the gitops-reliability cluster"
[[ "$TARGET_ENV" == "dev" ]] ||
  fail "Pod recovery drills are restricted to dev"
[[ "$WORKLOAD_NAME" == "reliability-demo" ]] ||
  fail "Pod recovery drills are restricted to the reliability-demo workload"
[[ "$CONFIRM_POD_DELETE" == "DELETE ONE DEV POD" ]] ||
  fail "Set CONFIRM_POD_DELETE='DELETE ONE DEV POD' to authorize the drill"
[[ "$RECOVERY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
  fail "RECOVERY_TIMEOUT_SECONDS must be an integer"
((RECOVERY_TIMEOUT_SECONDS >= 10 && RECOVERY_TIMEOUT_SECONDS <= 600)) ||
  fail "RECOVERY_TIMEOUT_SECONDS must be between 10 and 600"
[[ "$POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] ||
  fail "POLL_INTERVAL_SECONDS must be an integer"
((POLL_INTERVAL_SECONDS <= 30)) ||
  fail "POLL_INTERVAL_SECONDS must be between 0 and 30"

for command in "$KUBECTL_BIN" "$KIND_BIN" jq date; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command is missing: $command"
done
[[ -x "$SMOKE_TEST_BIN" ]] || fail "Smoke test is not executable: $SMOKE_TEST_BIN"

current_context="$($KUBECTL_BIN config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] ||
  fail "Refusing context '${current_context}'; expected '${EXPECTED_CONTEXT}'"

"$KIND_BIN" get clusters | grep -Fxq "$CLUSTER_NAME" ||
  fail "Expected kind cluster does not exist: $CLUSTER_NAME"

application_json="$($KUBECTL_BIN get application "${WORKLOAD_NAME}-${TARGET_ENV}" --namespace argocd --output=json)"
sync_status="$(jq -r '.status.sync.status // ""' <<< "$application_json")"
health_status="$(jq -r '.status.health.status // ""' <<< "$application_json")"
[[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]] ||
  fail "Argo CD application must be Synced and Healthy before fault injection"

cluster_policies="$($KUBECTL_BIN get clusterpolicy --output=json)"
ready_policy_count="$(jq '[
  .items[]
  | select(.metadata.name == "require-immutable-images"
      or .metadata.name == "require-restricted-workloads"
      or .metadata.name == "verify-signed-images")
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
] | length' <<< "$cluster_policies")"
[[ "$ready_policy_count" == "3" ]] ||
  fail "All three reviewed Kyverno ClusterPolicies must be Ready before fault injection"

deployment_json="$($KUBECTL_BIN get deployment "$WORKLOAD_NAME" --namespace "$TARGET_ENV" --output=json)"
managed_by="$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<< "$deployment_json")"
desired_replicas="$(jq -r '.spec.replicas // 1' <<< "$deployment_json")"
ready_replicas="$(jq -r '.status.readyReplicas // 0' <<< "$deployment_json")"
available_replicas="$(jq -r '.status.availableReplicas // 0' <<< "$deployment_json")"
original_image="$(jq -r '.spec.template.spec.containers[0].image // ""' <<< "$deployment_json")"

[[ "$managed_by" == "Helm" ]] || fail "Target Deployment is not managed by Helm"
((desired_replicas > 0)) || fail "Target Deployment has no desired replicas"
[[ "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]] ||
  fail "Target Deployment must be fully available before fault injection"
[[ "$original_image" =~ @sha256:[a-f0-9]{64}$ ]] ||
  fail "Target Deployment image is not pinned by sha256 digest"

initial_pod="$(ready_pod)"
[[ -n "$initial_pod" ]] || fail "No Ready target Pod found"
IFS=$'\t' read -r deleted_pod deleted_uid pod_image <<< "$initial_pod"
[[ "$pod_image" == "$original_image" ]] ||
  fail "Ready Pod image differs from the Deployment image"

echo "Context: ${current_context}"
echo "Environment: ${TARGET_ENV}"
echo "Deployment: ${WORKLOAD_NAME} (${ready_replicas}/${desired_replicas} Ready)"
echo "Selected Pod: ${deleted_pod}"
echo "Image: ${original_image}"

step "Fault injection"
started_at="$(date --utc '+%Y-%m-%dT%H:%M:%SZ')"
started_epoch="$(date --utc '+%s')"
"$KUBECTL_BIN" delete pod "$deleted_pod" \
  --namespace "$TARGET_ENV" \
  --wait=false

step "Recovery observation"
replacement_pod=""
deadline=$((started_epoch + RECOVERY_TIMEOUT_SECONDS))
while (( $(date --utc '+%s') <= deadline )); do
  replacement_pod="$(ready_pod "$deleted_uid")"
  [[ -n "$replacement_pod" ]] && break
  sleep "$POLL_INTERVAL_SECONDS"
done
[[ -n "$replacement_pod" ]] || fail "No replacement Pod became Ready within ${RECOVERY_TIMEOUT_SECONDS} seconds"
IFS=$'\t' read -r replacement_name replacement_uid replacement_image <<< "$replacement_pod"
[[ "$replacement_uid" != "$deleted_uid" ]] || fail "Replacement Pod reused the deleted Pod UID"
[[ "$replacement_image" == "$original_image" ]] || fail "Replacement Pod image changed during recovery"

"$KUBECTL_BIN" rollout status \
  --namespace "$TARGET_ENV" \
  "deployment/${WORKLOAD_NAME}" \
  --timeout="${RECOVERY_TIMEOUT_SECONDS}s"

recovered_at="$(date --utc '+%Y-%m-%dT%H:%M:%SZ')"
recovered_epoch="$(date --utc '+%s')"
recovery_seconds=$((recovered_epoch - started_epoch))

step "Validation and evidence"
application_json="$($KUBECTL_BIN get application "${WORKLOAD_NAME}-${TARGET_ENV}" --namespace argocd --output=json)"
sync_status="$(jq -r '.status.sync.status // ""' <<< "$application_json")"
health_status="$(jq -r '.status.health.status // ""' <<< "$application_json")"
[[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]] ||
  fail "Argo CD application did not return to Synced and Healthy"

deployment_image="$($KUBECTL_BIN get deployment "$WORKLOAD_NAME" \
  --namespace "$TARGET_ENV" \
  --output=jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$deployment_image" == "$original_image" ]] ||
  fail "Deployment image changed during the drill"

policy_reports="$($KUBECTL_BIN get policyreport --namespace "$TARGET_ENV" --output=json)"
policy_report_count="$(jq '.items | length' <<< "$policy_reports")"
((policy_report_count > 0)) || fail "No Kyverno policy reports found in dev"
policy_violations="$(jq '[.items[]?.summary | (.fail // 0) + (.warn // 0) + (.error // 0)] | add // 0' <<< "$policy_reports")"
[[ "$policy_violations" == "0" ]] ||
  fail "Kyverno policy reports contain ${policy_violations} failure, warning, or error result(s)"

NAMESPACE="$TARGET_ENV" RELEASE_NAME="$WORKLOAD_NAME" "$SMOKE_TEST_BIN"

mkdir -p "$EVIDENCE_DIR"
evidence_file="${EVIDENCE_DIR}/pod-recovery-${TARGET_ENV}-$(date --utc '+%Y%m%dT%H%M%SZ').md"
cat > "$evidence_file" <<EOF
# Pod Recovery Drill Evidence

- Result: PASS
- Context: \`${current_context}\`
- Environment: \`${TARGET_ENV}\`
- Deployment: \`${WORKLOAD_NAME}\`
- Image: \`${original_image}\`
- Started: \`${started_at}\`
- Recovered: \`${recovered_at}\`
- Recovery duration: ${recovery_seconds} seconds
- Deleted Pod: \`${deleted_pod}\` (UID \`${deleted_uid}\`)
- Replacement Pod: \`${replacement_name}\` (UID \`${replacement_uid}\`)
- Argo CD: \`${sync_status} / ${health_status}\`
- Kyverno policy violations: ${policy_violations}
- Smoke test: PASS
EOF

echo "Recovery completed in ${recovery_seconds} second(s)"
echo "Evidence: ${evidence_file}"
