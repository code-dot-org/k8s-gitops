# apps/infra implementation checklist

This file tracks the current state of the `apps/infra` port. If the thread is interrupted, refresh this file first, then continue.

## Repository structure

- [x] Replace the placeholder `apps/infra` structure with the parent and child application layout.
- [x] Add `apps/infra/charts/eso-per-env/` as the shared chart-only directory.
- [x] Delete the old placeholder `.gitkeep` files under `apps/infra/**`.

## Chart copies

- [x] Copy `networking` into `apps/infra/networking/chart/`.
- [x] Copy `external-secrets-operator` into `apps/infra/external-secrets-operator/chart/`.
- [x] Copy `external-dns` into `apps/infra/external-dns/chart/`.
- [x] Copy `argocd` into `apps/infra/argocd/chart/`.
- [x] Copy `kargo-secrets` into `apps/infra/kargo-secrets/chart/`.
- [x] Copy `standard-envtypes` into `apps/infra/standard-envtypes/chart/`.
- [x] Copy `dex` into `apps/infra/dex/chart/`.
- [x] Copy `eso-per-envtype` into `apps/infra/charts/eso-per-env/`.
- [x] Update the copied `standard-envtypes` chart to use `file://../../charts/eso-per-env`.

## Child applications

- [x] Write `apps/infra/networking/application.yaml` with wave `0` and namespace `kube-system`.
- [x] Write `apps/infra/external-secrets-operator/application.yaml` with wave `1` and namespace `external-secrets`.
- [x] Write `apps/infra/external-dns/application.yaml` with wave `1` and namespace `external-dns`.
- [x] Write `apps/infra/argocd/application.yaml` with wave `2` and namespace `argocd`.
- [x] Write `apps/infra/kargo-secrets/application.yaml` with wave `2` and namespace `kargo-system-resources`.
- [x] Write `apps/infra/standard-envtypes/application.yaml` with wave `2` and namespace `external-secrets`.
- [x] Write `apps/infra/dex/application.yaml` with wave `3` and namespace `dex`.
- [x] Make every child application load `apps/infra/codeai-cluster-config.values.yaml`.

## Parent application and docs

- [x] Rewrite `apps/infra/application.yaml` to point only at child `application.yaml` files.
- [x] Exclude `apps/infra/charts/` from the parent app.
- [x] Do not create an `eso-per-env` application.
- [x] Update `README.md` to describe the new `apps/infra` layout.
- [x] Write `apps/infra/implementation-plan.md`.
- [x] Write `apps/infra/implementation-checklist.md`.

## Local validation

- [x] `git diff --check` is clean for the current local changes.
- [x] `helm template` succeeds for all seven copied charts against `apps/infra/codeai-cluster-config.values.yaml`.

## Remaining work

- [ ] Review the generated diffs one more time for accidental non-verbatim chart edits.
- [ ] Commit the `k8s-gitops` changes.
- [ ] Push the branch or `main`, as appropriate.
- [ ] Refresh the Argo `infra` application after the push.
- [ ] Sync the Argo `infra` application if refresh does not move it to the new Git revision.
- [ ] Verify all seven child applications become `Synced` and `Healthy`.
- [ ] Remove OpenTofu ownership of the seven migrated `helm_release` resources without uninstalling them.
- [ ] Remove the obsolete `helm_release` blocks from `code-dot-org/k8s/tofu/codeai-k8s/cluster-infra-argocd/helm.tf`.
