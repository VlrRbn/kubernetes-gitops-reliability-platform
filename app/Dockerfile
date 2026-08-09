# syntax=docker/dockerfile:1.18
ARG GO_IMAGE=golang:1.24.6-alpine3.22@sha256:c8c5f95d64aa79b6547f3b626eb84b16a7ce18a139e3e9ca19a8c078b85ba80d

FROM ${GO_IMAGE} AS build
WORKDIR /src

COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/

ARG VERSION=dev
ARG COMMIT=unknown

RUN CGO_ENABLED=0 GOOS=linux go test ./... && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/reliability-demo \
      ./cmd/server

FROM scratch

LABEL org.opencontainers.image.title="reliability-demo" \
      org.opencontainers.image.description="Fault-injectable service for the Kubernetes GitOps reliability portfolio" \
      org.opencontainers.image.source="https://github.com/VlrRbn/kubernetes-gitops-reliability-platform"

COPY --from=build --chown=65532:65532 /out/reliability-demo /reliability-demo

USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD ["/reliability-demo", "healthcheck"]

ENTRYPOINT ["/reliability-demo"]
