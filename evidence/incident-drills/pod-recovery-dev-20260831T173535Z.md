# Pod Recovery Drill Evidence

- Result: PASS
- Context: `kind-gitops-reliability`
- Environment: `dev`
- Deployment: `reliability-demo`
- Image: `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:de0f442a19a212135e303fc1cfbe6ea4b8d32783a4f2838bbf09d47ed1131c31`
- Started: `2026-08-31T17:35:30Z`
- Recovered: `2026-08-31T17:35:34Z`
- Recovery duration: 4 seconds
- Deleted Pod: `reliability-demo-5bf76d8b48-qc6s4` (UID `3dd187fb-90af-4588-a97d-9deca5b58e78`)
- Replacement Pod: `reliability-demo-5bf76d8b48-fxxz9` (UID `eb01e7be-eedc-4ed6-9aae-e949d53b327e`)
- Argo CD: `Synced / Healthy`
- Kyverno policy violations: 0
- Smoke test: PASS
