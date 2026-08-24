# Admission Policy

Kyverno provides admission controls for the Argo-managed `dev`, `stage`, and
`prod` namespaces. Argo CD remains the workload owner; Kyverno only decides
whether a requested Pod is acceptable and reports existing violations.

## Policy Contract

The enforced policies require:

- every workload image to carry a valid keyless signature from the exact
  `secure-image.yml` workflow identity on protected `main`;
- every regular, init, and ephemeral container image to use a full
  `sha256` digest;
- the Kubernetes `restricted` Pod Security Standard pinned to `v1.32`,
  including non-root execution, seccomp, no privileged containers, no
  privilege escalation, restricted capabilities, no host namespaces, and no
  `hostPath` volumes;
- a read-only root filesystem for every container.

The rules deliberately target only `dev`, `stage`, and `prod`. Kyverno and
Argo CD system workloads are outside this application boundary.

## Reproducible Bootstrap

Kyverno `v1.18.2` is installed from Helm chart `3.8.2`. The chart archive is
verified by SHA256, and every rendered controller and hook image must use a
reviewed multi-platform digest before Helm may contact the cluster.

Bootstrap after Argo CD has created and reconciled all three environments:

```bash
make check
make argocd-status
make kyverno-bootstrap
make admission-status
```

The bootstrap accepts only the `kind-gitops-reliability` context. It waits for
the Kyverno policy webhooks with bounded server-side dry runs instead of assuming
that Helm readiness means the webhooks already accept traffic. Each policy that
does not yet exist is first applied in `Audit`; bootstrap waits until all three
namespaces have reports for every new policy and requires zero failures before
applying the repository version in `Enforce`. A timeout or violation removes
only the temporary policies introduced by that run and fails closed. Existing
enforced policies must match the repository exactly and are never downgraded or
silently replaced. A changed existing policy requires a new disposable cluster
and a fresh audit.

The audit includes inactive controller revisions such as zero-replica
ReplicaSets. An unsigned historical revision therefore blocks signature-policy
activation even when the current Deployment is signed. Bootstrap reports the
namespace, kind, and object name but never deletes rollback history
automatically. The operator must review and explicitly retire an obsolete
unsigned revision, or recreate the disposable cluster from the current GitOps
state, before running bootstrap again.

### Review an unsigned historical ReplicaSet

When the audit identifies a ReplicaSet, inspect it before deleting anything:

```bash
NAMESPACE=dev
REPLICASET=reliability-demo-example

kubectl get replicaset "$REPLICASET" \
  --namespace "$NAMESPACE" \
  --output custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,OWNER:.metadata.ownerReferences[0].name,IMAGE:.spec.template.spec.containers[0].image'
```

Confirm all of the following:

- `DESIRED` and `CURRENT` are both `0`, so the revision serves no Pods;
- `OWNER` is the expected `reliability-demo` Deployment;
- `IMAGE` is the unsigned digest reported by the failed audit;
- the current Deployment uses the newer reviewed and signed digest:

```bash
kubectl get deployment reliability-demo \
  --namespace "$NAMESPACE" \
  --output jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Only after those checks, explicitly retire that single obsolete revision:

```bash
kubectl delete replicaset "$REPLICASET" --namespace "$NAMESPACE"
```

Repeat the inspection for every object reported by bootstrap, then run
`make kyverno-bootstrap` again. Deleting a ReplicaSet removes that Deployment
revision from the local rollback history; this is why bootstrap reports the
violation but never performs the deletion automatically. For this disposable
lab, recreating the kind cluster from the current GitOps state is the clean
alternative when rollback history does not need to be preserved.

## Acceptance Evidence

Confirm that the existing workloads remain healthy:

```bash
make argocd-status
NAMESPACE=dev make smoke-test
NAMESPACE=stage make smoke-test
NAMESPACE=prod make smoke-test
```

Then prove that admission rejects a mutable image without creating a Pod:

```bash
kubectl run admission-negative-test \
  --namespace dev \
  --image=nginx:latest \
  --restart=Never
```

The command must be denied by `require-immutable-images`. Verify that no test
Pod exists:

```bash
kubectl get pod admission-negative-test --namespace dev
```

The local Kyverno CLI suite covers compliant resources plus mutable images,
privileged containers, writable root filesystems, root execution, unsafe
security contexts, host namespaces, and `hostPath` volumes. Registry-backed
signature tests accept the current `main` image and reject unsigned images,
images signed by another workflow identity, and unverifiable digests.

The complete acceptance sequence was exercised:

- all four Kyverno controllers reached `Running` without restarts;
- all three ClusterPolicies reached `Ready` with admission and background scanning
  enabled;
- existing Deployment, ReplicaSet, and Pod reports contained four passes and
  zero failures, warnings, or errors per workload;
- the API server denied the mutable `nginx:latest` test Pod and did not create it;
- the signature policy accepted the digest signed by `secure-image.yml` on
  protected `main`;
- unsigned, wrong-workflow-identity, and unverifiable digests were denied;
- smoke tests passed in `dev`, `stage`, and `prod` after enforcement.

## Trade-offs

Keyless signature verification depends on GHCR and public Sigstore services.
Registry, DNS, or verifier failures deny admission by design, improving supply
chain integrity at the cost of deployment availability. Kyverno is bootstrapped
imperatively because the restricted Argo AppProject cannot manage cluster-scoped
CRDs or ClusterPolicies; application delivery remains GitOps-managed.
