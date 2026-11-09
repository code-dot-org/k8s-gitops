# Scope and conventions

Two repositories. Tasks 1-3 are edits in `code-dot-org` (two PRs to `staging`, branches to be named by the user: the legacy release change first, the tag workflow second). Tasks 4-5 are edits in `k8s-gitops`. Task 6 is rollout, and it interleaves the repositories: the Warehouse commit (task 6.2) precedes the merge of PR B (task 3.4).

Tasks marked **(user)** need an action only the user takes: git commit and push, PR merge, a `workflow_dispatch` run, a Kargo promotion. Everything else is file editing plus local, read-only verification. Nothing in this list runs `kubectl` mutations or `tofu`.

Prerequisite: `gate-production-freight-on-legacy-production` is rolled out (the gate step passed on a manual promotion from the runbook) and archived, so the two modified specs exist under `openspec/specs/`.

## 1. code-dot-org: the release names the deployed revision

- [ ] 1.1 In `bin/create-release`, add `--commit <sha>` and pass it as `target_commitish` to `Octokit.create_release`; keep `production` as the default when the option is absent
- [ ] 1.2 In `lib/rake/infra.rake` `publish_github_release`, pass the build's revision (`RakeUtils.git_revision`, the checkout `ci_build` recorded) with `--commit`
- [ ] 1.3 **(user)** Open PR A to `staging` from the chosen branch, get review from the legacy deploy owners, merge. After the next DTP carries it to `production`, confirm on the following release that the tag's commit equals the revision the daemon announced in Slack

## 2. code-dot-org: production tag script

- [ ] 2.1 Add `docker/rails/tag-production-image.sh` taking a release tag and optional `--image-commit`, `--replace-alias`, `--move-live-tag`, `--dry-run`:
  - check eligibility: not draft or prerelease, tag format, release commit is a merge commit with `compare/production...<sha>` `ahead_by` 0
  - resolve the image commit from `gh api .../compare/staging...<release sha>` `.merge_base_commit.sha`
  - or validate an override with `compare/<release sha>...<override>` `ahead_by` 0
- [ ] 2.2 Resolve `ghcr.io/code-dot-org/cdo-rails:git-<sha>` to a digest once with `regctl manifest head`:
  - on not-found, fail before any write and list up to thirty ancestors (`.../commits?sha=<sha>&per_page=30`) that have images
  - on auth errors, timeouts or 5xx, fail as "cannot determine" with no suggestions
- [ ] 2.3 Validate the index by digest (OCI index media type, revision annotation equal to the commit, both platform descriptors), then write in order:
  - alias `release-<tag>` by digest: no-op if it already points at the digest, fail if it differs unless `--replace-alias`; read back
  - forward-only check: read the revision annotation of the index `production` currently resolves to; `gh api .../compare/<live revision>...<image commit>` must report `behind_by` 0 and the release commit must still be contained in `production`; otherwise stop after the alias unless `--move-live-tag`
  - an absent `production` tag proceeds; a live index without annotation, or a live revision GitHub does not know, fails as "cannot determine" before any write
  - live tag `production` by digest; read back
- [ ] 2.4 Classify every exit: "nothing published" for failures before the live copy, "outcome unknown, inspect registry and Kargo" for failures at or after it. Write a job summary (release, release commit, image commit, digest, alias state, live tag state, class) when `GITHUB_STEP_SUMMARY` is set
- [ ] 2.5 Run `--dry-run` locally and record the outputs for each case:
  - the latest release
  - a release behind the live revision (alias only)
  - no `production` tag yet (proceeds)
  - a live index without a revision annotation (cannot determine)
  - a prerelease (ineligible)
  - a release whose merge base has no image (candidates listed)
  - a simulated registry auth failure (no candidates)
  - an override inside the release, and an override ahead of the release
  - a release whose alias already matches, and a release whose alias conflicts

## 3. code-dot-org: workflow and docs

- [ ] 3.1 Add `.github/workflows/cdo-rails-production-tag.yml`:
  - `on: release: types: [published]` and `workflow_dispatch` (`release_tag` required; `image_commit`, `replace_alias`, `move_live_tag`, `dry_run` optional)
  - `concurrency: {group: cdo-rails-production-tag, cancel-in-progress: false, queue: max}`; `queue: max` keeps every queued run, where the default cancels the pending run whenever another is queued
  - permissions `contents: read`, `packages: write`
  - steps: shallow checkout, SHA-pinned `regclient/actions/regctl-installer`, the same SHA-pinned `docker/login-action` to ghcr.io the image workflow uses, then the script with `${{ github.event.release.tag_name || inputs.release_tag }}` and the inputs mapped to flags
- [ ] 3.2 Add a final step with `if: failure() || cancelled()` that posts the release, the last stage completed and the outcome class to the notification channel the team designates (mechanism per the open question); a run cancelled after the live copy reports outcome unknown. Add a header comment explaining that the workflow runs at the release's tag commit and becomes active only after a DTP carries it to `production`
- [ ] 3.3 Extend the tag contract in `docker/rails/README.md` with `production` and `release-<tag>`: who moves them, what they guarantee, that the Kargo production Warehouse follows `production`, and that a digest is the only immutable handle
- [ ] 3.4 **(user)** Open PR B to `staging` from the chosen branch and get review. Merge only once the Warehouse commit (task 6.2) is in place, and continue straight into tasks 3.5 and 6.3 in the same sitting: `workflow_dispatch` is available as soon as the file is on `staging`, the default branch, and the first release-triggered run happens only after the next DTP
- [ ] 3.5 **(user)** Exercise the workflow from `staging`, right after the merge and before seeding:
  - run `workflow_dispatch` with `release_tag` set to the latest release and `dry_run` true; confirm the summary names the expected commit and digest and that neither tag exists or changed
  - trigger one deliberate failure (a bogus `release_tag`) and confirm the notification arrives
  - do not run it for real for the latest release here: that would create the `production` tag at the current release before the previous one is seeded (task 6.3)

