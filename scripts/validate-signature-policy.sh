#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POLICY="${1:-${ROOT_DIR}/platform/kyverno/policies/verify-signed-images.yaml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_literal() {
  local value="$1"
  local reason="$2"
  grep -Fq -- "$value" "$POLICY" || fail "$reason"
}

[[ -f "$POLICY" ]] || fail "Signature policy not found: $POLICY"

require_literal "  name: verify-signed-images" "Signature policy name must remain stable"
require_literal "    failurePolicy: Fail" "Signature verifier errors must fail closed"
require_literal "    timeoutSeconds: 20" "Signature verification must use the reviewed webhook timeout"
require_literal "                - Pod" "Signature verification must cover Pods"
for namespace in dev stage prod; do
  require_literal "                - ${namespace}" "Signature verification must cover ${namespace}"
done
require_literal '            - "*"' "All workload images must require a trusted signature"
require_literal "          required: true" "Every matching image must be verified"
require_literal "          mutateDigest: false" "Admission must not replace the reviewed GitOps digest"
require_literal "          verifyDigest: true" "Signature verification must require immutable digests"
require_literal "          failureAction: Enforce" "Signature verification must be enforced"
require_literal "            - count: 1" "At least one trusted attestor must verify each image"
require_literal "                    subject: https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main" \
  "Signer subject must be restricted to secure-image.yml on main"
require_literal "                    issuer: https://token.actions.githubusercontent.com" \
  "Signer issuer must be restricted to GitHub Actions OIDC"
require_literal "                      url: https://rekor.sigstore.dev" \
  "Keyless verification must use the public Rekor log"

grep -Eq "subject(RegExp)?:[[:space:]]*[\"']?\\*" "$POLICY" &&
  fail "Wildcard signer subjects are forbidden"
grep -Eq "issuer(RegExp)?:[[:space:]]*[\"']?\\*" "$POLICY" &&
  fail "Wildcard signer issuers are forbidden"
grep -Fq "skipImageReferences:" "$POLICY" &&
  fail "Signature verification exclusions are forbidden"
grep -Fq "cosignOCI11:" "$POLICY" &&
  fail "Unreviewed Cosign OCI compatibility switches are forbidden"

echo "Signature policy contract passed"
