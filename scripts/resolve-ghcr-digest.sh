#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_REPOSITORY="${1:-}"
IMAGE_TAG="${2:-}"
HEADERS_FILE="$(mktemp)"
trap 'rm -f "$HEADERS_FILE"' EXIT

[[ "$IMAGE_REPOSITORY" =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._/-]+$ ]] || {
  echo "Invalid GHCR repository: $IMAGE_REPOSITORY" >&2
  exit 1
}
[[ "$IMAGE_TAG" =~ ^sha-[0-9a-f]{40}$ ]] || {
  echo "Image tag must contain a full commit SHA: $IMAGE_TAG" >&2
  exit 1
}

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

repository_path="${IMAGE_REPOSITORY#ghcr.io/}"
token="$(
  curl --fail --silent --show-error --get \
    --data-urlencode 'service=ghcr.io' \
    --data-urlencode "scope=repository:${repository_path}:pull" \
    'https://ghcr.io/token' |
    jq --exit-status --raw-output '.token'
)"

curl --fail --silent --show-error \
  --dump-header "$HEADERS_FILE" \
  --output /dev/null \
  --header "Authorization: Bearer ${token}" \
  --header 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' \
  "https://ghcr.io/v2/${repository_path}/manifests/${IMAGE_TAG}"

digest="$(
  awk 'tolower($1) == "docker-content-digest:" {gsub("\\r", "", $2); print $2}' "$HEADERS_FILE" |
    tail -n 1
)"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "GHCR did not return a valid digest for ${IMAGE_REPOSITORY}:${IMAGE_TAG}" >&2
  exit 1
}

printf '%s\n' "$digest"
