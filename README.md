# k8s-gitops

## Bootstrap

kubectl apply -f apps/app-of-apps/applicationset.yaml

## What is it?

This directory models the external GitOps repo at:

- `https://github.com/code-dot-org/k8s-gitops`

It is scaffolded locally under `k8s/k8s-gitops` so we can iterate on:

- Argo CD bootstrap/config
- Kargo resources
- env-type defaults
- per-release deployment values

The v1 model is:

- one long-lived GitOps branch
- fixed Kargo-managed releases only
- Argo CD reads Git
- Kargo writes Git
- values files in GitOps, not rendered manifests
