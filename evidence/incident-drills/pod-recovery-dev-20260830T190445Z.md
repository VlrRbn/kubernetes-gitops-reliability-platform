# Pod Recovery Drill Evidence

- Result: PASS
- Context: `kind-gitops-reliability`
- Environment: `dev`
- Deployment: `reliability-demo`
- Image: `ghcr.io/vlrrbn/kubernetes-gitops-reliability-platform@sha256:de0f442a19a212135e303fc1cfbe6ea4b8d32783a4f2838bbf09d47ed1131c31`
- Started: `2026-08-30T19:04:39Z`
- Recovered: `2026-08-30T19:04:43Z`
- Recovery duration: 4 seconds
- Deleted Pod: `reliability-demo-5bf76d8b48-gjxqz` (UID `073353fa-ebe0-48f1-bc1b-4e741d97cc66`)
- Replacement Pod: `reliability-demo-5bf76d8b48-jnmgf` (UID `62321aa9-3eeb-4925-82c2-77ef03ee52ba`)
- Argo CD: `Synced / Healthy`
- Kyverno policy violations: 0
- Smoke test: PASS
