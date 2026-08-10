#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GO_IMAGE="golang:1.26.5-alpine3.23@sha256:622e56dbc11a8cfe87cafa2331e9a201877271cbff918af53d3be315f3da88cc"
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

for script in "${SCRIPT_DIR}"/*.sh; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SCRIPT_DIR}"/*.sh
fi

echo "Local checks passed"
