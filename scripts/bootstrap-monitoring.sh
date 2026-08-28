#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
CHART_VERSION="88.6.1"
CHART_SHA256="d98b1a1a4f286cb6022c1f059edc01a83da31e3f2dd1ee70533384151a4dc354"
CHART="oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"
VALUES_FILE="${ROOT_DIR}/platform/monitoring/values.yaml"
WORK_DIR="$(mktemp -d)"
CHART_FILE="${WORK_DIR}/kube-prometheus-stack-${CHART_VERSION}.tgz"
RENDERED_FILE="${WORK_DIR}/monitoring-rendered.yaml"
OPERATOR_DEPLOYMENT="monitoring-kube-prometheus-operator"
PROMETHEUS_STATEFULSET="prometheus-monitoring-kube-prometheus-prometheus"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

step() {
  printf '\n==> %s\n' "$1"
}

step "Checking prerequisites and Kubernetes context"
for command in awk helm jq kubectl sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] || {
  echo "Refusing to bootstrap monitoring into context '$current_context'; expected '$EXPECTED_CONTEXT'" >&2
  exit 1
}

step "Downloading and verifying kube-prometheus-stack ${CHART_VERSION}"
helm pull "$CHART" \
  --version "$CHART_VERSION" \
  --destination "$WORK_DIR"

printf '%s  %s\n' "$CHART_SHA256" "$CHART_FILE" |
  sha256sum --check --status || {
    echo "kube-prometheus-stack chart checksum verification failed" >&2
    exit 1
  }

helm template monitoring "$CHART_FILE" \
  --namespace monitoring \
  --values "$VALUES_FILE" > "$RENDERED_FILE"

mapfile -t rendered_images < <(
  {
    awk '$1 == "image:" && NF >= 2 {gsub(/"/, "", $2); print $2}' "$RENDERED_FILE"
    sed -n 's/.*--prometheus-config-reloader=\([^[:space:]]*\).*/\1/p' "$RENDERED_FILE"
  } | sort -u
)

[[ "${#rendered_images[@]}" -eq 4 ]] || {
  echo "Unexpected number of rendered monitoring images: ${#rendered_images[@]}" >&2
  printf '  %s\n' "${rendered_images[@]}" >&2
  exit 1
}
for image in "${rendered_images[@]}"; do
  [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || {
    echo "Rendered monitoring image is not digest-pinned: $image" >&2
    exit 1
  }
done

step "Installing the pinned Prometheus foundation"
helm upgrade --install monitoring "$CHART_FILE" \
  --namespace monitoring \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 10m

kubectl rollout status \
  --namespace monitoring \
  "deployment/${OPERATOR_DEPLOYMENT}" \
  --timeout=5m

statefulset_ready=false
for _ in $(seq 1 60); do
  if kubectl get statefulset "$PROMETHEUS_STATEFULSET" \
    --namespace monitoring >/dev/null 2>&1; then
    statefulset_ready=true
    break
  fi
  sleep 2
done
[[ "$statefulset_ready" == true ]] || {
  echo "Timed out waiting for the Prometheus StatefulSet" >&2
  exit 1
}

kubectl rollout status \
  --namespace monitoring \
  "statefulset/${PROMETHEUS_STATEFULSET}" \
  --timeout=5m

mapfile -t live_images < <(
  kubectl get deployment,statefulset \
    --namespace monitoring \
    --output=json |
    jq -r '.items[] | .spec.template.spec | (.initContainers[]?.image, .containers[]?.image)' |
    sort -u
)
[[ "${#live_images[@]}" -eq 3 ]] || {
  echo "Unexpected number of live monitoring images: ${#live_images[@]}" >&2
  printf '  %s\n' "${live_images[@]}" >&2
  exit 1
}
for image in "${live_images[@]}"; do
  [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || {
    echo "Live monitoring image is not digest-pinned: $image" >&2
    exit 1
  }
done

echo "Prometheus foundation ${CHART_VERSION} is ready with digest-pinned images"
