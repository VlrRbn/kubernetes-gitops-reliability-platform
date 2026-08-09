SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= gitops-reliability
NAMESPACE ?= dev
RELEASE_NAME ?= reliability-demo
IMAGE_REPOSITORY ?= reliability-demo
IMAGE_TAG ?= dev
COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')
VERSION ?= 0.1.0

.PHONY: help check image-build cluster-create image-load deploy-dev smoke-test local-demo cluster-delete

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

deploy-dev: ## Deploy the local image to the dev namespace with Helm
	helm upgrade --install "$(RELEASE_NAME)" ./charts/reliability-demo \
	  --namespace "$(NAMESPACE)" \
	  --create-namespace \
	  --values ./gitops/environments/dev/values.yaml \
	  --set-string image.repository="$(IMAGE_REPOSITORY)" \
	  --set-string image.tag="$(IMAGE_TAG)" \
	  --wait \
	  --timeout 2m

smoke-test: ## Verify health, readiness, application, and metrics endpoints
	@NAMESPACE="$(NAMESPACE)" RELEASE_NAME="$(RELEASE_NAME)" ./scripts/smoke-test.sh

local-demo: check image-build cluster-create image-load deploy-dev smoke-test ## Run the complete local vertical slice

cluster-delete: ## Delete only the local kind cluster
	kind delete cluster --name "$(CLUSTER_NAME)"
