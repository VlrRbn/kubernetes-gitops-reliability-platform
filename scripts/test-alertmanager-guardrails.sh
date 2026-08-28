#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALUES="${ROOT_DIR}/platform/monitoring/values.yaml"
BOOTSTRAP="${ROOT_DIR}/scripts/bootstrap-monitoring.sh"
DELIVERY_TEST="${ROOT_DIR}/scripts/test-alertmanager-delivery.sh"

required_values_contracts=(
  'tplConfig: true'
  'stringConfig: |'
  'repository: prometheus/alertmanager'
  'tag: v0.34.0'
  'sha: 690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d'
  'automountServiceAccountToken: false'
  'receiver: reliability-demo-dev'
  'url: http://reliability-demo.dev.svc.cluster.local/'
  'send_resolved: true'
  'group_wait: 1s'
  'repeat_interval: 4h'
  'disableAlerting: false'
)

for contract in "${required_values_contracts[@]}"; do
  grep -Fq -- "$contract" "$VALUES" || {
    echo "Alertmanager values are missing guardrail: $contract" >&2
    exit 1
  }
done

grep -Fq '  config:' "$VALUES" && {
  echo "Alertmanager must use a complete stringConfig instead of merging chart defaults" >&2
  exit 1
}

# These entries intentionally match shell expressions literally.
# shellcheck disable=SC2016
required_runtime_contracts=(
  'statefulset/${ALERTMANAGER_STATEFULSET}'
  '/bin/amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml'
  'EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"'
  'ReliabilityDemoDeliveryTest'
  '/bin/amtool'
  '--alertmanager.url=http://localhost:9093'
  'after > before'
)

for contract in "${required_runtime_contracts[@]}"; do
  if ! grep -Fq -- "$contract" "$BOOTSTRAP" "$DELIVERY_TEST"; then
    echo "Alertmanager runtime checks are missing guardrail: $contract" >&2
    exit 1
  fi
done

grep -Eq '(^|[^a-z])latest([^a-z]|$)' "$VALUES" "$BOOTSTRAP" && {
  echo "Alertmanager configuration contains a mutable latest reference" >&2
  exit 1
}

echo "Alertmanager configuration and delivery guardrails passed"
