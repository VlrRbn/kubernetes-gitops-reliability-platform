#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${1:-${ROOT_DIR}/platform/argocd/project.yaml}"
APPLICATION_SET="${2:-${ROOT_DIR}/platform/argocd/applicationset.yaml}"
WORK_DIR="$(mktemp -d)"
RENDERED="${WORK_DIR}/rendered.json"
trap 'rm -rf "$WORK_DIR"' EXIT

for input in "$PROJECT" "$APPLICATION_SET"; do
  [[ -f "$input" ]] || {
    echo "FAIL: GitOps boundary manifest is missing: $input" >&2
    exit 1
  }
done
for command in helm python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "FAIL: ${command} is required for structural GitOps validation" >&2
    exit 1
  }
done

mkdir -p "${WORK_DIR}/files" "${WORK_DIR}/templates"
printf '%s\n' \
  'apiVersion: v2' \
  'name: gitops-boundary-validator' \
  'version: 0.1.0' \
  > "${WORK_DIR}/Chart.yaml"
cp "$PROJECT" "${WORK_DIR}/files/project.yaml"
cp "$APPLICATION_SET" "${WORK_DIR}/files/applicationset.yaml"
# These are literal Helm template expressions, not shell expansions.
# shellcheck disable=SC2016
printf '%s\n' \
  '{{- dict "project" (.Files.Get "files/project.yaml" | fromYaml) "applicationSet" (.Files.Get "files/applicationset.yaml" | fromYaml) | toJson }}' \
  > "${WORK_DIR}/templates/manifests.yaml"

if ! helm template gitops-boundary-validator "$WORK_DIR" > "$RENDERED"; then
  echo "FAIL: GitOps boundary YAML could not be parsed structurally" >&2
  exit 1
fi

python3 - "$RENDERED" <<'PYTHON'
import json
import sys


REPOSITORY = "https://github.com/VlrRbn/kubernetes-gitops-reliability-platform.git"
ENVIRONMENTS = {"dev", "stage", "prod"}


def fail(reason):
    print(f"FAIL: {reason}", file=sys.stderr)
    raise SystemExit(1)


documents = None
with open(sys.argv[1], encoding="utf-8") as rendered:
    for line in rendered:
        line = line.strip()
        if line.startswith("{"):
            documents = json.loads(line)
            break
if not isinstance(documents, dict):
    fail("GitOps boundary YAML could not be parsed structurally")

project = documents.get("project")
application_set = documents.get("applicationSet")
if not isinstance(project, dict) or "Error" in project:
    fail("AppProject YAML could not be parsed structurally")
if not isinstance(application_set, dict) or "Error" in application_set:
    fail("ApplicationSet YAML could not be parsed structurally")

if project.get("apiVersion") != "argoproj.io/v1alpha1" or project.get("kind") != "AppProject":
    fail("Reviewed AppProject identity must not change")
metadata = project.get("metadata", {})
if metadata.get("name") != "reliability-platform" or metadata.get("namespace") != "argocd":
    fail("Reviewed AppProject identity must not change")
spec = project.get("spec")
if not isinstance(spec, dict):
    fail("AppProject spec is missing")
if set(spec) != {
    "description",
    "sourceRepos",
    "destinations",
    "clusterResourceBlacklist",
    "namespaceResourceWhitelist",
    "orphanedResources",
}:
    fail("AppProject contains unreviewed boundary settings")
if spec.get("sourceRepos") != [REPOSITORY]:
    fail("AppProject must allow exactly the reviewed repository")

destinations = spec.get("destinations")
expected_destinations = {
    (environment, "https://kubernetes.default.svc") for environment in ENVIRONMENTS
}
if not isinstance(destinations, list) or {
    (entry.get("namespace"), entry.get("server"))
    for entry in destinations
    if isinstance(entry, dict)
} != expected_destinations or len(destinations) != 3:
    fail("AppProject destinations must contain exactly dev, stage, and prod")

if spec.get("clusterResourceBlacklist") != [{"group": "*", "kind": "*"}]:
    fail("AppProject must deny every cluster-scoped resource")
