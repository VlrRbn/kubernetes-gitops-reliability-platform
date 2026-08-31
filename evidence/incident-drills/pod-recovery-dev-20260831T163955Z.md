# Pod Recovery Drill Evidence

- Result: PASS
- Context: `kind-gitops-reliability`
- Environment: `dev`
- Deployment: `reliability-demo`
- Image: `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:de0f442a19a212135e303fc1cfbe6ea4b8d32783a4f2838bbf09d47ed1131c31`
- Started: `2026-08-31T16:39:52Z`
- Recovered: `2026-08-31T16:39:54Z`
- Recovery duration: 2 seconds
- Deleted Pod: `reliability-demo-5bf76d8b48-q5q55` (UID `1a95db55-1d3f-4050-a2c2-5ad2c8b58aa3`)
- Replacement Pod: `reliability-demo-5bf76d8b48-n4m27` (UID `c6f37948-f8f9-47aa-a056-cb3b37d2332b`)
- Argo CD: `Synced / Healthy`
- Kyverno policy violations: 0
- Smoke test: PASS
