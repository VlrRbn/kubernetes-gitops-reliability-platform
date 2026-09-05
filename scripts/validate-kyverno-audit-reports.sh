#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_RESOURCES_FILE="${1:-}"
REPORTS_FILE="${2:-}"
MINIMUM_RESULT_EPOCH="${3:-}"
shift 3 || true

[[ -f "$EXPECTED_RESOURCES_FILE" ]] || {
  echo "FAIL: Expected workload snapshot is missing" >&2
  exit 1
}
[[ -f "$REPORTS_FILE" ]] || {
  echo "FAIL: Kyverno policy report snapshot is missing" >&2
  exit 1
}
[[ "$MINIMUM_RESULT_EPOCH" =~ ^[0-9]+$ ]] || {
  echo "FAIL: Audit result freshness boundary must be a Unix epoch" >&2
  exit 1
}
[[ "$#" -gt 0 ]] || {
  echo "FAIL: At least one audited policy name is required" >&2
  exit 1
}

python3 - "$EXPECTED_RESOURCES_FILE" "$REPORTS_FILE" "$MINIMUM_RESULT_EPOCH" "$@" <<'PYTHON'
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


expected = load(sys.argv[1])
reports = load(sys.argv[2])
minimum_result_epoch = int(sys.argv[3])
policies = set(sys.argv[4:])

resources = {
    (
        item.get("metadata", {}).get("namespace", ""),
        item.get("kind", ""),
        item.get("metadata", {}).get("name", ""),
        item.get("metadata", {}).get("uid", ""),
    )
    for item in expected.get("items", [])
}
if not resources or any(not all(resource) for resource in resources):
    print("FAIL: Expected workload snapshot is empty or malformed", file=sys.stderr)
    raise SystemExit(1)

observed = {}
for report in reports.get("items", []):
    resource = (
        report.get("metadata", {}).get("namespace", ""),
        report.get("scope", {}).get("kind", ""),
        report.get("scope", {}).get("name", ""),
        report.get("scope", {}).get("uid", ""),
    )
    for result in report.get("results", []):
        policy = result.get("policy")
        timestamp = result.get("timestamp", {}).get("seconds")
        if (
            resource in resources
            and policy in policies
            and isinstance(timestamp, int)
            and timestamp >= minimum_result_epoch
        ):
            observed.setdefault((resource, policy), []).append(result)

missing = [
    (resource, policy)
    for resource in sorted(resources)
    for policy in sorted(policies)
    if (resource, policy) not in observed
]
if missing:
    for (namespace, kind, name, _uid), policy in missing:
        print(f"INCOMPLETE: {namespace}/{kind}/{name}: no result for {policy}", file=sys.stderr)
    raise SystemExit(2)

unsafe = []
for (resource, policy), results in observed.items():
    for result in results:
        if result.get("result") != "pass":
            unsafe.append((resource, policy, result))

if unsafe:
    for (namespace, kind, name, _uid), policy, result in sorted(
        unsafe,
        key=lambda entry: (entry[0], entry[1], entry[2].get("rule", "")),
    ):
        outcome = result.get("result", "<missing>")
        rule = result.get("rule", "<unknown>")
        message = result.get("message", "no diagnostic message")
        print(
            f"FAIL: {namespace}/{kind}/{name}: {policy}/{rule}: {outcome}: {message}",
            file=sys.stderr,
        )
    raise SystemExit(1)

print("Kyverno audit report coverage is complete and clean")
PYTHON
