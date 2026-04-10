# argo-trace-stress-test

This tree exists to harden `bin/argo-trace` against live Argo CD states that
are awkward, noisy, or easy to truncate by accident.

It is deliberately separate from `mimic/`. `mimic/` is a small Argo shape
probe. This tree is a broader stress harness.

The default harness is cloud-free:

- normal Argo `Application` and `ApplicationSet` recursion
- workload ownership chains down to Pods and hook Jobs
- delete stalls caused by finalizers
- real Crossplane core behavior using synthetic managed CRDs

There is no Route53, ALB, ACM, or DNS here. If a future campaign needs a real
provider path, add it as a clearly isolated fallback tier.

## Layout

- `roots/primary/`: the main root used for most scenarios
- `roots/secondary/`: a second root used only to prove multi-root inference
- `apps/primary/`: live scenarios under the primary root
- `apps/secondary/`: quiet scenarios under the secondary root

The primary root contains:

- a healthy idle app
- a broken workload app that bottoms out in Pod state and events
- a hook Job app that is easy to catch mid-sync
- a finalizer stall app for delete-time tracing
- a nested `ApplicationSet`
- a Crossplane app that exercises real XR/composed-resource behavior without
  touching AWS

## Commands

Bootstrap the primary root from the current branch:

```sh
kubectl apply --server-side --field-manager=terraform -f /Users/seth/src/k8s-gitops/argo-trace-stress-test/roots/primary/bootstrap.yaml
```

Bootstrap the secondary root:

```sh
kubectl apply --server-side --field-manager=terraform -f /Users/seth/src/k8s-gitops/argo-trace-stress-test/roots/secondary/bootstrap.yaml
```

Delete both roots foreground and wait:

```sh
kubectl delete --cascade=foreground --wait=true -f /Users/seth/src/k8s-gitops/argo-trace-stress-test/roots/primary/bootstrap.yaml
kubectl delete --cascade=foreground --wait=true -f /Users/seth/src/k8s-gitops/argo-trace-stress-test/roots/secondary/bootstrap.yaml
```
