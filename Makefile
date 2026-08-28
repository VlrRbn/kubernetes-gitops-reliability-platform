SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= gitops-reliability
NAMESPACE ?= local-dev
RELEASE_NAME ?= reliability-demo-local
WORKLOAD_NAME ?= reliability-demo
IMAGE_REPOSITORY ?= reliability-demo
IMAGE_TAG ?= dev
COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')
VERSION ?= dev

.PHONY: help check image-build cluster-create image-load deploy-local smoke-test local-demo argocd-bootstrap argocd-status monitoring-bootstrap kyverno-bootstrap admission-status promote cluster-delete

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Available targets:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Run Go, Helm, shell, positive, and negative checks
	@./scripts/run-local-checks.sh

image-build: ## Build the hardened local application image
	docker build \
	  --build-arg VERSION="$(VERSION)" \
	  --build-arg COMMIT="$(COMMIT)" \
	  --tag "$(IMAGE_REPOSITORY):$(IMAGE_TAG)" \
	  ./app

cluster-create: ## Create the local kind cluster if it does not exist
	@CLUSTER_NAME="$(CLUSTER_NAME)" ./scripts/create-cluster.sh

image-load: ## Load the local image into kind
	kind load docker-image \
	  --name "$(CLUSTER_NAME)" \
	  "$(IMAGE_REPOSITORY):$(IMAGE_TAG)"

deploy-local: ## Deploy the local image outside the Argo-managed environments
	helm upgrade --install "$(RELEASE_NAME)" ./charts/reliability-demo \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --values ./gitops/environments/dev/values.yaml \
	  --set-string image.repository="$(IMAGE_REPOSITORY)" \
	  --set-string image.tag="$(IMAGE_TAG)" \
	  --set-string image.digest= \
	  --wait \
	  --timeout 2m

smoke-test: ## Verify health, readiness, application, and metrics endpoints
	@NAMESPACE="$(NAMESPACE)" RELEASE_NAME="$(WORKLOAD_NAME)" ./scripts/smoke-test.sh

local-demo: check image-build cluster-create image-load deploy-local smoke-test ## Run the complete local vertical slice

argocd-bootstrap: cluster-create ## Install pinned Argo CD and apply the restricted GitOps control plane
	@CLUSTER_NAME="$(CLUSTER_NAME)" ./scripts/bootstrap-argocd.sh

argocd-status: ## Show generated Applications and environment workloads
	@kubectl get applications.argoproj.io -n argocd
	@for namespace in dev stage prod; do \
	  printf '\n[%s]\n' "$$namespace"; \
	  kubectl get deployment,pod,service --namespace "$$namespace"; \
	done

monitoring-bootstrap: cluster-create ## Install the pinned Prometheus foundation
	@CLUSTER_NAME="$(CLUSTER_NAME)" ./scripts/bootstrap-monitoring.sh

kyverno-bootstrap: ## Install pinned Kyverno, audit live workloads, and enforce admission policies
	@CLUSTER_NAME="$(CLUSTER_NAME)" ./scripts/bootstrap-kyverno.sh

admission-status: ## Show admission policies and policy reports
	@printf '[Cluster admission policies]\n'
	@kubectl get clusterpolicy
	@printf '\n[Workload policy reports]\n'
	@kubectl get policyreport --all-namespaces

promote: ## Update one environment: make promote TARGET_ENV=dev IMAGE_COMMIT=<full-sha>
	@test -n "$(TARGET_ENV)" || { echo "TARGET_ENV is required" >&2; exit 1; }
	@test -n "$(IMAGE_COMMIT)" || { echo "IMAGE_COMMIT is required" >&2; exit 1; }
	@./scripts/promote-image.sh "$(TARGET_ENV)" "$(IMAGE_COMMIT)"

cluster-delete: ## Delete only the local kind cluster
	kind delete cluster --name "$(CLUSTER_NAME)"
