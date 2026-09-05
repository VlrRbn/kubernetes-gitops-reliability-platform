#!/usr/bin/env bash
set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

[[ "$#" -gt 0 ]] || {
  echo "FAIL: At least one temporary Audit policy name is required" >&2
  exit 1
}
command -v "$KUBECTL_BIN" >/dev/null 2>&1 || {
  echo "FAIL: kubectl is required to clean temporary Audit policies" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required to inspect temporary Audit policies" >&2
  exit 1
}

cleanup_failed=false
for policy_name in "$@"; do
  policy_json="$($KUBECTL_BIN get clusterpolicy "$policy_name" --ignore-not-found --output=json)" || {
    echo "CRITICAL: unable to inspect policy during cleanup: $policy_name" >&2
    cleanup_failed=true
    continue
  }
  [[ -n "$policy_json" ]] || continue

  if ! jq --exit-status '
    [
      .spec.rules[]?
      | if .validate? then .validate.failureAction
        else .verifyImages[]?.failureAction
        end
    ] as $actions
    | ($actions | length) > 0
      and all($actions[]; . == "Audit")
  ' >/dev/null <<< "$policy_json"; then
    echo "CRITICAL: retaining non-Audit policy after interrupted bootstrap: $policy_name" >&2
    cleanup_failed=true
    continue
  fi

  if ! "$KUBECTL_BIN" delete clusterpolicy "$policy_name" >/dev/null; then
    echo "CRITICAL: failed to remove temporary Audit policy: $policy_name" >&2
    cleanup_failed=true
    continue
  fi
  remaining="$($KUBECTL_BIN get clusterpolicy "$policy_name" --ignore-not-found --output=json)" || {
    echo "CRITICAL: unable to confirm Audit policy removal: $policy_name" >&2
    cleanup_failed=true
    continue
  }
  if [[ -n "$remaining" ]]; then
    echo "CRITICAL: temporary Audit policy still exists: $policy_name" >&2
    cleanup_failed=true
  fi
done

[[ "$cleanup_failed" == false ]]
