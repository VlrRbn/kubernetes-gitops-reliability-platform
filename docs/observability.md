# Observability And SLOs

The observability capability provides a reproducible local monitoring path for the
Argo-managed `dev`, `stage`, and `prod` environments. It collects only the application
telemetry required by this project.

## Monitoring Contract

The pinned `kube-prometheus-stack` chart installs:

- Prometheus with six-hour retention and 30-second scrape and evaluation intervals;
- Alertmanager with six-hour retention and a local webhook receiver;
- Grafana with a provisioned Prometheus datasource and version-controlled SLO
  dashboard;
- Prometheus Operator CRDs and controllers required by `ServiceMonitor` and
  `PrometheusRule` resources.

The chart archive is verified by SHA256 before rendering. Bootstrap rejects
any rendered or live monitoring image that is not pinned by registry digest.
Prometheus selects only `ServiceMonitor` resources carrying
`observability.reliability-platform.io/monitor=true` in `dev`, `stage`, and
`prod`. Cluster-wide node and control-plane exporters are deliberately disabled
to keep the disposable lab focused and resource-bounded.

The application exports labeled request counters and a request-duration
histogram. Recording rules derive:

- five-minute request and HTTP 5xx error rates;
- five-minute availability ratio;
- five-minute p95 request latency.

Alerts require real traffic and remain pending for ten minutes before firing:

- availability below 99%;
- p95 latency above 500 ms.

## Reproducible Bootstrap

Argo CD must first reconcile the application into all three environments so
that their labeled `ServiceMonitor` resources and metrics endpoints exist:

```bash
make check
make argocd-bootstrap
make argocd-status
make monitoring-bootstrap
```

Bootstrap accepts only the `kind-gitops-reliability` context. It verifies the
chart checksum and image digests, waits for Prometheus, Alertmanager, Grafana,
and the Operator, confirms that both reviewed rule groups loaded, checks the
live Prometheus and Alertmanager configurations, and fails if Grafana restarted
during bootstrap.

Run the synthetic Alertmanager delivery contract separately:

```bash
make alertmanager-test
```

The test submits a short-lived alert to the in-cluster Alertmanager and requires
the configured webhook delivery to increase the dev application's request
counter within 30 seconds. It does not contact an external paging provider.

## Grafana Access

Print the generated local administrator password:

```bash
make grafana-password
```

In a separate terminal, expose Grafana locally:

```bash
make grafana-port-forward
```

Open `http://localhost:3000` and sign in as `admin`. The provisioned
**Reliability Demo SLOs** dashboard contains:

- availability by environment;
- request and error rates;
- p95 request latency;
- Prometheus scrape health;
- firing SLO alert count.

The dashboard JSON is reviewed in Git, mounted through a generated ConfigMap,
and loaded by Grafana's file provider. The dashboard is read-only in the UI so
that local edits cannot silently diverge from the repository.

## Acceptance Evidence

The complete path was exercised against the disposable kind cluster:

- [PR #25](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/pull/25)
  introduced the application metrics, environment `ServiceMonitor` resources,
  pinned monitoring stack, SLO rules, and Alertmanager delivery test;
- the same observability-enabled image was promoted through dev, stage, and
  prod using one immutable commit and digest;
- Prometheus reported healthy scrape targets for all three environments;
- the synthetic Alertmanager alert reached the dev application;
- [PR #29](https://github.com/VlrRbn/kubernetes-gitops-reliability-platform/pull/29)
  added the provisioned Grafana dashboard and its guardrail tests;
- Grafana displayed 100% five-minute availability, zero HTTP 5xx error rate,
  healthy scrapes, and zero firing SLO alerts for dev, stage, and prod;
- p95 latency and request-rate panels showed live application samples for all
  three environments.

## Trade-offs

This is a single-node, disposable lab. Prometheus, Alertmanager, and Grafana
run as single replicas without persistent storage, long-term retention, or
high availability. Alertmanager delivers to an in-cluster test receiver rather
than a real paging service. The configuration demonstrates collection, SLO
evaluation, visualization, and verified routing while keeping the project
locally reproducible.
