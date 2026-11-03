# Scope and conventions

Two repositories. Task 1 is edits in `code-dot-org` (one PR to `staging`, branch to be named by
the user); task 2 lands and verifies it. Tasks 3-4 are edits in `k8s-gitops` on
`INF-2281/promotion-gates`. Task 5 is rollout. Tasks marked **(user)** need an action only the
user takes: git commit and push, PR merge, or a Kargo promotion. Everything else is file editing
plus local, read-only verification. Nothing in this list runs `kubectl` mutations or `tofu`.

## 1. code-dot-org: image provenance

- [ ] 1.1 In the `merge` job of `.github/workflows/cdo-rails-image.yml`, install regctl from a SHA-pinned `regclient/actions/regctl-installer`, replace `docker buildx imagetools create` with one `regctl index create "$IMAGE:git-$SHA" --ref "$IMAGE:git-$SHA-amd64" --ref "$IMAGE:git-$SHA-arm64" --annotation "org.opencontainers.image.revision=$SHA"`, inspect that index and fail the job unless the media type is the OCI index, the annotation equals `github.sha`, and both platform descriptors are present, and only then `regctl image copy` it to `latest` and every other tag in `$TAGS` (document the `--desc-platform` two-step and the skopeo fallbacks in a comment)
- [ ] 1.2 Update the tag contract in `docker/rails/README.md`: add the revision annotation and correct the `git-<sha>` guarantee, which is repointed when the `cdo-deps` chain or a manual dispatch rebuilds that commit; a digest is the only immutable handle

## 2. code-dot-org: land and verify

- [ ] 2.1 **(user)** Open the PR to `staging` from the chosen branch, get review, merge
- [ ] 2.2 After the first `latest` publish post-merge, confirm with `docker buildx imagetools inspect --raw` that the index is OCI, annotated with the staging SHA and lists both platforms; confirm `docker pull` on amd64 and arm64; confirm with read-only `kubectl get freight -n kargo-project-codeai` that the newest Freight carries the annotation and that a staging pod pulled it

## 3. k8s-gitops: Kargo gate

- [ ] 3.1 Insert one `http` step, `legacy-ancestry`, as the first step of the promotion template in `apps/kargo/projects/codeai/stages/production.yaml`, calling GitHub compare `production...${{ imageFrom("ghcr.io/code-dot-org/cdo-rails").Annotations["org.opencontainers.image.revision"] }}` with a 30-second request timeout and a 5-minute retry timeout: success `response.status == 200 && response.body.ahead_by == 0`, failure `response.status == 404 || response.status == 422 || (response.status == 200 && response.body.ahead_by > 0)`, and an `errorExpression` that renders `no revision annotation, or GitHub does not know the commit (HTTP <status>)` for 404 and 422 and `image commit is <ahead_by> commit(s) ahead of legacy production (<status>)` for 200; add a header comment explaining the step and linking to the runbook
- [ ] 3.2 Add `apps/kargo/projects/codeai/README.md` describing the Stages, the production gate and linking to the runbook; confirm the Application's directory include still selects only `application.yaml`

## 4. k8s-gitops: runbook

- [ ] 4.1 Write `docs/production-promotion.md` per the runbook spec: the rule and the gate; when to promote (only after the GitHub release for the DTP that carried the commit exists, which closes the window between the merge and `db:migrate`); pre-promotion checks; post-promotion checks (pods `Running`, and whatever application-level health signal exists at the time); rollout and rollback timing with the 2100-second grace period; rollback procedure (review of the migrations added between the two commits for destructive changes, every time); failure signatures in Kargo (the `legacy-ancestry` message and HTTP status and what each means, with the compare URL to run by hand); the hotfix caveat; the accepted gaps (a legacy migration rollback, answered by re-promoting the Freight whose commit matches the rolled-back branch; hand edits to the values file, which bypass the gate and are not a sanctioned path); and the NetworkPolicy allowance a future default-deny policy must keep for the Kargo controller

## 5. Rollout

- [ ] 5.1 **(user)** Commit and push the k8s-gitops changes; refresh the `kargo-project-codeai` Argo Application, which owns the Stage, and sync if it has not moved; confirm with read-only `kubectl get stage production -n kargo-project-codeai -o yaml` that the step and its three expressions are present
- [ ] 5.2 **(user)** Rehearse the Kargo step on `levelbuilder` before production is enabled: temporarily add the step, promote an unannotated Freight (expect failure with HTTP 404 and the no-revision message), the newest Freight (expect failure with HTTP 200 and the ahead-by message) and the Freight whose annotation equals `git merge-base production staging` (expect the step to pass), record the three Promotion statuses in the runbook as reference signatures, then remove the step
- [ ] 5.3 **(user)** After the production deployment has been enabled with `branch: production`, perform the first production promotion following the runbook: wait for the release of the DTP that carried the Freight's commit, promote, and confirm the pods are `Running`
- [ ] 5.4 Record the first promotion's date and Freight in the runbook's history section
