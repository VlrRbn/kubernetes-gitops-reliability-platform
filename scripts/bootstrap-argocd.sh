#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
ARGOCD_VERSION="v3.4.6"
ARGOCD_MANIFEST_SHA256="752b5a2681f2522fc78ea12ba2d23be44a4523cfa5d9a55cf1907909cc23fc5d"
ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ARGOCD_IMAGE="quay.io/argoproj/argocd@sha256:6e9f4f1d646d9056c8e285495d0c8043b5f553c784181b3522ef324dcefdcc82"
DEX_IMAGE="ghcr.io/dexidp/dex@sha256:b8469881d3cb3a73001506f0d3aaefecb9c45d2311c1e0f405d8ac538316c59d"
REDIS_IMAGE="public.ecr.aws/docker/library/redis@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba"
MANIFEST_FILE="$(mktemp)"

cleanup() {
  rm -f "$MANIFEST_FILE"
}
trap cleanup EXIT

pin_image() {
  local source_image="$1"
  local pinned_image="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(grep -Fc -- "image: ${source_image}" "$MANIFEST_FILE")"
  [[ "$actual_count" -eq "$expected_count" ]] || {
    echo "Unexpected reference count for ${source_image}: ${actual_count}" >&2
    exit 1
  }
  sed -i "s|image: ${source_image}|image: ${pinned_image}|g" "$MANIFEST_FILE"
}

for command in curl kubectl sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] || {
  echo "Refusing to bootstrap Argo CD into context '$current_context'; expected '$EXPECTED_CONTEXT'" >&2
  exit 1
}

if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "Required ServiceMonitor CRD is missing" >&2
  echo "Run 'make monitoring-bootstrap' before 'make argocd-bootstrap'" >&2
  exit 1
fi

if kubectl get secrets \
  --namespace dev \
  --selector 'owner=helm,name=reliability-demo' \
  --output=name \
  2>/dev/null | grep -q .; then
  echo "Refusing to take over the legacy Helm release dev/reliability-demo" >&2
  echo "Recreate the disposable cluster before Argo CD bootstrap" >&2
  exit 1
fi

curl --fail --location --silent --show-error \
  "$ARGOCD_MANIFEST_URL" \
  --output "$MANIFEST_FILE"

printf '%s  %s\n' "$ARGOCD_MANIFEST_SHA256" "$MANIFEST_FILE" | sha256sum --check --status || {
  echo "Argo CD install manifest checksum verification failed" >&2
  exit 1
}

pin_image "quay.io/argoproj/argocd:${ARGOCD_VERSION}" "$ARGOCD_IMAGE" 8
pin_image "ghcr.io/dexidp/dex:v2.45.0" "$DEX_IMAGE" 1
pin_image "public.ecr.aws/docker/library/redis:8.2.3-alpine" "$REDIS_IMAGE" 1

for namespace in argocd dev stage prod; do
  kubectl create namespace "$namespace" \
    --dry-run=client \
    --output=yaml |
    kubectl apply --filename=-
done

kubectl apply \
  --server-side \
  --field-manager=argocd-bootstrap \
  --namespace argocd \
  --filename "$MANIFEST_FILE"

while IFS= read -r deployment; do
  kubectl rollout status "$deployment" \
    --namespace argocd \
    --timeout=5m
done < <(kubectl get deployment --namespace argocd --output=name)
kubectl rollout status statefulset/argocd-application-controller \
  --namespace argocd \
  --timeout=5m

kubectl patch configmap argocd-cm \
  --namespace argocd \
  --type merge \
  --patch '{"data":{"admin.enabled":"false"}}'
kubectl rollout restart deployment/argocd-server \
  --namespace argocd
kubectl rollout status deployment/argocd-server \
  --namespace argocd \
  --timeout=5m

kubectl apply --filename "${ROOT_DIR}/platform/argocd/project.yaml"
kubectl apply --filename "${ROOT_DIR}/platform/argocd/applicationset.yaml"

echo "Argo CD ${ARGOCD_VERSION} bootstrapped into ${EXPECTED_CONTEXT}"
