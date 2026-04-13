# mimic

Bootstraps the non-production `bootstrap/apptrees/mimic/` Argo tree from `k8s-gitops`.

This is a small test root for Argo app-of-apps experiments. It mirrors the real
bootstrap pattern, but points at:

- `bootstrap/apptrees/mimic/apps/app-of-apps/bootstrap.yaml`
- `bootstrap/apptrees/mimic/apps/app-of-apps/app-of-apps.yaml`

## Pre-requisites

Apply `../cluster/` and `../cluster-infra-argocd/` first.

## Usage

```bash
tofu init
AWS_PROFILE=codeorg-admin tofu apply
```
