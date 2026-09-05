#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-kyverno-audit-reports.sh"
TEST_DIR="$(mktemp -d)"
EXPECTED="${TEST_DIR}/expected.json"
REPORTS="${TEST_DIR}/reports.json"
POLICIES=(require-immutable-images verify-signed-images)
MINIMUM_RESULT_EPOCH=100
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$EXPECTED" <<'JSON'
{"items":[
  {"kind":"Deployment","metadata":{"namespace":"dev","name":"reliability-demo","uid":"deployment-uid"}},
  {"kind":"Pod","metadata":{"namespace":"dev","name":"reliability-demo-example","uid":"pod-uid"}}
]}
JSON

write_reports() {
  local deployment_result="$1"
  local pod_result="$2"
  local include_pod_signature="${3:-true}"
  local result_epoch="${4:-200}"
  local pod_uid="${5:-pod-uid}"

  python3 - "$REPORTS" "$deployment_result" "$pod_result" "$include_pod_signature" "$result_epoch" "$pod_uid" <<'PYTHON'
import json
import sys

path, deployment_result, pod_result, include_pod_signature, result_epoch, pod_uid = sys.argv[1:]
result_epoch = int(result_epoch)


def report(kind, name, uid, results):
    return {
        "metadata": {"namespace": "dev"},
        "scope": {"kind": kind, "name": name, "uid": uid},
        "results": results,
    }


def result(policy, outcome):
    return {
        "policy": policy,
        "rule": "reviewed-rule",
        "result": outcome,
        "message": f"synthetic {outcome} result",
        "timestamp": {"seconds": result_epoch},
    }


pod_results = [result("require-immutable-images", pod_result)]
if include_pod_signature == "true":
    pod_results.append(result("verify-signed-images", pod_result))

document = {
    "items": [
        report(
            "Deployment",
            "reliability-demo",
            "deployment-uid",
            [
                result("require-immutable-images", deployment_result),
                result("verify-signed-images", deployment_result),
            ],
        ),
        report("Pod", "reliability-demo-example", pod_uid, pod_results),
    ]
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(document, stream)
PYTHON
}

expect_rejected() {
  local name="$1"
  local expected_reason="$2"
  local expected_status="$3"
  local output status

  echo "Testing negative Kyverno audit case: $name"
  set +e
  output="$("$VALIDATOR" "$EXPECTED" "$REPORTS" "$MINIMUM_RESULT_EPOCH" "${POLICIES[@]}" 2>&1)"
  status="$?"
  set -e
  [[ "$status" -eq "$expected_status" ]] || {
    echo "FAIL: unexpected validator status for $name: $status" >&2
    exit 1
  }
  grep -Fq -- "$expected_reason" <<< "$output" || {
    echo "FAIL: validator rejected '$name' for the wrong reason" >&2
    echo "$output" >&2
    exit 1
  }
  echo "PASS: $name"
}

write_reports pass pass
"$VALIDATOR" "$EXPECTED" "$REPORTS" "$MINIMUM_RESULT_EPOCH" "${POLICIES[@]}" >/dev/null
echo "PASS: complete passing audit coverage"

for outcome in fail warn error skip; do
  write_reports pass "$outcome"
  expect_rejected \
    "${outcome} audit result" \
    "verify-signed-images/reviewed-rule: ${outcome}" \
    1
done

write_reports pass pass false
expect_rejected \
  "missing policy result for one workload" \
  "INCOMPLETE: dev/Pod/reliability-demo-example: no result for verify-signed-images" \
  2

write_reports pass pass true 99
expect_rejected \
  "stale passing audit results" \
  "INCOMPLETE: dev/Pod/reliability-demo-example: no result for verify-signed-images" \
  2

write_reports pass pass true 200 stale-pod-uid
expect_rejected \
  "passing report for a replaced workload UID" \
  "INCOMPLETE: dev/Pod/reliability-demo-example: no result for verify-signed-images" \
  2

echo "Kyverno audit report positive and negative tests passed"
