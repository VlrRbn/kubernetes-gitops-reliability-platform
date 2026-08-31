# Pod Recovery Drill

This exercise demonstrates controller-driven recovery after the deliberate
deletion of one application Pod. It changes no GitOps values, image identity,
replica count, or cloud resource. The deletion is still a real Kubernetes
mutation and therefore runs only when an operator provides the exact
confirmation phrase.

## Safety

The drill fails before deletion unless all of the following are true:

- the target is exactly `dev`;
- the current context is exactly `kind-gitops-reliability`;
- kind reports the expected local cluster;
- `reliability-demo-dev` is `Synced` and `Healthy` in Argo CD;
- all three reviewed Kyverno ClusterPolicies are `Ready`;
- the Helm-managed Deployment is fully available;
- the Deployment and selected Ready Pod use the same immutable image digest;
- `CONFIRM_POD_DELETE` exactly equals `DELETE ONE DEV POD`.

The script never creates a cluster, scales a Deployment, disables Argo CD, or
selects stage or prod.

## Fault Injection

Run checks first, then authorize deletion of exactly one Ready dev Pod:

```bash
make check
CONFIRM_POD_DELETE='DELETE ONE DEV POD' make pod-recovery-drill
```

The controller-owned Pod is selected by the reviewed application labels and deleted
with `--wait=false`. The Deployment remains the source of replacement state.

## Recovery Observation

The script records the original Pod name, UID, and image, then waits for a new
Ready Pod with a different UID. It requires the replacement to use the exact
same image digest and waits for the Deployment rollout to complete. The
default recovery deadline is 180 seconds and may be reduced or increased only
within the validated range of 10 to 600 seconds.

## Validation And Evidence

Recovery is accepted only when:

- Argo CD is again `Synced` and `Healthy`;
- the Deployment image did not change;
- at least one Kyverno policy report exists, and reports contain no failures,
  warnings, or errors in dev;
- the application smoke test passes.

On success, the script writes a Markdown report under
`evidence/incident-drills/`. The report includes timestamps, recovery duration,
the deleted and replacement Pod identities, immutable image, Argo CD status,
policy result, and smoke-test result.

## Interpretation

This exercise proves that a Deployment can replace one failed Pod and restore
the application contract in the disposable lab. It does not prove multi-node
survival, zone resilience, persistent-data recovery, or production incident
response. Dev runs one replica, so the exercise may produce a brief availability
interruption.
