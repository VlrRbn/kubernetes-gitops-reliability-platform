#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KYVERNO_CLI_IMAGE="reg.kyverno.io/kyverno/kyverno-cli@sha256:7224ed05508c24419c3df98114c28ba682ad0a940dcdb7b9fdba0a4b6bf943cf"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required for admission policy tests" >&2
  exit 1
}

echo "NOTE: RESULT=Pass means the policy behavior matched the test expectation."
echo "Negative fixtures are expected to be rejected by the policy."

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "${ROOT_DIR}:/workspace:ro" \
  --workdir /workspace/tests/kyverno \
  "$KYVERNO_CLI_IMAGE" \
  test .

echo "Admission policy positive and negative tests passed"
