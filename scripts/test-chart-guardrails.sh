#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CHART="${ROOT_DIR}/charts/reliability-demo"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

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

if helm template reliability-demo "$CHART" \
  --set fault.errorRate=1.1 \
  >/dev/null 2>&1; then
  echo "Chart accepted fault.errorRate above 1" >&2
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
