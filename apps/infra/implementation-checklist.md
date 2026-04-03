# apps/infra implementation checklist

Refresh `/Users/seth/src/k8s-gitops/apps/infra/implementation-plan.md` first if this thread gets interrupted. This file tracks execution state against that plan.

## Infra chart groundwork

- [x] Replace the placeholder `apps/infra` layout with the parent-and-child application layout.
- [x] Add `apps/infra/charts/eso-per-env/` as the shared chart-only directory.
- [x] Delete the placeholder `.gitkeep` files under `apps/infra/**`.
- [x] Copy `networking` into `apps/infra/networking/chart/`.
- [x] Copy `external-secrets-operator` into `apps/infra/external-secrets-operator/chart/`.
- [x] Copy `external-dns` into `apps/infra/external-dns/chart/`.
- [x] Copy `argocd` into `apps/infra/argocd/chart/`.
- [x] Copy `kargo-secrets` into `apps/infra/kargo-secrets/chart/`.
- [x] Copy `standard-envtypes` into `apps/infra/standard-envtypes/chart/`.
- [x] Copy `dex` into `apps/infra/dex/chart/`.
- [x] Copy `eso-per-envtype` into `apps/infra/charts/eso-per-env/`.
- [x] Update the copied `standard-envtypes` chart to use `file://../../charts/eso-per-env`.

## Infra child apps

- [x] Write `apps/infra/networking/application.yaml` with internal wave `0` and namespace `kube-system`.
- [x] Write `apps/infra/external-secrets-operator/application.yaml` with internal wave `1` and namespace `external-secrets`.
- [x] Write `apps/infra/external-dns/application.yaml` with internal wave `1` and namespace `external-dns`.
- [x] Write `apps/infra/argocd/application.yaml` with internal wave `2` and namespace `argocd`.
- [x] Write `apps/infra/kargo-secrets/application.yaml` with internal wave `2` and namespace `kargo-system-resources`.
- [x] Write `apps/infra/standard-envtypes/application.yaml` with internal wave `2` and namespace `external-secrets`.
- [x] Write `apps/infra/dex/application.yaml` with internal wave `3` and namespace `dex`.
- [x] Make every child application load `apps/infra/codeai-cluster-config.values.yaml`.
- [x] Rewrite `apps/infra/application.yaml` to point only at child `application.yaml` files.
- [x] Exclude `apps/infra/charts/` from the parent app.
- [x] Do not create an `eso-per-env` application.

## Validation already done

- [x] Run `git diff --check` on the current local `k8s-gitops` diff.
- [x] Run `helm template` for all seven copied charts against `apps/infra/codeai-cluster-config.values.yaml`.

## External reset already done

- [x] Destroy the old `cluster-infra-argocd` managed releases and bootstrap objects.
- [x] Clear the finalizers that blocked that destroy.

## Resolve the `apps/argocd` collision

- [x] Move `apps/argocd/repos.yaml` verbatim into `apps/infra/argocd/chart/templates/repos.yaml`.
- [x] Delete `apps/argocd/application.yaml`.
- [x] Delete `apps/argocd/repos.yaml`.
- [x] Delete `apps/argocd/` if it is empty afterward.
- [x] Confirm only one Argo `Application` named `argocd` remains in Git.

## Top-level sequencing via `RollingSync`

- [x] Add `code.org/bootstrap-group=infra` to `apps/infra/application.yaml`.
- [x] Add `code.org/bootstrap-group=post-infra` to `apps/kargo/application.yaml`.
- [x] Update `apps/app-of-apps/applicationset.yaml` so wrapper `Application`s generated from `apps/*/applicationset.yaml` are labeled `code.org/bootstrap-group=post-infra`.
- [x] Add `spec.strategy.type: RollingSync` to `apps/app-of-apps/applicationset.yaml`.
- [x] Add `spec.strategy.deletionOrder: Reverse` to `apps/app-of-apps/applicationset.yaml`.
- [x] Add a first `RollingSync` step that matches `code.org/bootstrap-group In [infra]`.
- [x] Add a second `RollingSync` step that matches `code.org/bootstrap-group In [post-infra]`.
- [x] Keep the internal `apps/infra/*` sync-wave annotations unchanged.
- [x] Do not add top-level sync-wave annotations for `infra`, `kargo`, or generated wrapper apps.

