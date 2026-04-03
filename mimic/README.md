# mimic

This is a non-production imitation of `apps/`.

It exists to test Argo CD behavior against a small tree that preserves the
shapes we care about:

- `ApplicationSet` wrappers for `applicationset.yaml`
- passthrough of `application.yaml`
- recursive `app-of-apps` self-management
- simple HTTP services behind Ingress + `code.ai/dns-name`

Nothing under `mimic/` is meant to be part of the real cluster topology.
Use it only for experiments.

Argo `Application` and `ApplicationSet` names under this tree should start with
`mimic-`.

## Commands

These mirror the current Tofu `app-of-apps` bootstrap behavior as closely as
practical:

- bootstrap from GitHub `main`
- server-side apply
- foreground waited delete

Bootstrap:

```sh
kubectl apply --server-side --field-manager=terraform -f <(curl -fsSL https://raw.githubusercontent.com/code-dot-org/k8s-gitops/main/mimic/apps/app-of-apps/applicationset.yaml)
```

Destroy:

```sh
kubectl delete --cascade=foreground --wait=true -f <(curl -fsSL https://raw.githubusercontent.com/code-dot-org/k8s-gitops/main/mimic/apps/app-of-apps/applicationset.yaml)
```
