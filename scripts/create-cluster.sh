#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"

if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  echo "kind cluster already exists: $CLUSTER_NAME"
  exit 0
fi

kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "${ROOT_DIR}/platform/kind/kind-config.yaml"
