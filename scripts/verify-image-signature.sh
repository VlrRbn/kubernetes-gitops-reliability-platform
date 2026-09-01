#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_REPOSITORY="ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform"
EXPECTED_IDENTITY="https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main"
EXPECTED_ISSUER="https://token.actions.githubusercontent.com"
EXPECTED_COSIGN_VERSION="v2.6.5"
COSIGN_BIN="${COSIGN_BIN:-cosign}"
IMAGE_REPOSITORY="${1:-}"
IMAGE_DIGEST="${2:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "$IMAGE_REPOSITORY" == "$EXPECTED_REPOSITORY" ]] ||
  fail "Signature verification requires the trusted image repository"
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "Signature verification requires a valid sha256 digest"
command -v "$COSIGN_BIN" >/dev/null 2>&1 ||
  fail "Cosign verifier is not executable: $COSIGN_BIN"
command -v jq >/dev/null 2>&1 || fail "jq is required to validate Cosign output"

cosign_version="$("$COSIGN_BIN" version 2>&1)" ||
  fail "Unable to determine the Cosign verifier version"
grep -Eq '^GitVersion:[[:space:]]+v2\.6\.5[[:space:]]*$' <<< "$cosign_version" ||
  fail "Cosign verifier must be the reviewed version ${EXPECTED_COSIGN_VERSION}"

verification_file="$(mktemp)"
trap 'rm -f "$verification_file"' EXIT

if ! "$COSIGN_BIN" verify \
  --certificate-identity "$EXPECTED_IDENTITY" \
  --certificate-oidc-issuer "$EXPECTED_ISSUER" \
  "${IMAGE_REPOSITORY}@${IMAGE_DIGEST}" \
  > "$verification_file"; then
  fail "Trusted signature verification failed for ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
fi

jq --exit-status 'type == "array" and length > 0' "$verification_file" >/dev/null ||
  fail "Cosign returned no trusted signatures for ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"

echo "Verified trusted signature: ${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
