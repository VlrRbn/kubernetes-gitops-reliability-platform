#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/image-values.sh
source "${SCRIPT_DIR}/image-values.sh"
GITOPS_ROOT="${GITOPS_ROOT:-${ROOT_DIR}/gitops/environments}"
DIGEST_RESOLVER="${DIGEST_RESOLVER:-${SCRIPT_DIR}/resolve-ghcr-digest.sh}"
EXPECTED_REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for environment in dev stage prod; do
  values_file="${GITOPS_ROOT}/${environment}/values.yaml"
  [[ -f "$values_file" ]] || fail "Missing values file for ${environment}"

  repository="$(read_image_field "$values_file" repository)" || fail "Invalid image repository field in ${environment}"
  tag="$(read_image_field "$values_file" tag)" || fail "Invalid image tag field in ${environment}"
  configured_digest="$(read_image_field "$values_file" digest)" || fail "Invalid image digest field in ${environment}"

  [[ "$repository" == "$EXPECTED_REPOSITORY" ]] || fail "Unexpected image repository in ${environment}: $repository"
  [[ "$tag" =~ ^sha-[0-9a-f]{40}$ ]] || fail "Mutable or malformed image tag in ${environment}: $tag"
  [[ "$configured_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Malformed image digest in ${environment}"

  resolved_digest="$("$DIGEST_RESOLVER" "$repository" "$tag")" ||
    fail "Unable to resolve ${environment} image from GHCR"
  [[ "$resolved_digest" == "$configured_digest" ]] ||
    fail "Configured digest does not match GHCR for ${environment}"

  echo "Verified ${environment}: ${repository}:${tag}@${configured_digest}"
done
