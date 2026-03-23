# AGENTS.md

## Purpose

This repository is the GitOps repo for [`code-dot-org/code-dot-org`](https://github.com/code-dot-org/code-dot-org), specifically for the CodeAI Kubernetes deployments and supporting control-plane apps.

Deployment state here is applied by ArgoCD at [argocd.k8s.code.org](https://argocd.k8s.code.org).
Promotion between CodeAI deployments is handled by Kargo at [kargo.k8s.code.org](https://kargo.k8s.code.org).

When a change affects both the app source and the cluster/deployment definitions, it is normal to work in this repo and the neighboring `/Users/seth/src/code-dot-org` checkout together.

## Repo Shape

Read [`README.md`](/Users/seth/src/k8s-gitops/README.md) first. It is the canonical sketch of the repo structure.

Important directories in this repo:

- `apps/app-of-apps/`: root ArgoCD ApplicationSet that discovers app definitions under `apps/*`.
- `apps/codeai/`: ArgoCD ApplicationSet plus deployment and envType definitions for CodeAI.
- `apps/codeai/deployments/`: one directory per deployed CodeAI environment, each with a `deployment.yaml` and usually a `values.yaml`.
- `apps/codeai/envTypes/`: shared values/components grouped by environment type.
- `apps/kargo/`: ArgoCD-managed installation of Kargo itself.
- `apps/kargo-project-codeai/`: Kargo project, warehouse, and stage definitions that promote CodeAI deployments.
- `apps/argocd/`: ArgoCD configuration managed from this repo.

## Related Repo

Relevant paths in the sibling `/Users/seth/src/code-dot-org` repo:

- `k8s/tofu/`: EKS cluster bootstrap and shared platform components such as Dex, ArgoCD, OIDC, AWS Load Balancer Controller, and External Secrets Operator.
- `k8s/helm/`: Helm chart for the CodeAI app.
- `k8s/kustomize/`: Kustomize `base/` for the CodeAI app.

If a change spans app manifests and app code or image/build behavior, inspect both repos before editing.

## Working Guidance

- Prefer making deployment intent explicit in Git. ArgoCD and Kargo are the systems of record for what runs.
- Keep changes scoped to the environment or shared envType they actually affect.
- For CodeAI rollout/debugging questions, check whether the source of truth belongs in:
  - `/Users/seth/src/code-dot-org/k8s/helm`
  - `/Users/seth/src/code-dot-org/k8s/kustomize`
  - `/Users/seth/src/k8s-gitops/apps/codeai`
  - `/Users/seth/src/k8s-gitops/apps/kargo-project-codeai`
- If you change bootstrap or cluster-level platform concerns, the likely owner is `/Users/seth/src/code-dot-org/k8s/tofu`, not this repo.