## Argo health and controller config

- [x] Add `applicationsetcontroller.enable.progressive.syncs: "true"` under `argo-cd.configs.params` in the copied Argo chart values.
- [x] Restore `resource.customizations.health.argoproj.io_Application` under `argo-cd.configs.cm` in the copied Argo chart values.
- [x] Use the stable Argo docs `Argocd App` Lua snippet without changing its behavior.
- [x] Keep the existing Kargo `Project` health customization in place.

## `code-dot-org` bootstrap changes

- [x] Add `argocd-bootstrap.tf` in `/Users/seth/src/code-dot-org/k8s/tofu/codeai-k8s/cluster-infra-argocd`.
- [x] Make `argocd-bootstrap.tf` fetch the `k8s-gitops` default branch with a shallow sparse clone limited to `apps/infra/argocd/`.
- [x] Point the bootstrap `helm_release` at the sparse-cloned `apps/infra/argocd/chart`.
- [x] Keep the bootstrap release name `argocd` and namespace `argocd`.
- [x] Keep the bootstrap `helm_release` managed in Tofu after Argo self-management starts.
- [x] Make `argocd-app-of-apps-bootstrap.tf` depend on the bootstrap `helm_release`.
- [x] Keep `deploy_helm_charts` controlling only the legacy `helm.tf` releases.
- [x] Ensure default apply with `deploy_helm_charts=false` plans bootstrap only, not the legacy Helm releases.

## Docs and tracking files

- [x] Rewrite `apps/infra/implementation-plan.md` for the bootstrap-and-`RollingSync` design.
- [ ] Refresh `apps/infra/implementation-plan.md` again if the design changes materially.
- [ ] Refresh this checklist again if the design changes materially.
- [x] Update `README.md` so `apps/argocd` is gone and repo secrets are documented under `apps/infra/argocd/chart/templates/`.

## Final validation and rollout

- [x] Review the diffs one more time for accidental non-verbatim chart edits.
- [x] Run `git diff --check` again after the collision, `RollingSync`, and health changes land.
- [x] Re-run `helm template` for `apps/infra/argocd/chart` after moving `repos.yaml`.
- [x] Confirm `apps/app-of-apps/applicationset.yaml` contains the `RollingSync` strategy and wrapper-app `code.org/bootstrap-group` label.
- [x] Confirm `apps/infra/argocd/chart/values.yaml` contains `applicationsetcontroller.enable.progressive.syncs: "true"`.
- [x] Confirm `apps/infra/argocd/chart/values.yaml` contains `resource.customizations.health.argoproj.io_Application`.
- [ ] Commit the `k8s-gitops` changes.
- [ ] Push the branch or `main`, as appropriate.
- [x] Update `code-dot-org` with the bootstrap changes.
- [x] Run `tofu validate` in `/Users/seth/src/code-dot-org/k8s/tofu/codeai-k8s/cluster-infra-argocd`.
- [ ] Rebootstrap Argo and `app-of-apps` from `code-dot-org`.
- [ ] Refresh the Argo `infra` application after the bootstrap apply.
- [ ] Sync the Argo `infra` application if refresh does not move it to the new Git revision.
- [ ] Verify top-level `infra` reaches `Healthy` before the `post-infra` group proceeds.
- [ ] Verify `kargo` and the `codeai` wrapper app both land in the `post-infra` group.
- [ ] Verify the internal `infra` child apps still follow the existing `0/1/2/3` order.
- [ ] Verify repo secrets from the moved `repos.yaml` appear in `argocd`.
- [ ] Verify `apps/infra/argocd/application.yaml` becomes healthy and manages the same Argo resources as the bootstrap release.
