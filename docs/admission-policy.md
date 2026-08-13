# Admission Policy

Kyverno provides admission controls for the Argo-managed `dev`, `stage`, and
`prod` namespaces. Argo CD remains the workload owner; Kyverno only decides
whether a requested Pod is acceptable and reports existing violations.

## Policy Contract

The enforced policies require:

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

The bootstrap accepts only the `kind-gitops-reliability` context. On first
installation it applies the policies in `Audit`, waits until all three namespaces
have reports for both policies, and requires zero failures before applying the
repository versions in `Enforce`. A timeout or violation removes the temporary
Audit policies and fails closed. Existing policies are never silently replaced:
a changed policy requires a new disposable cluster and a fresh audit.

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
security contexts, host namespaces, and `hostPath` volumes.

The complete acceptance sequence was exercised:

- all four Kyverno controllers reached `Running` without restarts;
- both ClusterPolicies reached `Ready` with admission and background scanning
  enabled;
- existing Deployment, ReplicaSet, and Pod reports contained three passes and
  zero failures, warnings, or errors per workload;
- the API server denied the mutable `nginx:latest` test Pod and did not create it;
- smoke tests passed in `dev`, `stage`, and `prod` after enforcement.

## Trade-offs

This milestone validates image immutability but does not verify who built or
signed an image. Kyverno is bootstrapped imperatively because the restricted
Argo AppProject cannot manage cluster-scoped CRDs or ClusterPolicies;
application delivery remains GitOps-managed.
