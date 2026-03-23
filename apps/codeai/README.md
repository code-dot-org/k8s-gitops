This app's deployment metadata lives under `deployments/` on `main`.

Long-lived environments (`staging`, `test`, `levelbuilder`, and `production`) are rendered by Kargo into `apps/codeai/deployments/<deployment>/deploy/` on `stage/<deployment>` branches, and Argo CD deploys those rendered manifests directly.

The thin build-lock and legacy gitflow gate records are written by the GitHub Actions workflow [`k8s-commit-to-kargo-warehouse.yml`](https://github.com/code-dot-org/code-dot-org/blob/staging/.github/workflows/k8s-commit-to-kargo-warehouse.yml).