expected_resources = {
    ("apps", "Deployment"),
    ("", "Service"),
    ("monitoring.coreos.com", "ServiceMonitor"),
}
resources = spec.get("namespaceResourceWhitelist")
if not isinstance(resources, list) or {
    (entry.get("group"), entry.get("kind"))
    for entry in resources
    if isinstance(entry, dict)
} != expected_resources or len(resources) != 3:
    fail("AppProject may manage only Deployment, Service, and ServiceMonitor resources")
if spec.get("orphanedResources") != {"warn": True}:
    fail("AppProject orphaned resource warnings must remain enabled")

if application_set.get("apiVersion") != "argoproj.io/v1alpha1" or application_set.get("kind") != "ApplicationSet":
    fail("Reviewed ApplicationSet identity must not change")
metadata = application_set.get("metadata", {})
if metadata.get("name") != "reliability-demo-environments" or metadata.get("namespace") != "argocd":
    fail("Reviewed ApplicationSet identity must not change")
spec = application_set.get("spec")
if not isinstance(spec, dict):
    fail("ApplicationSet spec is missing")
if set(spec) != {"goTemplate", "goTemplateOptions", "generators", "syncPolicy", "template"}:
    fail("ApplicationSet contains unreviewed top-level settings")
if spec.get("goTemplate") is not True or spec.get("goTemplateOptions") != ["missingkey=error"]:
    fail("ApplicationSet must fail on missing template keys")
if spec.get("syncPolicy") != {"preserveResourcesOnDeletion": True}:
    fail("ApplicationSet deletion must preserve generated workloads")

generators = spec.get("generators")
if not isinstance(generators, list) or len(generators) != 1:
    fail("ApplicationSet must use exactly one reviewed environment generator")
elements = generators[0].get("list", {}).get("elements") if isinstance(generators[0], dict) else None
if not isinstance(elements, list) or {
    element.get("environment") for element in elements if isinstance(element, dict)
} != ENVIRONMENTS or len(elements) != 3 or any(set(element) != {"environment"} for element in elements):
    fail("ApplicationSet generator must contain exactly dev, stage, and prod")

template = spec.get("template")
if not isinstance(template, dict):
    fail("ApplicationSet template is missing")
if set(template) != {"metadata", "spec"}:
    fail("ApplicationSet template contains unreviewed settings")
template_metadata = template.get("metadata")
if template_metadata != {
    "name": "reliability-demo-{{ .environment }}",
    "labels": {
        "app.kubernetes.io/part-of": "reliability-platform",
        "reliability.platform/environment": "{{ .environment }}",
    },
}:
    fail("Generated Application identity and labels must match the reviewed template")
template_spec = template.get("spec")
if not isinstance(template_spec, dict) or template_spec.get("project") != "reliability-platform":
    fail("Applications must remain inside the reliability-platform AppProject")
if set(template_spec) != {"project", "sources", "destination", "syncPolicy"}:
    fail("Generated Applications contain unreviewed spec settings")

sources = template_spec.get("sources")
if not isinstance(sources, list) or len(sources) != 2:
    fail("ApplicationSet must use exactly the reviewed chart and values sources")
expected_chart_source = {
    "repoURL": REPOSITORY,
    "targetRevision": "main",
    "path": "charts/reliability-demo",
    "helm": {
        "releaseName": "reliability-demo",
        "valueFiles": ["$values/gitops/environments/{{ .environment }}/values.yaml"],
    },
}
expected_values_source = {
    "repoURL": REPOSITORY,
    "targetRevision": "main",
    "ref": "values",
}
if sources != [expected_chart_source, expected_values_source]:
    fail("ApplicationSet sources must remain pinned to the reviewed repository paths on main")
if template_spec.get("destination") != {
    "server": "https://kubernetes.default.svc",
    "namespace": "{{ .environment }}",
}:
    fail("Application destination must use only the generated managed environment")

expected_sync = {
    "automated": {"allowEmpty": False, "prune": True, "selfHeal": True},
    "syncOptions": ["PruneLast=true", "PrunePropagationPolicy=foreground"],
    "retry": {
        "limit": 3,
        "backoff": {"duration": "5s", "factor": 2, "maxDuration": "1m"},
    },
}
if template_spec.get("syncPolicy") != expected_sync:
    fail("ApplicationSet reconciliation settings must match the reviewed fail-safe contract")

print("GitOps structural boundary contract passed")
PYTHON
