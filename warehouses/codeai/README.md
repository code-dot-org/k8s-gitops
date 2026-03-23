`warehouses/codeai/freight/` is the frozen release input consumed by Kargo.

CI writes two directories in the same `main` branch commit for each release:

- `warehouses/codeai/freight/current/`
- `warehouses/codeai/freight/git-<full-commit-sha>/`

`current/` must be an exact mirror of the matching historical `git-<full-commit-sha>/` directory in the same commit.

Promotion reads only `current/freight.yaml` plus the `current/helm/` chart snapshot. Environment-specific policy stays under `apps/codeai/`.
