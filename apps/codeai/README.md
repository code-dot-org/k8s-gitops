This app's deployment definitions live under `deployments/`.

Each deployment now has:

- `deployment.yaml`: metadata only, currently `envType` and `namespace`
- `deploy/kustomization.yaml`: the machine-owned wrapper that pins the remote
  `code-dot-org//k8s/kustomize/base` path to an exact commit and rewrites the
  immutable image tag

Release metadata writeback is done by the GitHub Actions workflow
[`k8s-commit-image-ref-to-argocd.yml`](https://github.com/code-dot-org/code-dot-org/blob/staging/.github/workflows/k8s-commit-image-ref-to-argocd.yml),
which writes thin build-lock records under `warehouses/codeai/`.
