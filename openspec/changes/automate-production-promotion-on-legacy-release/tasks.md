# Scope and conventions

Two repositories. Tasks 1-3 are edits in `code-dot-org` (two PRs to `staging`, branches to be
named by the user: the legacy release change first, the tag workflow second). Tasks 4-5 are
edits in `k8s-gitops`. Task 6 is rollout. Tasks marked **(user)** need an action only the user
takes: git commit and push, PR merge, a `workflow_dispatch` run, a Kargo promotion. Everything
else is file editing plus local, read-only verification. Nothing in this list runs `kubectl`
mutations or `tofu`.

Prerequisite: `gate-production-freight-on-legacy-production` is rolled out (production in
`enforce`, both gate steps passed on a manual promotion from the runbook) and archived, so the
two modified specs exist under `openspec/specs/`.

## 1. code-dot-org: the release names the deployed revision

- [ ] 1.1 In `bin/create-release`, add `--commit <sha>` and pass it as `target_commitish` to `Octokit.create_release`; keep `production` as the default when the option is absent
- [ ] 1.2 In `lib/rake/infra.rake` `publish_github_release`, pass the build's revision (`RakeUtils.git_revision`, the checkout `ci_build` recorded) with `--commit`
- [ ] 1.3 **(user)** Open PR A to `staging` from the chosen branch, get review from the legacy deploy owners, merge; after the next DTP carries it to `production`, confirm on the following release that the tag's commit equals the revision the daemon announced in Slack

## 2. code-dot-org: production tag script

- [ ] 2.1 Add `docker/rails/tag-production-image.sh` taking a release tag and optional `--image-commit`, `--replace-alias`, `--move-live-tag`, `--dry-run`: check eligibility (not draft or prerelease, tag format, release commit is a merge commit with `compare/production...<sha>` `ahead_by` 0); resolve the image commit from `gh api .../compare/staging...<release sha>` `.merge_base_commit.sha`, or validate an override with `compare/<release sha>...<override>` `ahead_by` 0
- [ ] 2.2 Resolve `ghcr.io/code-dot-org/cdo-rails:git-<sha>` to a digest once with `regctl manifest head`; on not-found, fail before any write and list up to thirty ancestors (`.../commits?sha=<sha>&per_page=30`) that have images; on auth errors, timeouts or 5xx fail as "cannot determine" with no suggestions
- [ ] 2.3 Validate the index by digest (OCI index media type, revision annotation equal to the commit, both platform descriptors), then write in order: alias `release-<tag>` by digest (no-op if it already points at the digest, fail if it differs unless `--replace-alias`), read back, freshness check (`gh api .../releases/latest` is this release and its commit is still contained in `production`, else stop after the alias unless `--move-live-tag`), live tag `production` by digest, read back
- [ ] 2.4 Classify every exit: "nothing published" for failures before the live copy, "outcome unknown, inspect registry and Kargo" for failures at or after it; write a job summary (release, release commit, image commit, digest, alias state, live tag state, class) when `GITHUB_STEP_SUMMARY` is set
- [ ] 2.5 Run `--dry-run` locally for: the latest release; an older release (alias only); a prerelease (ineligible); a release whose merge base has no image (candidates listed); a simulated registry auth failure (no candidates); an override inside the release; an override ahead of the release; a release whose alias already matches; a release whose alias conflicts; and record the outputs

## 3. code-dot-org: workflow and docs

- [ ] 3.1 Add `.github/workflows/cdo-rails-production-tag.yml` with `on: release: types: [published]` and `workflow_dispatch` (`release_tag` required; `image_commit`, `replace_alias`, `move_live_tag` optional); `concurrency: {group: cdo-rails-production-tag, cancel-in-progress: false}`; permissions `contents: read`, `packages: write`; steps: shallow checkout, SHA-pinned `regclient/actions/regctl-installer`, the same SHA-pinned `docker/login-action` to ghcr.io the image workflow uses, the script with `${{ github.event.release.tag_name || inputs.release_tag }}` and the inputs mapped to flags
- [ ] 3.2 Add a final step with `if: failure()` that posts the release, the last stage completed and the outcome class to the notification channel the team designates (mechanism per the open question), and a header comment explaining that the workflow runs at the release's tag commit and becomes active only after a DTP carries it to `production`
- [ ] 3.3 Extend the tag contract in `docker/rails/README.md` with `production` and `release-<tag>`: who moves them, what they guarantee, that the Kargo production Warehouse follows `production`, and that a digest is the only immutable handle
- [ ] 3.4 **(user)** Open PR B to `staging` from the chosen branch, get review, merge; wait for the next DTP to carry the workflow to `production`
- [ ] 3.5 **(user)** Run `workflow_dispatch` from the `production` branch with `release_tag` set to the latest release and `--dry-run` semantics if the script exposes them through an input; otherwise run it for the latest release and confirm with `docker buildx imagetools inspect --raw` that `production` and `release-<tag>` resolve to the same OCI index with the expected digest and revision annotation; trigger one deliberate failure (a bogus `release_tag`) and confirm the notification arrives

