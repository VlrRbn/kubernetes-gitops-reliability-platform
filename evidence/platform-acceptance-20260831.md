# Reliability Platform Acceptance Evidence

- Result: PASS
- Date: `2026-08-31`
- Context: `kind-gitops-reliability`
- Tested revision: `6fc8acd5a2ab80e0c50305a975ae30bc7fd47339`
- Tested revision title: `fix(platform): enforce clean bootstrap dependency order (#32)`
- Application image: `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:de0f442a19a212135e303fc1cfbe6ea4b8d32783a4f2838bbf09d47ed1131c31`

## Acceptance Sequence

The disposable kind cluster was deleted before this acceptance run. The
platform was then rebuilt in the documented dependency order:

```text
empty host-side kind target
  -> monitoring and ServiceMonitor CRDs
  -> Argo CD and three Applications
  -> Kyverno audit and enforcement
  -> application and alert-delivery validation
  -> controlled dev Pod recovery drill
```

`make local-demo` was intentionally not used. It is an independent standalone path
for the `local-dev` namespace and is not a prerequisite for the GitOps platform.

## Monitoring Foundation

`make monitoring-bootstrap` created the new kind cluster and completed before
Argo CD was installed. The bootstrap reported:

- Prometheus, Alertmanager, and Grafana ready;
- the `ServiceMonitor` and `PrometheusRule` APIs available;
- both reviewed SLO rule groups loaded;
- the pinned monitoring image and configuration checks passed.

After Argo CD reconciliation, the labeled application monitor was present in
all three namespaces:

```text
dev     reliability-demo
stage   reliability-demo
prod    reliability-demo
```

The synthetic Alertmanager contract passed and delivered its test alert to the
`reliability-demo` service in dev.

## GitOps Reconciliation

`make argocd-bootstrap` ran only after the monitoring CRDs existed. No manual
retry or same-revision sync patch was required. All generated Applications
reached the expected state:

```text
reliability-demo-dev     Synced   Healthy
reliability-demo-stage   Synced   Healthy
reliability-demo-prod    Synced   Healthy
```

The dev, stage, and prod smoke tests passed against the digest-pinned application.

## Admission Controls

`make kyverno-bootstrap` completed its Audit-to-Enforce lifecycle after all three
Applications were healthy. The reviewed ClusterPolicies became Ready.
Workload reports for Deployments, ReplicaSets, and Pods contained four passes per
resource and zero failures, warnings, or errors.

## Recovery Exercise

The operator explicitly authorized deletion of one Ready Pod in dev. The drill
did not change GitOps values, replica count, or image identity.

The generated raw report is
[`incident-drills/pod-recovery-dev-20260831T173535Z.md`](incident-drills/pod-recovery-dev-20260831T173535Z.md).
It records:

- deleted Pod: `reliability-demo-5bf76d8b48-qc6s4`;
- replacement Pod: `reliability-demo-5bf76d8b48-fxxz9`;
- distinct old and replacement UIDs;
- recovery duration: 4 seconds;
- Deployment availability: `1/1` after recovery;
- Argo CD: `Synced / Healthy`;
- Kyverno policy violations: 0;
- application smoke test: PASS;
- replacement image unchanged at the reviewed digest.

## Scope And Interpretation

This evidence demonstrates reproducible single-node lab bootstrap, GitOps
reconciliation, enforced workload policy, local telemetry and alert routing,
and controller-driven recovery from one Pod deletion. It does not claim
multi-node or availability-zone resilience, persistent-data recovery,
high-availability monitoring, external paging delivery, or zero downtime. Dev
runs one replica, so a short interruption during the recovery drill is an
expected limitation.
