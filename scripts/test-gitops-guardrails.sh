#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ROOT_DIR}/platform/argocd/project.yaml"
APPLICATION_SET="${ROOT_DIR}/platform/argocd/applicationset.yaml"
BOOTSTRAP="${ROOT_DIR}/scripts/bootstrap-argocd.sh"
STRUCTURAL_VALIDATOR="${SCRIPT_DIR}/validate-gitops-boundaries.sh"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

"$STRUCTURAL_VALIDATOR" "$PROJECT" "$APPLICATION_SET"

required_project_contracts=(
  "https://github.com/VlrRbn/kubernetes-gitops-reliability-platform.git"
  "namespace: dev"
  "namespace: stage"
  "namespace: prod"
  "clusterResourceBlacklist:"
  "kind: Deployment"
  "kind: Service"
  "group: monitoring.coreos.com"
  "kind: ServiceMonitor"
  "warn: true"
)

for contract in "${required_project_contracts[@]}"; do
  grep -Fq -- "$contract" "$PROJECT" || {
    echo "AppProject is missing guardrail: $contract" >&2
    exit 1
  }
done

# The array intentionally contains a literal ApplicationSet Go template.
# shellcheck disable=SC2016
required_application_contracts=(
  "missingkey=error"
  "preserveResourcesOnDeletion: true"
  "targetRevision: main"
  'valueFiles:'
  '$values/gitops/environments/{{ .environment }}/values.yaml'
  "allowEmpty: false"
  "prune: true"
  "selfHeal: true"
)

for contract in "${required_application_contracts[@]}"; do
  grep -Fq -- "$contract" "$APPLICATION_SET" || {
    echo "ApplicationSet is missing guardrail: $contract" >&2
    exit 1
  }
done

grep -Eq 'targetRevision:[[:space:]]+(HEAD|master)$' "$APPLICATION_SET" && {
  echo "ApplicationSet uses an unreviewed target revision" >&2
  exit 1
}

# The array intentionally matches shell variable expressions literally.
# shellcheck disable=SC2016
required_bootstrap_contracts=(
  'EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"'
  'ARGOCD_VERSION="v3.4.6"'
  'ARGOCD_MANIFEST_SHA256="752b5a2681f2522fc78ea12ba2d23be44a4523cfa5d9a55cf1907909cc23fc5d"'
  'quay.io/argoproj/argocd@sha256:6e9f4f1d646d9056c8e285495d0c8043b5f553c784181b3522ef324dcefdcc82'
  'ghcr.io/dexidp/dex@sha256:b8469881d3cb3a73001506f0d3aaefecb9c45d2311c1e0f405d8ac538316c59d'
  'public.ecr.aws/docker/library/redis@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba'
  'sha256sum --check --status'
  '--server-side'
  '--field-manager=argocd-bootstrap'
  'kubectl get deployment --namespace argocd --output=name'
  'kubectl rollout status "$deployment"'
  'admin.enabled'
  'owner=helm,name=reliability-demo'
  'kubectl get crd servicemonitors.monitoring.coreos.com'
  "Run 'make monitoring-bootstrap' before 'make argocd-bootstrap'"
)

for contract in "${required_bootstrap_contracts[@]}"; do
  grep -Fq -- "$contract" "$BOOTSTRAP" || {
    echo "Argo CD bootstrap is missing guardrail: $contract" >&2
    exit 1
  }
done

crd_check_line="$(grep -nF 'kubectl get crd servicemonitors.monitoring.coreos.com' "$BOOTSTRAP" | cut -d: -f1)"
manifest_download_line="$(grep -nF 'curl --fail --location --silent --show-error' "$BOOTSTRAP" | cut -d: -f1)"
[[ -n "$crd_check_line" && -n "$manifest_download_line" && "$crd_check_line" -lt "$manifest_download_line" ]] || {
  echo "Argo CD bootstrap must check the ServiceMonitor CRD before downloading or applying Argo CD" >&2
  exit 1
}

grep -Eq 'kubectl apply[^\n]*https?://' "$BOOTSTRAP" && {
  echo "Argo CD bootstrap applies an unverified remote URL" >&2
  exit 1
}

grep -Fq -- '--force-conflicts' "$BOOTSTRAP" && {
  echo "Argo CD bootstrap must not override field ownership conflicts" >&2
  exit 1
}

for environment in dev stage prod; do
  values_file="${ROOT_DIR}/gitops/environments/${environment}/values.yaml"
  rendered_file="${RENDER_DIR}/${environment}.yaml"
  digest="$(awk '$1 == "digest:" {print $2}' "$values_file")"

  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Environment ${environment} is not pinned to an image digest" >&2
    exit 1
  }

  helm template reliability-demo "${ROOT_DIR}/charts/reliability-demo" \
    --namespace "$environment" \
    --values "$values_file" \
    > "$rendered_file"

  grep -Fq "@${digest}" "$rendered_file" || {
    echo "Rendered ${environment} workload does not use its configured digest" >&2
    exit 1
  }

  grep -Fq "kind: ServiceMonitor" "$rendered_file" || {
    echo "Rendered ${environment} release is missing its ServiceMonitor" >&2
    exit 1
  }

  grep -Fq 'observability.reliability-platform.io/monitor: "true"' "$rendered_file" || {
    echo "Rendered ${environment} ServiceMonitor is missing the Prometheus selector label" >&2
    exit 1
  }
done

echo "GitOps manifest guardrail tests passed"
