# apps/infra bootstrap and progressive-sync plan

ALWAYS CHECK ITEMS OFF AS YOU ACCOMPLISH THEM.

## Summary

Bootstrap Argo in two layers:

1. `argocd-bootstrap.tf` installs Argo once, from the `k8s-gitops` `apps/infra/argocd/chart` tree fetched into a temp checkout.
2. `argocd-app-of-apps-bootstrap.tf` then bootstraps `apps/app-of-apps/applicationset.yaml`, which creates the top-level `infra`, `kargo`, and `codeai` apps using `RollingSync`.

The legacy Helm releases in `helm.tf` remain behind `deploy_helm_charts`, which stays default `false`. Argo then manages the real infra chart set from `apps/infra`.

## Key changes

### Argo bootstrap in `code-dot-org`

- Add `argocd-bootstrap.tf` in `cluster-infra-argocd`.
- Fetch the `k8s-gitops` default branch with a shallow sparse clone into an untracked temp dir, limited to `apps/infra/argocd/`.
- Use a bootstrap `helm_release` with:
  - release name `argocd`
  - namespace `argocd`
  - chart path `<temp checkout>/apps/infra/argocd/chart`
- Keep this bootstrap release managed in Tofu after Argo self-management starts.
- Make `argocd-app-of-apps-bootstrap.tf` depend on the bootstrap release.
- Keep `deploy_helm_charts` controlling only the legacy `helm.tf` releases.

### Keep the Argo chart bootstrap-safe

- Do not keep ESO-dependent resources in `apps/infra/argocd/chart`.
- Move these templates into `apps/infra/dex/chart/templates/`:
  - `argocd-secret-external-secret.yaml`
  - `argocd-dex-client-secret-generator.yaml`
- Render them in namespace `argocd` from the `dex` app.
- This keeps the main Argo chart bootstrap-safe without any bootstrap-only
  values override.

### Resolve the `argocd` app collision in `k8s-gitops`

- Move `apps/argocd/repos.yaml` verbatim into:
  - `apps/infra/argocd/chart/templates/repos.yaml`
- Delete:
  - `apps/argocd/application.yaml`
  - `apps/argocd/repos.yaml`
  - `apps/argocd/` if empty
- Do not rename the infra child app. The only `Application` named `argocd` should be `apps/infra/argocd/application.yaml`.

### Top-level sequencing via `RollingSync`

- Enable Progressive Syncs in the Argo chart by adding:
  - `applicationsetcontroller.enable.progressive.syncs: "true"`
  - under `argo-cd.configs.params`
- Restore health assessment for `argoproj.io/Application` in the Argo chart under `argo-cd.configs.cm`:
  - `resource.customizations.health.argoproj.io_Application`
  - use the current stable Argo docs `Argocd App` Lua snippet as-is:
    - `hs = {}`
    - `hs.status = "Progressing"`
    - `hs.message = ""`
    - if `obj.status.health` exists, copy through its `status` and optional `message`
    - return `hs`
  - source: [Argo CD Resource Health: Argocd App](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app)
  - do not simplify or rewrite it unless there is a concrete behavior change we want
- Keep the existing internal infra child waves unchanged:
  - `networking` `0`
  - `external-secrets-operator` `1`
  - `external-dns` `1`
  - `argocd` `2`
  - `kargo-secrets` `2`
  - `standard-envtypes` `2`
  - `dex` `3`
- Add a top-level label key on generated apps:
  - `code.org/bootstrap-group`
- Label the top-level passthrough `Application`s directly in Git:
  - `apps/infra/application.yaml`: `code.org/bootstrap-group=infra`
- Do not add `post-infra` labels to `kargo` or generated wrapper apps. Everything not labeled `infra` belongs to the second step.
- Add `spec.strategy` to `apps/app-of-apps/applicationset.yaml`:
  - `type: RollingSync`
  - `deletionOrder: Reverse`
  - steps:
    - `code.org/bootstrap-group In [infra]`
    - `code.org/bootstrap-group NotIn [infra]`
- Do not use top-level sync-wave annotations for `infra`, `kargo`, or wrapper apps. `RollingSync` is the top-level ordering mechanism.
- Leave passthrough behavior for top-level `application.yaml` files unchanged apart from the new bootstrap-group label.

### `RollingSync` behavior notes

- `RollingSync` gates on managed `Application` health, which is what we want at the top level.
- Restoring `argoproj.io/Application` health is therefore required, not optional, for this plan.
- The ApplicationSet controller will disable autosync on the generated top-level apps. That is expected and acceptable.
- The child apps inside `infra`, `kargo`, and `codeai` keep their own normal sync policies.
- The `dex` child app owns the ESO-dependent Argo secret resources, so those
  resources do not appear until after ESO is in place.

### Docs and tracking files

- Refresh `apps/infra/implementation-checklist.md` to match:
  - `apps/argocd` removal
  - repo-secret move into the infra argocd chart
  - bootstrap via `argocd-bootstrap.tf`
  - top-level `RollingSync` plan
- Update `README.md` so `apps/argocd` is gone and repo secrets live under `apps/infra/argocd/chart/templates/`.

## Test plan

- `k8s-gitops`
  - `git diff --check`
  - confirm only one `Application` named `argocd` remains
  - `helm template` succeeds for `apps/infra/argocd/chart` after moving `repos.yaml`
  - `helm template` succeeds for `apps/infra/dex/chart` after moving the
    ESO-dependent Argo secret resources there
  - confirm `apps/app-of-apps/applicationset.yaml` includes:
    - Progressive Sync enablement assumptions
    - `RollingSync` strategy
    - second step expressed as `code.org/bootstrap-group NotIn [infra]`
  - confirm `apps/infra/argocd/chart/values.yaml` includes the restored:
    - `resource.customizations.health.argoproj.io_Application`
- `code-dot-org`
  - `tofu validate` in `cluster-infra-argocd`
  - default apply with `deploy_helm_charts=false` plans:
    - bootstrap Argo
    - bootstrap `app-of-apps`
    - no legacy `helm.tf` releases
- Live ordering
  - top-level `infra` app syncs first and reaches `Healthy`
  - only after that does the non-`infra` group proceed
  - `kargo` and the `codeai` wrapper app are both in that second group
  - inside `infra`, child apps still follow the existing `0/1/2/3` order
- Live bootstrap
  - repo secrets from the moved `repos.yaml` appear in `argocd`
  - `apps/infra/argocd/application.yaml` becomes healthy and manages the same Argo resources as the bootstrap release

## Assumptions

- The bootstrap chart source comes from a shallow sparse clone of `k8s-gitops`, not the old local `infra/argocd` chart in `code-dot-org`.
- Keeping the bootstrap `helm_release` managed in Tofu after Argo self-management starts is acceptable.
- All top-level wrapper apps generated from `applicationset.yaml` may safely run after infra; current impact is `codeai`.
- `kargo` and `codeai` may sync together in the second non-`infra` group. No further top-level ordering between those two is required for this plan.
- The `argoproj.io/Application` health snippet should be copied from the Argo docs as-is unless there is a concrete reason to simplify it.
- The source of truth for that snippet is the stable Argo docs `Argocd App` section, not an older local copy.
- The ESO-dependent Argo secret resources belong with `dex`, not with the main
  Argo bootstrap chart.
