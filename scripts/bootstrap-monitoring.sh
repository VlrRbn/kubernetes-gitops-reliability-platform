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
RULES_FILE="${ROOT_DIR}/platform/monitoring/slo-rules.yaml"
DASHBOARD_FILE="${ROOT_DIR}/platform/monitoring/dashboards/reliability-demo-slo.json"
WORK_DIR="$(mktemp -d)"
CHART_FILE="${WORK_DIR}/kube-prometheus-stack-${CHART_VERSION}.tgz"
RENDERED_FILE="${WORK_DIR}/monitoring-rendered.yaml"
DASHBOARD_CONFIGMAP_FILE="${WORK_DIR}/grafana-dashboard-configmap.yaml"
NAMESPACE_FILE="${WORK_DIR}/monitoring-namespace.yaml"
OPERATOR_DEPLOYMENT="monitoring-kube-prometheus-operator"
GRAFANA_DEPLOYMENT="monitoring-grafana"
PROMETHEUS_STATEFULSET="prometheus-monitoring-kube-prometheus-prometheus"
ALERTMANAGER_STATEFULSET="alertmanager-monitoring-kube-prometheus-alertmanager"
PROMETHEUS_RULES_API="/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:http-web/proxy/api/v1/rules"
RULES_LOAD_ATTEMPTS=90
RULES_LOAD_POLL_SECONDS=2

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

[[ "${#rendered_images[@]}" -eq 6 ]] || {
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

jq empty "$DASHBOARD_FILE"

step "Provisioning the version-controlled Grafana dashboard"
kubectl create namespace monitoring \
  --dry-run=client \
  --output=yaml > "$NAMESPACE_FILE"
kubectl apply --filename "$NAMESPACE_FILE"

kubectl create configmap reliability-demo-slo-dashboard \
  --namespace monitoring \
  --from-file=reliability-demo-slo.json="$DASHBOARD_FILE" \
  --dry-run=client \
  --output=yaml > "$DASHBOARD_CONFIGMAP_FILE"
kubectl apply --filename "$DASHBOARD_CONFIGMAP_FILE"

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

kubectl rollout status \
  --namespace monitoring \
  "deployment/${GRAFANA_DEPLOYMENT}" \
  --timeout=5m

kubectl get --raw \
  "/api/v1/namespaces/monitoring/services/${GRAFANA_DEPLOYMENT}:http-web/proxy/api/health" |
  jq --exit-status '.database == "ok"' >/dev/null

step "Applying SLO recording and alerting rules"
kubectl apply --filename "$RULES_FILE"

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

kubectl rollout status \
  --namespace monitoring \
  "statefulset/${ALERTMANAGER_STATEFULSET}" \
  --timeout=5m

rules_loaded=false
for _ in $(seq 1 "$RULES_LOAD_ATTEMPTS"); do
  if kubectl get --raw "$PROMETHEUS_RULES_API" 2>/dev/null |
    jq --exit-status '
      [.data.groups[]?.name] as $groups |
      ($groups | index("reliability-demo.slo.recording")) != null and
      ($groups | index("reliability-demo.slo.alerts")) != null
    ' >/dev/null; then
    rules_loaded=true
    break
  fi
  sleep "$RULES_LOAD_POLL_SECONDS"
done
[[ "$rules_loaded" == true ]] || {
  echo "Prometheus did not load both reviewed SLO rule groups within $((RULES_LOAD_ATTEMPTS * RULES_LOAD_POLL_SECONDS)) seconds" >&2
  exit 1
}

kubectl exec \
  --namespace monitoring \
  "statefulset/${PROMETHEUS_STATEFULSET}" \
  --container prometheus \
  -- /bin/promtool check config /etc/prometheus/config_out/prometheus.env.yaml \
  >/dev/null

kubectl exec \
  --namespace monitoring \
  "statefulset/${ALERTMANAGER_STATEFULSET}" \
  --container alertmanager \
  -- /bin/amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml \
  >/dev/null

mapfile -t live_images < <(
  kubectl get deployment,statefulset \
    --namespace monitoring \
    --output=json |
    jq -r '.items[] | .spec.template.spec | (.initContainers[]?.image, .containers[]?.image)' |
    sort -u
)
[[ "${#live_images[@]}" -eq 5 ]] || {
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

grafana_restarts="$(
  kubectl get pods \
    --namespace monitoring \
    --selector='app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring' \
    --output=json |
    jq '[.items[].status.containerStatuses[]? | select(.name == "grafana") | .restartCount] | add // 0'
)"
[[ "$grafana_restarts" -eq 0 ]] || {
  echo "Grafana restarted during bootstrap: ${grafana_restarts} restart(s)" >&2
  exit 1
}

echo "Prometheus, Alertmanager, Grafana, and SLO rules are ready"
