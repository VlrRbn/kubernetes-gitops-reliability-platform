#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KYVERNO_CLI_IMAGE="reg.kyverno.io/kyverno/kyverno-cli@sha256:7224ed05508c24419c3df98114c28ba682ad0a940dcdb7b9fdba0a4b6bf943cf"
POLICY="platform/kyverno/policies/verify-signed-images.yaml"
RESOURCES="tests/kyverno-signatures/resources.yaml"
SIGNED_DIGEST="sha256:671788b8087031cf1bbd9bb0d57c7453ff6ffbee1249a2dc3c99cafefb67c660"
UNSIGNED_DIGEST="sha256:36769bfe4cc94ad7e6bc920d6ef318ed102a56d7c0fcda4ecbe216cd435e2f54"
WRONG_IDENTITY_DIGEST="sha256:0ef6467b187d3ba3284b021df2188d2a32b67358488d4c460f7bdebb108b9e15"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required for signature container coverage tests" >&2
  exit 1
}

REPORT_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE"' EXIT

set +e
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "${ROOT_DIR}:/workspace:ro" \
  --workdir /workspace \
  "$KYVERNO_CLI_IMAGE" \
  apply "$POLICY" \
  --resource "$RESOURCES" \
  --registry \
  --policy-report \
  --output-format json \
  --continue-on-fail >"$REPORT_FILE"
KYVERNO_STATUS=$?
set -e

if ((KYVERNO_STATUS > 1)); then
  echo "Kyverno CLI failed before producing a usable policy report" >&2
  exit "$KYVERNO_STATUS"
fi

python3 - \
  "$REPORT_FILE" \
  "$SIGNED_DIGEST" \
  "$UNSIGNED_DIGEST" \
  "$WRONG_IDENTITY_DIGEST" <<'PY'
import json
import sys

report_path, signed_digest, unsigned_digest, wrong_identity_digest = sys.argv[1:]
with open(report_path, encoding="utf-8") as stream:
    report = json.load(stream)

results = report.get("results", [])


def resource_results(name):
    return [
        result
        for result in results
        if any(resource.get("name") == name for resource in result.get("resources", []))
    ]


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def message_contains(result, *values):
    message = result.get("message", "")
    return all(value in message for value in values)


for name in ("signed-init-image", "signed-ephemeral-image"):
    found = resource_results(name)
    require(found, f"no verification results for {name}")
    require(
        all(result.get("result") == "pass" for result in found),
        f"trusted images in {name} were not all accepted",
    )
    require(
        any(message_contains(result, signed_digest) for result in found),
        f"{name} did not verify the reviewed signed digest",
    )

unsigned_init = resource_results("unsigned-init-image")
require(unsigned_init, "no verification results for unsigned-init-image")
require(
    any(
        result.get("result") == "fail"
        and message_contains(result, unsigned_digest)
        and (
            "no signatures found" in result.get("message", "")
            or "unverified image" in result.get("message", "")
        )
        for result in unsigned_init
    ),
    "unsigned initContainer digest was not rejected",
)
require(
    any(
        result.get("result") == "pass" and message_contains(result, signed_digest)
        for result in unsigned_init
    ),
    "signed app container in unsigned-init-image was not independently accepted",
)

wrong_ephemeral = resource_results("wrong-identity-ephemeral-image")
require(wrong_ephemeral, "no verification results for wrong-identity-ephemeral-image")
require(
    any(
        result.get("result") == "fail"
        and message_contains(result, wrong_identity_digest, "subject mismatch")
        for result in wrong_ephemeral
    ),
    "wrong-identity ephemeralContainer digest was not rejected for subject mismatch",
)
require(
    any(
        result.get("result") == "pass" and message_contains(result, signed_digest)
        for result in wrong_ephemeral
    ),
    "signed app container in wrong-identity-ephemeral-image was not independently accepted",
)

print("Signature coverage passed for containers, initContainers, and ephemeralContainers")
PY
