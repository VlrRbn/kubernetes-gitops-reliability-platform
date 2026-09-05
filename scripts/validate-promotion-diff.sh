#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/image-values.sh"

EVENT_NAME="${EVENT_NAME:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
GIT_BIN="${PROMOTION_GIT_BIN:-git}"
EXPECTED_REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ "$EVENT_NAME" != "pull_request" ]]; then
  echo "Promotion diff validation is only required for pull requests"
  exit 0
fi

[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Pull request base SHA must be a full lowercase commit SHA"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Pull request head SHA must be a full lowercase commit SHA"
"$GIT_BIN" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null || fail "Pull request base commit is unavailable"
"$GIT_BIN" cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null || fail "Pull request head commit is unavailable"

DIFF_FILE="${WORK_DIR}/environment-diff.txt"
"$GIT_BIN" diff --name-status "$BASE_SHA" "$HEAD_SHA" -- gitops/environments > "$DIFF_FILE" ||
  fail "Unable to compare pull request environment changes"
mapfile -t changed < "$DIFF_FILE"

promotion_changes=()
for change in "${changed[@]}"; do
  [[ -n "$change" ]] || continue
  status="${change%%$'\t'*}"
  path="${change#*$'\t'}"
  [[ "$status" == "M" ]] || fail "Promotion PR may only modify an existing environment values file: $change"
  [[ "$path" =~ ^gitops/environments/(dev|stage|prod)/values\.yaml$ ]] ||
    fail "Unreviewed file changed inside the managed environment scope: $path"
  promotion_changes+=("$path")
done

if [[ "${#promotion_changes[@]}" -eq 0 ]]; then
  echo "No environment promotion change detected"
  exit 0
fi
[[ "${#promotion_changes[@]}" -eq 1 ]] || fail "A pull request may promote exactly one environment"

target_path="${promotion_changes[0]}"
target_environment="${target_path#gitops/environments/}"
target_environment="${target_environment%/values.yaml}"

for environment in dev stage prod; do
  for revision in base head; do
    if [[ "$revision" == "base" ]]; then
      sha="$BASE_SHA"
    else
      sha="$HEAD_SHA"
    fi
    output="${WORK_DIR}/${revision}-${environment}.yaml"
    "$GIT_BIN" show "${sha}:gitops/environments/${environment}/values.yaml" > "$output" 2>/dev/null ||
      fail "Unable to read ${environment} values from pull request ${revision} revision"
  done
done

mask_image_identity() {
  awk '
    $0 == "image:" { in_image = 1; print; next }
    in_image && /^[^[:space:]]/ { in_image = 0 }
    in_image && ($1 == "repository:" || $1 == "tag:" || $1 == "digest:") {
      print "  " $1 " <reviewed-promotion-value>"
      next
    }
    { print }
  ' "$1"
}

mask_image_identity "${WORK_DIR}/base-${target_environment}.yaml" > "${WORK_DIR}/base-masked.yaml"
mask_image_identity "${WORK_DIR}/head-${target_environment}.yaml" > "${WORK_DIR}/head-masked.yaml"
cmp --silent "${WORK_DIR}/base-masked.yaml" "${WORK_DIR}/head-masked.yaml" ||
  fail "Promotion PR may change only image repository, tag, and digest"

read_identity() {
  local values_file="$1"
  local repository tag digest

  repository="$(read_image_field "$values_file" repository)" || return 1
  tag="$(read_image_field "$values_file" tag)" || return 1
  digest="$(read_image_field "$values_file" digest)" || return 1
  [[ "$repository" == "$EXPECTED_REPOSITORY" ]] || return 1
  [[ "$tag" =~ ^sha-[0-9a-f]{40}$ ]] || return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s\t%s\t%s\n' "$repository" "$tag" "$digest"
}

base_identity="$(read_identity "${WORK_DIR}/base-${target_environment}.yaml")" ||
  fail "Base ${target_environment} image identity is malformed"
target_identity="$(read_identity "${WORK_DIR}/head-${target_environment}.yaml")" ||
  fail "Promoted ${target_environment} image identity is malformed"
[[ "$target_identity" != "$base_identity" ]] || fail "Promotion PR does not change the target image identity"

case "$target_environment" in
  dev)
    source_environment=""
    ;;
  stage)
    source_environment="dev"
    ;;
  prod)
    source_environment="stage"
    ;;
esac

if [[ -n "$source_environment" ]]; then
  source_identity="$(read_identity "${WORK_DIR}/head-${source_environment}.yaml")" ||
    fail "Source ${source_environment} image identity is malformed"
  [[ "$target_identity" == "$source_identity" ]] ||
    fail "${target_environment} promotion requires the same image to be present in ${source_environment}"
fi

echo "Promotion diff contract passed for ${target_environment}"
