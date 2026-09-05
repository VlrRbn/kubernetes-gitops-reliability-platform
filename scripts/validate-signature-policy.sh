#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POLICY="${1:-${ROOT_DIR}/platform/kyverno/policies/verify-signed-images.yaml}"

[[ -f "$POLICY" ]] || {
  echo "FAIL: Signature policy not found: $POLICY" >&2
  exit 1
}

"${SCRIPT_DIR}/validate-admission-policy-boundaries.sh" "$POLICY"
echo "Signature policy contract passed"
