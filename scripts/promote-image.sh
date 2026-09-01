#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/image-values.sh
source "${SCRIPT_DIR}/image-values.sh"
GITOPS_ROOT="${GITOPS_ROOT:-${ROOT_DIR}/gitops/environments}"
DIGEST_RESOLVER="${DIGEST_RESOLVER:-${SCRIPT_DIR}/resolve-ghcr-digest.sh}"
SIGNATURE_VERIFIER="${SIGNATURE_VERIFIER:-${SCRIPT_DIR}/verify-image-signature.sh}"
IMAGE_REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
TARGET_ENV="${1:-}"
IMAGE_COMMIT="${2:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "$TARGET_ENV" =~ ^(dev|stage|prod)$ ]] || fail "Target environment must be dev, stage, or prod"
[[ "$IMAGE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Image commit must be a full lowercase 40-character SHA"
[[ -x "$DIGEST_RESOLVER" ]] || fail "Digest resolver is not executable: $DIGEST_RESOLVER"
[[ -x "$SIGNATURE_VERIFIER" ]] || fail "Signature verifier is not executable: $SIGNATURE_VERIFIER"
command -v helm >/dev/null 2>&1 || fail "Helm is required to validate the promoted values"

for environment in dev stage prod; do
  [[ -f "${GITOPS_ROOT}/${environment}/values.yaml" ]] ||
    fail "Environment values file is missing: ${environment}/values.yaml"
done

IMAGE_TAG="sha-${IMAGE_COMMIT}"
if ! IMAGE_DIGEST="$("$DIGEST_RESOLVER" "$IMAGE_REPOSITORY" "$IMAGE_TAG")"; then
  fail "Unable to resolve the GHCR digest for ${IMAGE_TAG}"
fi
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "Digest resolver returned an invalid digest for ${IMAGE_TAG}"

if ! "$SIGNATURE_VERIFIER" "$IMAGE_REPOSITORY" "$IMAGE_DIGEST"; then
  fail "Trusted signature verification failed for ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
fi

case "$TARGET_ENV" in
  dev)
    SOURCE_ENV=""
    ;;
  stage)
    SOURCE_ENV="dev"
    ;;
  prod)
    SOURCE_ENV="stage"
    ;;
esac

if [[ -n "$SOURCE_ENV" ]]; then
  source_file="${GITOPS_ROOT}/${SOURCE_ENV}/values.yaml"
  source_repository="$(read_image_field "$source_file" repository)" ||
    fail "Invalid image repository field in ${SOURCE_ENV}"
  source_tag="$(read_image_field "$source_file" tag)" ||
    fail "Invalid image tag field in ${SOURCE_ENV}"
  source_digest="$(read_image_field "$source_file" digest)" ||
    fail "Invalid image digest field in ${SOURCE_ENV}"
  [[ "$source_repository" == "$IMAGE_REPOSITORY" &&
    "$source_tag" == "$IMAGE_TAG" &&
    "$source_digest" == "$IMAGE_DIGEST" ]] ||
    fail "${TARGET_ENV} promotion requires the same image to be present in ${SOURCE_ENV}"
fi

target_file="${GITOPS_ROOT}/${TARGET_ENV}/values.yaml"
target_repository="$(read_image_field "$target_file" repository)" ||
  fail "Invalid image repository field in ${TARGET_ENV}"
target_tag="$(read_image_field "$target_file" tag)" ||
  fail "Invalid image tag field in ${TARGET_ENV}"
target_digest="$(read_image_field "$target_file" digest)" ||
  fail "Invalid image digest field in ${TARGET_ENV}"
if [[ "$target_repository" == "$IMAGE_REPOSITORY" &&
  "$target_tag" == "$IMAGE_TAG" &&
  "$target_digest" == "$IMAGE_DIGEST" ]]; then
  fail "${TARGET_ENV} already references ${IMAGE_TAG}@${IMAGE_DIGEST}"
fi

candidate="$(mktemp)"
trap 'rm -f "$candidate"' EXIT

awk \
  -v repository="$IMAGE_REPOSITORY" \
  -v tag="$IMAGE_TAG" \
  -v digest="$IMAGE_DIGEST" '
    $0 == "image:" { in_image = 1; print; next }
    in_image && /^[^[:space:]]/ { in_image = 0 }
    in_image && $1 == "repository:" { print "  repository: " repository; next }
    in_image && $1 == "tag:" { print "  tag: " tag; next }
    in_image && $1 == "digest:" { print "  digest: " digest; next }
    { print }
  ' "$target_file" > "$candidate"

helm lint "${ROOT_DIR}/charts/reliability-demo" \
  --values "$candidate" \
  >/dev/null

mv "$candidate" "$target_file"
trap - EXIT

echo "Promoted ${IMAGE_TAG}@${IMAGE_DIGEST} to ${TARGET_ENV} values"
echo "Review the diff, commit it on a branch, and merge it through a pull request"
