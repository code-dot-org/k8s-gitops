This app's deployment definitions live under `deployments/`.

The `image:` line in each `deployments/*/values.yaml` is written by Kargo.
Each Kargo Stage under [`apps/kargo/projects/codeai/stages/`](../kargo/projects/codeai/stages/)
promotes a `ghcr.io/code-dot-org/cdo-rails` digest by committing it to the matching
values file and then refreshing the `codeai-<deployment>` Argo Application.
