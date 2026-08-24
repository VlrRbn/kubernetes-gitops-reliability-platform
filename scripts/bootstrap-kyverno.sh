#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
KYVERNO_VERSION="v1.18.2"
KYVERNO_CHART_VERSION="3.8.2"
KYVERNO_CHART_SHA256="7a9bdaeba4334337b7ff231baad1ec2044429893008a00bf398933bc033abc8e"
KYVERNO_CHART="oci://ghcr.io/kyverno/charts/kyverno"
POLICY_DIR="${ROOT_DIR}/platform/kyverno/policies"
VALUES_FILE="${ROOT_DIR}/platform/kyverno/values.yaml"
WORK_DIR="$(mktemp -d)"
CHART_FILE="${WORK_DIR}/kyverno-${KYVERNO_CHART_VERSION}.tgz"
RENDERED_FILE="${WORK_DIR}/kyverno-rendered.yaml"
AUDIT_DIR="${WORK_DIR}/audit-policies"
AUDIT_POLICY_NAMES=()
AUDIT_APPLIED=false

step() {
  printf '\n==> %s\n' "$1"
}

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ "$AUDIT_APPLIED" == true ]]; then
    if ! kubectl delete clusterpolicy "${AUDIT_POLICY_NAMES[@]}" \
      --ignore-not-found >/dev/null; then
      echo "CRITICAL: failed to remove temporary Audit policies" >&2
      status=1
    else
      for policy_name in "${AUDIT_POLICY_NAMES[@]}"; do
        if kubectl get clusterpolicy "$policy_name" >/dev/null 2>&1; then
          echo "CRITICAL: temporary Audit policy still exists: $policy_name" >&2
          status=1
        fi
      done
    fi
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT

step "Checking prerequisites and Kubernetes context"
for command in helm jq kubectl sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] || {
  echo "Refusing to bootstrap Kyverno into context '$current_context'; expected '$EXPECTED_CONTEXT'" >&2
  exit 1
}

for namespace in dev stage prod; do
  kubectl get namespace "$namespace" >/dev/null || {
    echo "Required Argo-managed namespace does not exist: $namespace" >&2
    exit 1
  }
done

step "Downloading and verifying Kyverno Helm chart ${KYVERNO_CHART_VERSION}"
helm pull "$KYVERNO_CHART" \
  --version "$KYVERNO_CHART_VERSION" \
  --destination "$WORK_DIR"

printf '%s  %s\n' "$KYVERNO_CHART_SHA256" "$CHART_FILE" |
  sha256sum --check --status || {
    echo "Kyverno chart checksum verification failed" >&2
    exit 1
  }

helm template kyverno "$CHART_FILE" \
  --namespace kyverno \
  --values "$VALUES_FILE" > "$RENDERED_FILE"

