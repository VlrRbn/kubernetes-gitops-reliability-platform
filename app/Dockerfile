# syntax=docker/dockerfile:1.18@sha256:dabfc0969b935b2080555ace70ee69a5261af8a8f1b4df97b9e7fbcf6722eddf
ARG GO_IMAGE=golang:1.26.6-alpine3.23@sha256:5978cc992ad5ef96a7469713c8af849c1433824761ce3be2c56381403cd8d9a3

FROM ${GO_IMAGE} AS build
WORKDIR /src

COPY go.mod go.sum ./
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

ARG VERSION=dev
ARG COMMIT=unknown

LABEL org.opencontainers.image.title="reliability-demo" \
      org.opencontainers.image.description="Fault-injectable service for the Kubernetes GitOps reliability portfolio" \
      org.opencontainers.image.source="https://github.com/VlrRbn/kubernetes-gitops-reliability-platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}"

COPY --from=build --chown=65532:65532 /out/reliability-demo /reliability-demo

USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD ["/reliability-demo", "healthcheck"]

ENTRYPOINT ["/reliability-demo"]