## 4. k8s-gitops: Warehouse, Stage and policy

- [ ] 4.1 Add `apps/kargo/projects/codeai/warehouse-production.yaml`: Warehouse `kargo-project-codeai-production`, image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest`, `constraint: production`, with a comment pointing at the release workflow and the runbook. This file lands in its own commit before the Stage switch (task 6.2)
- [ ] 4.2 In `apps/kargo/projects/codeai/stages/production.yaml`, change `requestedFreight` to origin `kargo-project-codeai-production` with `sources: {direct: true}`. Keep the gate step first and the rest of the template unchanged. Update the header comment to describe the automated path. This and 4.3 land in the second commit (task 6.6)
- [ ] 4.3 In `apps/kargo/projects/codeai/project-config.yaml`, set `autoPromotionEnabled: true` for `production` with a comment naming it as the one-line pause switch
- [ ] 4.4 Update `apps/kargo/projects/codeai/README.md`: two Warehouses, what feeds production, where the trigger lives, how to pause, how to roll back
- [ ] 4.5 Render or lint the Kargo manifests the way the repository's existing checks do, and confirm the project Application's recursive directory source will include the new file

## 5. k8s-gitops: runbook

- [ ] 5.1 Rewrite `docs/production-promotion.md` per the modified runbook spec, covering:
  - the automated path and its expected delay
  - mapping a release to a digest and a digest to a release
  - checking whether the `latest` Warehouse holds Freight with the same digest verified in `test`, and what it means when it does not
  - post-promotion checks
  - rollback: manual promotion of an older production Freight; the destructive-migration review of the migrations added between the two commits, every time; the auto-promotion hold Kargo records; that later releases do not promote while it stands; how to resume (promote the newest Freight by hand or use the Stage's Resume action)
  - pause and resume: disabling clears any hold; restoring promotes the newest Freight at once if it is not current
  - failure signatures and recoveries: workflow failed before the live copy (nothing changed, re-run); failed or cancelled after it (inspect registry and Kargo first); Promotion failed at `legacy-ancestry` (not retried; the message and HTTP status say why; a transient cause means promoting the same Freight by hand; a wrong digest means a corrected tag move, with `move_live_tag` when the corrected commit is older than what is live)
  - the hotfix caveat, and a manually created release
  - the accepted gaps carried over from step one: a legacy migration rollback (answered by promoting the matching older Freight) and hand edits to the values file (which bypass the gate)
- [ ] 5.2 Add a history section entry format (release tag, release commit, image commit, digest, Freight, date, anything unusual) for the rollout tasks to fill in

## 6. Rollout

- [ ] 6.1 **(user)** Confirm the entry criteria: the gate step passed on a manual promotion; the release tag observed naming the deployed revision (task 1.3)
- [ ] 6.2 **(user)** Commit and push k8s-gitops commit 1 (the Warehouse only), before PR B merges (task 3.4). Refresh the `kargo-project-codeai` Argo Application. Confirm with read-only `kubectl get warehouse -n kargo-project-codeai` that it exists and is watching the `production` tag, and with read-only `kubectl get freight -n kargo-project-codeai` that it holds no Freight, since the tag does not exist yet
- [ ] 6.3 **(user)** Seed the Warehouse right after task 3.5: dispatch the workflow for the previous eligible release (the `production` tag does not exist, so no `move_live_tag`), wait for Freight, then dispatch for the latest release and wait again. Then confirm:
  - with `docker buildx imagetools inspect --raw` that `production` and `release-<latest tag>` resolve to the same OCI index with the expected digest and revision annotation
  - with read-only `kubectl get freight -n kargo-project-codeai --sort-by=.metadata.creationTimestamp` (columns `.origin.name`, `.images[0].digest`, `.images[0].annotations`) that the production Warehouse holds two Freight, the older with the previous release's digest and the newer with the latest release's
  - that production still sources from the shared Warehouse, so nothing promoted
  - if `production` already exists when seeding starts, do not dispatch for the previous release: dispatch for the latest release only and note that the rollback target arrives with the next release
- [ ] 6.4 **(user)** Wait for the next DTP to carry the workflow to `production`. Confirm its release ran the workflow unattended: the run succeeded, the alias and tag were written, and the production Warehouse gained a newer Freight with that release's digest
- [ ] 6.5 **(user)** Pre-switch check, mandatory: with the read-only command from task 6.3, confirm the newest production-Warehouse Freight carries the digest `production` currently resolves to, that this is the latest release's digest, and that an older Freight exists; confirm the notification was observed (task 3.5). If the newest Freight is not the latest release, stop: do not switch, delete or edit nothing by hand, wait for the next release and check again
- [ ] 6.6 **(user)** Commit and push k8s-gitops commit 2 (Stage switch, policy, README, runbook). Refresh `kargo-project-codeai`. Confirm with read-only `kubectl get promotion,stage -n kargo-project-codeai` that one Promotion was created for `production`, the gate step passed, `git-commit` reported `Skipped` if the digest was already deployed, and the Stage is Healthy with the newest Freight current
- [ ] 6.7 Observe the next real release end to end (release published, workflow run, alias and tag written, Freight created, Promotion succeeded, pods rolled) and record the timings and the Warehouse refresh delay in the runbook's history section
- [ ] 6.8 **(user, optional)** Rollback drill: review the migrations between the two releases, promote the previous production Freight by hand, confirm the Stage shows an auto-promotion hold and Kargo does not re-promote the newest, then promote the newest again and confirm the hold clears. Record the signature in the runbook