mapfile -t rendered_images < <(
  awk '$1 == "image:" && NF >= 2 {gsub(/"/, "", $2); print $2}' "$RENDERED_FILE" |
    sort -u
)
[[ "${#rendered_images[@]}" -ge 6 ]] || {
  echo "Unexpected number of rendered Kyverno images: ${#rendered_images[@]}" >&2
  exit 1
}
for image in "${rendered_images[@]}"; do
  [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || {
    echo "Rendered Kyverno image is not digest-pinned: $image" >&2
    exit 1
  }
done

step "Installing Kyverno ${KYVERNO_VERSION} with digest-pinned images"
helm upgrade --install kyverno "$CHART_FILE" \
  --namespace kyverno \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 5m

step "Waiting for the Kyverno policy webhooks"
webhooks_ready=false
for _ in $(seq 1 60); do
  if kubectl apply --dry-run=server \
    --filename "$POLICY_DIR" >/dev/null 2>&1; then
    webhooks_ready=true
    break
  fi
  sleep 2
done
[[ "$webhooks_ready" == true ]] || {
  echo "Timed out waiting for the Kyverno policy webhooks" >&2
  exit 1
}

step "Checking the admission policy lifecycle"
POLICY_FILES=()
POLICY_NAMES=()
AUDIT_POLICY_FILES=()

for policy_file in "$POLICY_DIR"/*.yaml; do
  policy_name="$(awk '$1 == "name:" {print $2; exit}' "$policy_file")"
  [[ -n "$policy_name" ]] || {
    echo "Unable to determine policy name from $policy_file" >&2
    exit 1
  }

  POLICY_FILES+=("$policy_file")
  POLICY_NAMES+=("$policy_name")

  if kubectl get clusterpolicy "$policy_name" >/dev/null 2>&1; then
    if kubectl diff --filename "$policy_file" >/dev/null; then
      continue
    fi
    diff_status="$?"
    if [[ "$diff_status" -eq 1 ]]; then
      echo "Refusing to replace changed admission policy without a fresh audit: $policy_name" >&2
    else
      echo "Unable to compare existing admission policy: $policy_name" >&2
    fi
    exit 1
  fi

  AUDIT_POLICY_FILES+=("$policy_file")
  AUDIT_POLICY_NAMES+=("$policy_name")
done

[[ "${#POLICY_FILES[@]}" -gt 0 ]] || {
  echo "No admission policies found in $POLICY_DIR" >&2
  exit 1
}

if [[ "${#AUDIT_POLICY_FILES[@]}" -eq 0 ]]; then
  echo "Kyverno ${KYVERNO_VERSION} and admission policies are already enforced"
  exit 0
fi

mkdir -p "$AUDIT_DIR"
expected_audit_actions=0
for policy in "${AUDIT_POLICY_FILES[@]}"; do
  enforce_actions="$(grep -c 'failureAction: Enforce' "$policy")"
  [[ "$enforce_actions" -gt 0 ]] || {
    echo "Policy has no enforce action to audit: $policy" >&2
    exit 1
  }
  expected_audit_actions="$((expected_audit_actions + enforce_actions))"
  sed 's/failureAction: Enforce/failureAction: Audit/g' "$policy" \
    > "${AUDIT_DIR}/$(basename "$policy")"
done

audit_actions="$(grep -Rh 'failureAction: Audit' "$AUDIT_DIR" | wc -l)"
[[ "$audit_actions" -eq "$expected_audit_actions" ]] || {
  echo "Unexpected number of audit policy actions: $audit_actions" >&2
  exit 1
}

step "Auditing existing dev, stage, and prod workloads"
AUDIT_APPLIED=true
kubectl apply --filename "$AUDIT_DIR"

reports_ready=false
for _ in $(seq 1 60); do
  reports="$(kubectl get policyreport --all-namespaces --output=json)"
  reports_ready=true
  for namespace in dev stage prod; do
    for policy in "${AUDIT_POLICY_NAMES[@]}"; do
      if ! jq -e \
        --arg namespace "$namespace" \
        --arg policy "$policy" \
        '[.items[] | select(.metadata.namespace == $namespace) | .results[]? | select(.policy == $policy)] | length > 0' \
        >/dev/null <<< "$reports"; then
        reports_ready=false
      fi
    done
  done
  [[ "$reports_ready" == true ]] && break
  sleep 2
done

if [[ "$reports_ready" != true ]]; then
  echo "Timed out waiting for Kyverno background audit reports" >&2
  exit 1
fi

failures=0
for policy in "${AUDIT_POLICY_NAMES[@]}"; do
  policy_failures="$(jq --arg policy "$policy" '[
    .items[].results[]?
    | select(.result == "fail" and .policy == $policy)
  ] | length' <<< "$reports")"
  failures="$((failures + policy_failures))"
done
if [[ "$failures" -ne 0 ]]; then
  for policy in "${AUDIT_POLICY_NAMES[@]}"; do
    jq -r --arg policy "$policy" '
      .items[] as $report
      | $report.results[]?
      | select(.result == "fail" and .policy == $policy)
      | "FAIL: \($report.metadata.namespace)/\($report.scope.kind)/\($report.scope.name): \(.policy)/\(.rule): \(.message)"
    ' <<< "$reports" >&2
  done

  echo "Refusing to enforce admission policies: live workload audit found $failures failure(s)" >&2
  exit 1
fi

step "Enforcing admission policies after a clean audit"
kubectl apply --filename "$POLICY_DIR"

for policy_name in "${POLICY_NAMES[@]}"; do
  ready=false
  for _ in $(seq 1 60); do
    if kubectl get clusterpolicy "$policy_name" --output=json |
      jq -e '.status.conditions[]? | select(.type == "Ready" and .status == "True")' \
        >/dev/null; then
      ready=true
      break
    fi
    sleep 2
  done
  [[ "$ready" == true ]] || {
    echo "Timed out waiting for enforced policy to become Ready: $policy_name" >&2
    exit 1
  }
done

AUDIT_APPLIED=false

echo "Kyverno ${KYVERNO_VERSION} installed; live audit passed and policies are enforced"
