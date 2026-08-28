#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GO_IMAGE="golang:1.26.6-alpine3.23@sha256:5978cc992ad5ef96a7469713c8af849c1433824761ce3be2c56381403cd8d9a3"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

if command -v go >/dev/null 2>&1; then
  unformatted="$(gofmt -l "${ROOT_DIR}/app")"
  [[ -z "$unformatted" ]] || {
    echo "Go files require formatting:" >&2
    echo "$unformatted" >&2
    exit 1
  }
  (
    cd "${ROOT_DIR}/app"
    go vet ./...
    go test ./...
  )
else
  command -v docker >/dev/null 2>&1 || {
    echo "Go or Docker is required for application checks" >&2
    exit 1
  }
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env GOCACHE=/tmp/go-build \
    --env GOMODCACHE=/tmp/go-mod \
    --volume "${ROOT_DIR}/app:/src:ro" \
    --workdir /src \
    "$GO_IMAGE" \
    sh -ec 'files="$(gofmt -l .)"; test -z "$files" || { echo "$files"; exit 1; }; go vet ./...; go test ./...'
fi

command -v helm >/dev/null 2>&1 || {
  echo "helm is required for chart checks" >&2
  exit 1
}
helm version --short >/dev/null 2>&1 || {
  echo "helm is installed but not runnable" >&2
  exit 1
}

for env in dev stage prod; do
  helm lint "${ROOT_DIR}/charts/reliability-demo" \
    --values "${ROOT_DIR}/gitops/environments/${env}/values.yaml"
  helm template reliability-demo "${ROOT_DIR}/charts/reliability-demo" \
    --namespace "$env" \
    --values "${ROOT_DIR}/gitops/environments/${env}/values.yaml" \
    > "${RENDER_DIR}/reliability-demo-${env}.yaml"
done

"${SCRIPT_DIR}/test-chart-guardrails.sh"
"${SCRIPT_DIR}/test-workflow-guardrails.sh"
"${SCRIPT_DIR}/test-gitops-guardrails.sh"
"${SCRIPT_DIR}/test-promotion-guardrails.sh"
"${SCRIPT_DIR}/test-monitoring-guardrails.sh"
"${SCRIPT_DIR}/test-slo-rules.sh"
"${SCRIPT_DIR}/test-signature-policy-guardrails.sh"
"${SCRIPT_DIR}/test-admission-policies.sh"

for script in "${SCRIPT_DIR}"/*.sh; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SCRIPT_DIR}"/*.sh
fi

echo "Local checks passed"
