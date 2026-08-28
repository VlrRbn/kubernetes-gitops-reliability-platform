#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP="${ROOT_DIR}/scripts/bootstrap-monitoring.sh"
VALUES="${ROOT_DIR}/platform/monitoring/values.yaml"

# These entries intentionally match shell expressions literally.
# shellcheck disable=SC2016
required_bootstrap_contracts=(
  'EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"'
  'CHART_VERSION="88.6.1"'
  'CHART_SHA256="d98b1a1a4f286cb6022c1f059edc01a83da31e3f2dd1ee70533384151a4dc354"'
  'oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack'
  'sha256sum --check --status'
  'helm template monitoring'
  'Unexpected number of rendered monitoring images'
  'Rendered monitoring image is not digest-pinned'
  'helm upgrade --install monitoring'
  'deployment/${OPERATOR_DEPLOYMENT}'
  'kubectl apply --filename "$RULES_FILE"'
  'statefulset/${PROMETHEUS_STATEFULSET}'
  'kubectl get --raw "$PROMETHEUS_RULES_API"'
  'reliability-demo.slo.recording'
  'reliability-demo.slo.alerts'
  '/bin/promtool check config /etc/prometheus/config_out/prometheus.env.yaml'
  'Live monitoring image is not digest-pinned'
)

for contract in "${required_bootstrap_contracts[@]}"; do
  grep -Fq -- "$contract" "$BOOTSTRAP" || {
    echo "Monitoring bootstrap is missing guardrail: $contract" >&2
    exit 1
  }
done

grep -Fq -- '--force' "$BOOTSTRAP" && {
  echo "Monitoring bootstrap must not force resource conflicts" >&2
  exit 1
}

grep -Eq '(^|[^a-z])latest([^a-z]|$)' "$BOOTSTRAP" "$VALUES" && {
  echo "Monitoring configuration contains a mutable latest reference" >&2
  exit 1
}

mapfile -t image_shas < <(awk '$1 == "sha:" {gsub(/"/, "", $2); print $2}' "$VALUES")
[[ "${#image_shas[@]}" -eq 5 ]] || {
  echo "Expected exactly five monitoring image digests" >&2
  exit 1
}
for digest in "${image_shas[@]}"; do
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || {
    echo "Monitoring image digest is not a full SHA256 value: $digest" >&2
    exit 1
  }
done

required_values_contracts=(
  'failurePolicy: Fail'
  'timeoutSeconds: 10'
  'enableAdminAPI: false'
  'disableAlerting: false'
  'serviceMonitorSelectorNilUsesHelmValues: false'
  'observability.reliability-platform.io/monitor: "true"'
  'ruleSelectorNilUsesHelmValues: false'
  'observability.reliability-platform.io/rules: "true"'
  'kubernetes.io/metadata.name: monitoring'
  '- dev'
  '- stage'
  '- prod'
)

for contract in "${required_values_contracts[@]}"; do
  grep -Fq -- "$contract" "$VALUES" || {
    echo "Monitoring values are missing guardrail: $contract" >&2
    exit 1
  }
done

echo "Monitoring bootstrap guardrail tests passed"
