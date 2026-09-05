#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-gitops-boundaries.sh"
PROJECT="${ROOT_DIR}/platform/argocd/project.yaml"
APPLICATION_SET="${ROOT_DIR}/platform/argocd/applicationset.yaml"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_rejected() {
  local name="$1"
  local project="$2"
  local application_set="$3"
  local expected_reason="$4"
  local output

  echo "Testing negative GitOps boundary case: $name"
  if output="$("$VALIDATOR" "$project" "$application_set" 2>&1)"; then
    echo "FAIL: GitOps validator accepted negative case: $name" >&2
    exit 1
  fi
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: GitOps validator rejected '$name' for the wrong reason" >&2
    echo "$output" >&2
    exit 1
  }
  echo "PASS: $name"
}

fresh_case() {
  local name="$1"
  local candidate="${TEST_DIR}/${name}"

  mkdir -p "$candidate"
  cp "$PROJECT" "${candidate}/project.yaml"
  cp "$APPLICATION_SET" "${candidate}/applicationset.yaml"
  printf '%s\n' "$candidate"
}

"$VALIDATOR" "$PROJECT" "$APPLICATION_SET"

candidate="$(fresh_case wildcard-repository)"
sed -i '/^  sourceRepos:$/a\    - "*"' "${candidate}/project.yaml"
expect_rejected \
  "wildcard source repository" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "AppProject must allow exactly the reviewed repository"

candidate="$(fresh_case wildcard-destination)"
sed -i '/^  destinations:$/a\    - namespace: "*"\n      server: https://kubernetes.default.svc' \
  "${candidate}/project.yaml"
expect_rejected \
  "wildcard destination namespace" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "AppProject destinations must contain exactly dev, stage, and prod"

candidate="$(fresh_case wildcard-resource)"
sed -i '/^  namespaceResourceWhitelist:$/a\    - group: "*"\n      kind: "*"' \
  "${candidate}/project.yaml"
expect_rejected \
  "wildcard namespace resource" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "AppProject may manage only Deployment, Service, and ServiceMonitor resources"

candidate="$(fresh_case unreviewed-project-setting)"
sed -i '/^  orphanedResources:$/i\  roles: []' "${candidate}/project.yaml"
expect_rejected \
  "additional AppProject setting" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "AppProject contains unreviewed boundary settings"

candidate="$(fresh_case extra-environment)"
sed -i '/          - environment: prod/a\          - environment: qa' \
  "${candidate}/applicationset.yaml"
expect_rejected \
  "additional generated environment" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "ApplicationSet generator must contain exactly dev, stage, and prod"

candidate="$(fresh_case unreviewed-revision)"
sed -i '0,/targetRevision: main/s//targetRevision: feature\/unreviewed/' \
  "${candidate}/applicationset.yaml"
expect_rejected \
  "unreviewed chart revision" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "ApplicationSet sources must remain pinned to the reviewed repository paths on main"

candidate="$(fresh_case extra-source)"
sed -i '/      destination:$/i\        - repoURL: https://example.invalid/unreviewed.git\n          targetRevision: main\n          path: chart' \
  "${candidate}/applicationset.yaml"
expect_rejected \
  "additional application source" \
  "${candidate}/project.yaml" \
  "${candidate}/applicationset.yaml" \
  "ApplicationSet must use exactly the reviewed chart and values sources"

echo "GitOps structural boundary positive and negative tests passed"
