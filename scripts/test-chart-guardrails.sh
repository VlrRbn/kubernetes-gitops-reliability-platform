#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CHART="${ROOT_DIR}/charts/reliability-demo"
RENDERED="$(mktemp)"
MONITOR_RENDERED="$(mktemp)"
DEFAULT_RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED" "$MONITOR_RENDERED" "$DEFAULT_RENDERED"' EXIT

helm template reliability-demo "$CHART" \
  --namespace prod \
  --values "${ROOT_DIR}/gitops/environments/prod/values.yaml" \
  > "$RENDERED"

required_lines=(
  "automountServiceAccountToken: false"
  "runAsNonRoot: true"
  "runAsUser: 65532"
  "type: RuntimeDefault"
  "allowPrivilegeEscalation: false"
  "readOnlyRootFilesystem: true"
  "path: /healthz"
  "path: /readyz"
)

for line in "${required_lines[@]}"; do
  grep -Fq -- "$line" "$RENDERED" || {
    echo "Rendered chart is missing guardrail: $line" >&2
    exit 1
  }
done

helm template reliability-demo "$CHART" \
  --namespace prod \
  --values "${ROOT_DIR}/gitops/environments/prod/values.yaml" \
  --set metrics.serviceMonitor.enabled=true \
  > "$MONITOR_RENDERED"

required_monitor_lines=(
  "apiVersion: monitoring.coreos.com/v1"
  "kind: ServiceMonitor"
  'observability.reliability-platform.io/monitor: "true"'
  "port: http"
  'path: "/metrics"'
  'interval: "30s"'
  'scrapeTimeout: "10s"'
  "honorLabels: false"
)

for line in "${required_monitor_lines[@]}"; do
  grep -Fq -- "$line" "$MONITOR_RENDERED" || {
    echo "Rendered ServiceMonitor is missing guardrail: $line" >&2
    exit 1
  }
done

helm template reliability-demo "$CHART" > "$DEFAULT_RENDERED"

grep -Fq "kind: ServiceMonitor" "$DEFAULT_RENDERED" && {
  echo "ServiceMonitor must remain disabled until its CRD is installed" >&2
  exit 1
}

if helm template reliability-demo "$CHART" \
  --set fault.errorRate=1.1 \
  >/dev/null 2>&1; then
  echo "Chart accepted fault.errorRate above 1" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set metrics.serviceMonitor.interval=5s \
  >/dev/null 2>&1; then
  echo "Chart accepted an unreviewed metrics scrape interval" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set-string metrics.path=metrics \
  >/dev/null 2>&1; then
  echo "Chart accepted a metrics path without a leading slash" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set replicaCount=0 \
  >/dev/null 2>&1; then
  echo "Chart accepted zero replicas" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set image.digest=sha256:not-a-digest \
  >/dev/null 2>&1; then
  echo "Chart accepted an invalid image digest" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set probes.readiness.periodSeconds=0 \
  >/dev/null 2>&1; then
  echo "Chart accepted a zero readiness probe period" >&2
  exit 1
fi

if helm template reliability-demo "$CHART" \
  --set-string resources.requests.cpu= \
  >/dev/null 2>&1; then
  echo "Chart accepted an empty CPU request" >&2
  exit 1
fi

echo "Helm chart guardrail tests passed"
