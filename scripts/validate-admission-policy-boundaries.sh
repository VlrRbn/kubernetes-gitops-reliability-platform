#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="$(mktemp -d)"
RENDERED_FILE="${WORK_DIR}/rendered-policies.yaml"
trap 'rm -rf "$WORK_DIR"' EXIT

for command in helm python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "FAIL: ${command} is required for structural admission policy validation" >&2
    exit 1
  }
done

if [[ "$#" -eq 0 ]]; then
  set -- "${ROOT_DIR}/platform/kyverno"
fi

mkdir -p "${WORK_DIR}/files" "${WORK_DIR}/templates"
printf '%s\n' \
  'apiVersion: v2' \
  'name: admission-policy-validator' \
  'version: 0.1.0' \
  > "${WORK_DIR}/Chart.yaml"
# These are literal Helm template expressions, not shell expansions.
# shellcheck disable=SC2016
printf '%s\n' \
  '{{- range $path, $_ := .Files.Glob "files/*" }}' \
  '---' \
  '{{ $.Files.Get $path | fromYaml | toJson }}' \
  '{{- end }}' \
  > "${WORK_DIR}/templates/policies.yaml"

policy_files=()
require_complete_scope=false
for input in "$@"; do
  if [[ -d "$input" ]]; then
    require_complete_scope=true
    while IFS= read -r policy_file; do
      policy_files+=("$policy_file")
    done < <(find "$input" -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort)
  elif [[ -f "$input" ]]; then
    policy_files+=("$input")
  else
    echo "FAIL: Admission policy input not found: $input" >&2
    exit 1
  fi
done

[[ "${#policy_files[@]}" -gt 0 ]] || {
  echo "FAIL: No admission policy YAML files were provided" >&2
  exit 1
}

for index in "${!policy_files[@]}"; do
  if grep -Eq '^---[[:space:]]*$' "${policy_files[$index]}"; then
    echo "FAIL: Multiple YAML documents are forbidden in managed admission policy files" >&2
    exit 1
  fi
  cp "${policy_files[$index]}" "${WORK_DIR}/files/${index}.yaml"
done

if ! helm template admission-policy-validator "$WORK_DIR" > "$RENDERED_FILE"; then
  echo "FAIL: Admission policy YAML could not be parsed structurally" >&2
  exit 1
fi

python3 - "$RENDERED_FILE" "$require_complete_scope" <<'PYTHON'
import json
import sys

MANAGED_NAMESPACES = {"dev", "stage", "prod"}
MANAGED_POLICIES = {
    "require-immutable-images",
    "require-restricted-workloads",
    "verify-signed-images",
}
SIGNATURE_POLICY = "verify-signed-images"
EXPECTED_SUBJECT = "https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/.github/workflows/secure-image.yml@refs/heads/main"
EXPECTED_ISSUER = "https://token.actions.githubusercontent.com"
EXPECTED_REKOR = "https://rekor.sigstore.dev"


def fail(reason):
    print(f"FAIL: {reason}", file=sys.stderr)
    raise SystemExit(1)


def load_documents(path):
    documents = []
    with open(path, encoding="utf-8") as rendered:
        for line in rendered:
            line = line.strip()
            if line.startswith("{"):
                try:
                    documents.append(json.loads(line))
                except json.JSONDecodeError as error:
                    fail(f"Rendered admission policy JSON is invalid: {error}")
    return documents


def match_resources(rule):
    rule_name = rule.get("name", "<unnamed>")
    match = rule.get("match")
    if not isinstance(match, dict):
        fail(f"Policy rule {rule_name} must define match.any")
    if set(match) != {"any"}:
        fail(f"Policy rule {rule_name} must use only the reviewed match.any scope")
    entries = match.get("any")
    if not isinstance(entries, list) or len(entries) != 1:
        fail(f"Policy rule {rule_name} must use exactly one reviewed match.any entry")
    entry = entries[0]
    if not isinstance(entry, dict) or set(entry) != {"resources"} or not isinstance(entry.get("resources"), dict):
        fail(f"Policy rule {rule_name} must use only the reviewed resource matcher")
    resources = entry["resources"]
    if set(resources) != {"kinds", "namespaces"}:
        fail(f"Policy rule {rule_name} must use only reviewed kinds and namespaces")
    return [resources]