## 4. k8s-gitops: Warehouse, Stage and policy

- [ ] 4.1 Add `apps/kargo/projects/codeai/warehouse-production.yaml`: Warehouse `kargo-project-codeai-production`, image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest`, `constraint: production`, with a comment pointing at the release workflow and the runbook; this file lands in its own commit before the Stage switch (task 6.2)
- [ ] 4.2 In `apps/kargo/projects/codeai/stages/production.yaml`, change `requestedFreight` to origin `kargo-project-codeai-production` with `sources: {direct: true}`; keep the two gate steps first and the rest of the template unchanged; update the header comment to describe the automated path; this and 4.3 land in the second commit (task 6.4)
- [ ] 4.3 In `apps/kargo/projects/codeai/project-config.yaml`, set `autoPromotionEnabled: true` for `production` with a comment naming it as the one-line pause switch
- [ ] 4.4 Update `apps/kargo/projects/codeai/README.md`: two Warehouses, what feeds production, where the trigger lives, how to pause, how to roll back
- [ ] 4.5 Render or lint the Kargo manifests the way the repository's existing checks do and confirm the project Application's recursive directory source will include the new file

## 5. k8s-gitops: runbook

- [ ] 5.1 Rewrite `docs/production-promotion.md` per the modified runbook spec: the automated path and its expected delay; mapping release to digest and digest to release; checking whether the `latest` Warehouse holds Freight with the same digest verified in `test` and what it means when it does not; post-promotion checks; rollback (manual promotion of an older production Freight, the destructive-migration review of the migrations added between the two commits every time, Kargo does not undo it, automation resumes at a release with a new digest); pause and resume; failure signatures and recoveries (workflow failed before the live copy: nothing changed, re-run; after it: inspect registry and Kargo first; Promotion failed at a gate step: not retried, transient cause means promote the same Freight by hand, wrong digest means a corrected tag move; `Init:Error`; Argo `Degraded`); the hotfix caveat; a manually created release; emergency `warn`; and the staging/test verification note
- [ ] 5.2 Add a history section entry format (release tag, release commit, image commit, digest, Freight, date, anything unusual) for the rollout tasks to fill in

## 6. Rollout

- [ ] 6.1 **(user)** Confirm the entry criteria: production in `enforce`; both gate steps passed on a manual promotion; the release tag observed naming the deployed revision (task 1.3); the notification observed on a deliberate failure (task 3.5)
- [ ] 6.2 **(user)** Commit and push k8s-gitops commit 1 (the Warehouse only); refresh the `kargo-project-codeai` Argo Application; confirm with read-only `kubectl get warehouse -n kargo-project-codeai` that it exists and is watching the `production` tag
- [ ] 6.3 **(user)** Seed: dispatch the workflow for the previous eligible release with `move_live_tag: true`, wait for Freight, then dispatch for the latest release; confirm with read-only `kubectl get freight -n kargo-project-codeai` that the production Warehouse holds two Freight with the expected digests and annotations, and that production still sources from the shared Warehouse so nothing promoted
- [ ] 6.4 **(user)** Commit and push k8s-gitops commit 2 (Stage switch, policy, README, runbook); refresh `kargo-project-codeai`; confirm with read-only `kubectl get promotion,stage -n kargo-project-codeai` that one Promotion was created for `production`, both gate steps passed, `git-commit` reported `Skipped` if the digest was already deployed, and the Stage is Healthy with the newest Freight current
- [ ] 6.5 Observe the next real release end to end (release published, workflow run, alias and tag written, Freight created, Promotion succeeded, pods rolled, `schema-guard` log clean) and record the timings and the Warehouse refresh delay in the runbook's history section
- [ ] 6.6 **(user, optional)** Rollback drill: review the migrations between the two releases, promote the previous production Freight by hand, confirm Kargo does not re-promote the newest, then promote the newest again; record the signature in the runbook