def validate_common_policy(policy):
    name = policy.get("metadata", {}).get("name")
    if name not in MANAGED_POLICIES:
        fail(f"Unexpected managed admission policy: {name or '<unnamed>'}")

    spec = policy.get("spec")
    if not isinstance(spec, dict):
        fail(f"{name} must define a policy spec")
    if set(spec) != {"background", "rules", "webhookConfiguration"}:
        fail(f"{name} contains unreviewed policy-level settings")
    if spec.get("background") is not True:
        fail(f"{name} background coverage must remain enabled")

    failure_policy = spec.get("webhookConfiguration", {}).get("failurePolicy")
    reason = "Signature verifier errors must fail closed" if name == SIGNATURE_POLICY else f"{name} webhook errors must fail closed"
    if failure_policy != "Fail":
        fail(reason)
    expected_webhook_keys = {"failurePolicy", "timeoutSeconds"} if name == SIGNATURE_POLICY else {"failurePolicy"}
    if set(spec.get("webhookConfiguration", {})) != expected_webhook_keys:
        fail(f"{name} contains unreviewed webhook settings")

    annotation = policy.get("metadata", {}).get("annotations", {}).get("pod-policies.kyverno.io/autogen-controllers")
    if isinstance(annotation, str) and annotation.strip().lower() == "none":
        fail(f"{name} must not disable Kyverno autogen coverage")

    rules = spec.get("rules")
    if not isinstance(rules, list) or not rules:
        fail(f"{name} must define admission rules")

    for rule in rules:
        rule_name = rule.get("name", "<unnamed>")
        if "exclude" in rule:
            fail("Rule-level exclusions are forbidden for managed admission policies")
        expected_rule_keys = {"name", "match", "verifyImages"} if name == SIGNATURE_POLICY else {"name", "match", "validate"}
        if set(rule) != expected_rule_keys:
            fail(f"{name}/{rule_name} contains unreviewed rule settings")

        resources = match_resources(rule)
        kinds = {kind for resource in resources for kind in resource.get("kinds", [])}
        namespaces = {namespace for resource in resources for namespace in resource.get("namespaces", [])}
        if kinds != {"Pod"}:
            fail(f"{name}/{rule_name} must cover only Pods")
        if namespaces != MANAGED_NAMESPACES:
            fail(f"{name}/{rule_name} must cover exactly dev, stage, and prod")

        validation = rule.get("validate")
        verifications = rule.get("verifyImages")
        if isinstance(validation, dict):
            if validation.get("failureAction") != "Enforce":
                fail(f"{name}/{rule_name} must enforce validation failures")
        elif isinstance(verifications, list) and verifications:
            for verification in verifications:
                reason = "Signature verification must be enforced" if name == SIGNATURE_POLICY else f"{name}/{rule_name} must enforce image verification failures"
                if verification.get("failureAction") != "Enforce":
                    fail(reason)
        else:
            fail(f"{name}/{rule_name} must define validate or verifyImages enforcement")


def validate_signature_policy(policy):
    spec = policy["spec"]
    if spec.get("webhookConfiguration", {}).get("timeoutSeconds") != 20:
        fail("Signature verification must use the reviewed webhook timeout")

    rules = spec["rules"]
    if len(rules) != 1:
        fail("Signature policy must contain exactly one reviewed rule")
    verification_entries = rules[0].get("verifyImages")
    if not isinstance(verification_entries, list) or len(verification_entries) != 1:
        fail("Signature policy must contain exactly one reviewed image verification entry")
    verification = verification_entries[0]

    if "skipImageReferences" in verification:
        fail("Signature verification exclusions are forbidden")
    if "cosignOCI11" in verification:
        fail("Unreviewed Cosign OCI compatibility switches are forbidden")

    expected_verification_keys = {
        "attestors",
        "failureAction",
        "imageReferences",
        "mutateDigest",
        "required",
        "verifyDigest",
    }
    if set(verification) != expected_verification_keys:
        fail("Signature policy contains unreviewed image verification settings")

    if verification.get("imageReferences") != ["*"]:
        fail("All workload images must require a trusted signature")
    if verification.get("required") is not True:
        fail("Every matching image must be verified")
    if verification.get("mutateDigest") is not False:
        fail("Admission must not replace the reviewed GitOps digest")
    if verification.get("verifyDigest") is not True:
        fail("Signature verification must require immutable digests")
    attestors = verification.get("attestors")
    if not isinstance(attestors, list) or len(attestors) != 1:
        fail("Signature verification must use exactly one reviewed attestor set")
    attestor = attestors[0]
    if set(attestor) != {"count", "entries"}:
        fail("Signature verification contains unreviewed attestor settings")
    if attestor.get("count") != 1:
        fail("At least one trusted attestor must verify each image")
    entries = attestor.get("entries")
    if not isinstance(entries, list) or len(entries) != 1:
        fail("Signature verification must use exactly one reviewed keyless identity")
    keyless = entries[0].get("keyless")
    if not isinstance(keyless, dict):
        fail("Signature verification must use exactly one reviewed keyless identity")
    if keyless.get("subject") != EXPECTED_SUBJECT:
        fail("Signer subject must be restricted to secure-image.yml on main")
    if keyless.get("issuer") != EXPECTED_ISSUER:
        fail("Signer issuer must be restricted to GitHub Actions OIDC")
    if keyless.get("rekor", {}).get("url") != EXPECTED_REKOR:
        fail("Keyless verification must use the public Rekor log")
    if set(keyless) != {"subject", "issuer", "rekor"}:
        fail("Unreviewed keyless identity options are forbidden")


documents = load_documents(sys.argv[1])
if not documents:
    fail("No rendered admission policy documents were found")

cluster_policy_count = 0
cluster_policy_names = set()
for document in documents:
    if "Error" in document:
        fail(f"Admission policy YAML could not be parsed structurally: {document['Error']}")
    kind = document.get("kind")
    if kind == "PolicyException":
        fail("PolicyException bypasses are forbidden in the managed admission policy scope")
    if kind != "ClusterPolicy":
        fail(f"Only reviewed ClusterPolicy resources are allowed in the managed admission policy scope: {kind or '<missing>'}")
    cluster_policy_count += 1
    cluster_policy_names.add(document.get("metadata", {}).get("name"))
    validate_common_policy(document)
    if document.get("metadata", {}).get("name") == SIGNATURE_POLICY:
        validate_signature_policy(document)

if cluster_policy_count == 0:
    fail("No managed ClusterPolicy documents were provided")
if sys.argv[2] == "true" and (cluster_policy_count != 3 or cluster_policy_names != MANAGED_POLICIES):
    fail("Managed admission policy scope must contain exactly the three reviewed ClusterPolicies")

print("Admission policy boundary contract passed")
PYTHON
