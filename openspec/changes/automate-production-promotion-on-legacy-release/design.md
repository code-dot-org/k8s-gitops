## Context

**Starting point.** After `gate-production-freight-on-legacy-production` (step one) is rolled out, the `codeai` Kargo project, on Kargo 1.12.5 with its admission webhooks enabled, looks like this:

- One Warehouse (`kargo-project-codeai`) follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest.
- Every image index carries `org.opencontainers.image.revision`, naming the `staging` commit it was built from.
- `staging` and `test` auto-promote.
- `production` requests Freight verified in `test` and has `autoPromotionEnabled: false`. Its promotion template runs the gate step `legacy-ancestry` before `git-clone`, `yaml-update`, `git-commit`, `git-push` and `argocd-update`.
- The gate compares `production...<revision>` on GitHub. It passes only on 200 with `ahead_by == 0`, and fails on 404, 422 or `ahead_by > 0` with a message naming the cause.
- A person promotes by following `docs/production-promotion.md`, after the release for the DTP that carried the commit exists.

**How legacy production deploys (DTP, "deploy to production").** `bin/dotd` merges a candidate into the `production` branch. The `ci_build` daemon pulls, records the revision it is about to deploy, and runs `infra:all`: chef, `db:migrate`, seed, worker restart, assets, a rolling AMI replacement of about 45 minutes, and a CDN flush. The final task, `publish_github_release`, runs `bin/create-release --force`, which creates a GitHub release through the API with a tag of the form `vYYYY-MM-DD.N`. `create-release` exits without a release when production HEAD is not a merge commit, so hotfixes (direct pushes) never produce one.

Two details matter:

- `create-release` passes `target_commitish: production`, which GitHub resolves to the branch tip at that moment, not to the revision the daemon deployed. If a second DTP lands during the deploy, the release names a commit that has not finished deploying. Only the test daemon checks for a revision change during its build.
- The release's changelog is already computed from the local checkout. Tagging the deployed revision therefore also makes the release consistent with its own notes.

With that fix, the release is the one machine-readable signal meaning "legacy production finished deploying this commit".

**Which image a release maps to.** The staging commit a release contains is the merge base of `staging` and the release commit, which the GitHub compare API returns as `merge_base_commit`. That commit is the head of a push to `staging`, so CI normally published `cdo-rails:git-<sha>` for it. `git-<sha>` is not an immutable handle, though. The image workflow also runs after each weekly `cdo-deps` publish and on manual dispatch, both on the default branch, and republishes `git-<sha>` and `latest` with new bytes.

**Why no digest is known to have run in test.** Only a digest pins bytes. A rebuilt digest may never have been seen by the `latest` Warehouse. Even a first-build digest can be skipped when `latest` moves twice between Warehouse refreshes, or when a Stage was unhealthy at the time. So no digest can be assumed to have run in staging or test.

**Kargo 1.12.5 behaviour this design relies on**, verified in source:

- For each requested origin, auto-promotion takes as candidate the newest available Freight by discovery time. It skips when the candidate is already current or already awaited. It stands down while any Promotion for that Freight is still in flight. It skips a Freight whose newest terminal Promotion did not succeed, so a failed auto-promotion is never retried by Kargo.
- Manual promotions carry auto-promotion intent, stamped by the mutating webhook. Promoting Freight other than the current candidate stamps hold intent; promoting the candidate stamps resume intent. Once such a Promotion is terminal and not aborted, the Stage records or clears a hold for that origin.
- While a hold stands, nothing from that origin is auto-promoted, including Freight from later releases, until a manual Promotion of the current candidate succeeds or the UI's Resume action is used.
- Holds are cleared whenever auto-promotion is disabled for the Stage. Re-enabling it starts fresh and promotes the newest Freight at once if it is not current.
- A Warehouse with the Digest strategy creates Freight only for a digest it has not produced before.
- The `git-commit` step returns `Skipped` with the existing commit ID when the working tree has no diffs. A promotion that writes the digest already in `values.yaml` is a clean no-op.
- The GitHub webhook receiver refreshes Warehouses on `package` events, and Warehouses also poll on an interval.

**GitHub behaviour this design relies on.** `release: published` fires for prereleases too. A `release` workflow runs the workflow file at the release's tag commit. `workflow_dispatch` becomes available as soon as the workflow file is on `staging`, the default branch, and runs the file as it is on the branch chosen.

**Actions concurrency.** A `concurrency` group runs one workflow at a time. By default it holds a single pending run: when another run is queued, the pending one is cancelled before any of its steps execute, so a step that runs on failure never fires. Since May 2026, `queue: max` keeps up to 100 queued runs instead of replacing the pending one; it cannot be combined with `cancel-in-progress: true`. Neither setting orders the queued runs.

## Goals / Non-Goals

**Goals:**

- Promote to `production`, without a person, the exact image built from the staging commit each legacy production release contains, within minutes of the release.
- Keep the gate from step one in force on every automatic promotion, and never promote before the legacy deploy, migrations included, has finished.
- Never move the live tag to an unvalidated digest, never move it backward because of run ordering, and never leave it changed by a run that then fails silently.
- Keep rollback a one-step manual action in Kargo that the automation does not fight, with the same compatibility review every time, and make resuming after it a deliberate step.
- Make the automation pausable with one reviewed commit, and auditable from the release, the registry and the Freight.
- Tell a person whenever a release did not produce a promotion.

**Non-Goals:**

- Promoting hotfixes that bypass a release. They do not move the merge base, so k8s production stays one step behind until the next DTP. That is safe: an older image has no unapplied migration prerequisites.
- Falling back automatically to an older image when the exact one is missing. That is an operator decision after a compatibility review.
- Guaranteeing in Kargo that the promoted digest ran in `test`. The in-cluster promoter alternative below provides it and is not chosen.
- Changing how `staging`, `test` or `levelbuilder` select or promote Freight. Making k8s test follow the legacy `test` branch is a separate follow-up.
- Narrowing who may promote, or adding verification processes to the production Stage.
- Any new in-cluster component.

## Decisions

### 1. The trigger is the GitHub release, and the release must name the deployed revision

The release is created by the last task of `infra:all` on a production host, after `db:migrate`, the fleet replacement and the CDN flush, and only for merge commits. Triggering on it means "legacy production is running this" rather than "this was merged into `production`". A legacy build that fails after the merge produces no release and so no k8s promotion.

That claim holds only if the release tags the revision the daemon deployed. Today it tags the branch tip at release time. The prerequisite change in code-dot-org is small: `publish_github_release` passes the revision `ci_build` recorded (`RakeUtils.git_revision`, the local checkout's HEAD during the whole build) to `bin/create-release --commit <sha>`, which uses it as `target_commitish`. GitHub accepts a SHA there. Interactive use of `create-release` is unchanged. This is a change in the legacy deploy path and needs its owners' review. It also fixes the existing mismatch between the tag and the changelog.

The workflow treats a release as eligible only when:

- it is not a draft or prerelease;
- its tag matches `^v\d{4}-\d{2}-\d{2}\.\d+$`;
- its commit is a merge commit contained in `production` (compare `production...<sha>` with `ahead_by` 0).

Anything else is logged and ignored.

The `release` event runs the workflow file at the release's tag commit, so the workflow starts firing only after a DTP has carried it to the `production` branch. `workflow_dispatch` is available from `staging` the moment the file is merged there, and covers the exercise runs, seeding, re-runs and recovery.

Alternatives:

- **`push` to `production`.** Fires about fifty minutes earlier, during the legacy rollout and inside the window before `db:migrate` finishes. A legacy build that fails after migrating would still have moved k8s production. It also fires for hotfixes.
- **A Kargo git subscription to release tags.** Gives Freight a commit, but nothing ties it to an image digest, and no built-in step computes a merge base.
- **Inferring the deployed revision from timing heuristics** instead of fixing `create-release`. Fragile; rejected.

### 2. The exact image is resolved through the GitHub API, and there is no automatic fallback

`GET /repos/code-dot-org/code-dot-org/compare/staging...<release sha>` returns `merge_base_commit.sha`. The workflow requires `ghcr.io/code-dot-org/cdo-rails:git-<merge base>` to exist, resolves it to a digest once with `regctl manifest head`, and uses `@sha256:<digest>` for every later read and write. A concurrent rebuild of `git-<sha>` therefore cannot swap the bytes mid-run.

If the manifest is absent, the run fails. It does not promote an older image. An image from before a destructive migration can pass the gate and still break, and recording the gap in a job summary is not the compatibility review that case needs. The failure message lists up to thirty ancestors of the merge base that do have images. The operator chooses one with the `image_commit` override after reviewing the migrations between them. A not-found response is distinguished from authentication errors, timeouts and 5xx responses. Those fail as "cannot determine" with no suggestions, because the exact image may well exist.

There is no bounded wait for a running build. The merge-base push happened hours or days before the release, so a build still in progress is not a realistic state at release time. A re-run covers it if it ever is.

Alternatives: a full checkout and `git merge-base` (slow on this repository, gains nothing over the API); reading `<tag>^2^2` through the commits API (depends on the merge shape `dotd` produces, which is not a contract); automatic walk-back (rejected above).

### 3. Writes happen by digest, in an order that moves the live tag last

The script first validates the resolved index: media type `application/vnd.oci.image.index.v1+json`, `org.opencontainers.image.revision` equal to the resolved commit, both platform descriptors present. It then writes in this order:

1. Copy the digest to `cdo-rails:release-<tag>` and read the alias back.
2. Run the forward-only check (decision 5).
3. Copy the digest to `cdo-rails:production` and read it back.

`regctl image copy` within one repository copies the index manifest byte for byte, so digest and annotation survive and the blobs already exist.

Every failure is classified. Before the live copy: nothing a consumer can see has changed, and the run can simply be repeated. At or after the live copy, including a failed read-back: the state is unknown, the failure says so, and the runbook has the operator inspect the registry digest of `production`, the Warehouse and any Promotion before acting. Because validation precedes publication, a digest that reached `production` is at worst a correct image in a confusing state, never an unvalidated one.

regctl is installed with the SHA-pinned `regclient/actions/regctl-installer` and authenticates through the same `docker/login-action` with `GITHUB_TOKEN` and `packages: write` that the image workflow uses. The logic lives in `docker/rails/tag-production-image.sh`, with a `--dry-run` flag that performs every read and no write. The workflow exposes it as the dispatch input `dry_run`.

Alternative: `docker buildx imagetools create -t production <source>`. It re-marshals the index and, for a mixed-media index, can change its media type and drop annotations, the very problem step one solved.

### 4. A dedicated Warehouse and direct sourcing, with auto-promotion on

`warehouse-production.yaml` defines Warehouse `kargo-project-codeai-production` with one image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest`, `constraint: production`. The production Stage's `requestedFreight` becomes `origin: {kind: Warehouse, name: kargo-project-codeai-production}` with `sources: {direct: true}`. `project-config.yaml` sets `autoPromotionEnabled: true` for `production`.

The promotion template is otherwise unchanged. The gate step still runs first, and `imageFrom("ghcr.io/code-dot-org/cdo-rails")` stays unambiguous because the Stage has one origin. Each move of the tag to a new digest produces exactly one new Freight and one Promotion. The project Application sources the directory recursively, so the new file needs no wiring.

The Warehouse lands in its own commit before the workflow is merged, while no `production` tag exists, so it has nothing to discover until seeding creates the previous release's Freight first and the current release's second, with production still sourcing from the old Warehouse (decision 7, migration plan).

Alternative rejected: turning `autoPromotionEnabled` on with the existing Warehouse. Kargo would promote the newest Freight verified in `test`, which is almost always ahead of legacy production. The gate would fail it, Kargo never retries a Freight whose Promotion failed, and nothing fires when the DTP lands.

Alternative not chosen: an in-cluster CronJob with a ServiceAccount granted the `promote` verb on the production Stage. Every few minutes it would list Freight verified in `test`, ask the compare API for the newest one contained in `production`, and create a Promotion if none exists for it. It keeps the single Warehouse, and so the Kargo-visible chain "this Freight was verified in test", and it keeps `autoPromotionEnabled: false`.

It costs a Role, a ServiceAccount, an image with kubectl, curl and jq, a script to own, and a second trigger mechanism (polling) next to the release. If the team decides test execution must be guaranteed, this is the design to come back to.

### 5. Runs are serialized and queued, the live tag only moves forward, aliases are stable, overrides are scoped

- **Serialization and queueing.** The workflow declares `concurrency: {group: cdo-rails-production-tag, cancel-in-progress: false, queue: max}`. Runs execute one at a time, so two releases, or a release and a dispatch, never write at the same time. `queue: max` keeps every queued run. Without it, Actions holds one pending run and cancels it when another is queued, before any step runs: a release published while two runs were already in the group would lose its run, its alias and its failure notification, and nothing would say so.
- **Forward-only.** Immediately before the live copy, the run reads the `org.opencontainers.image.revision` annotation of the index `cdo-rails:production` currently resolves to (the live revision) and compares `<live revision>...<image commit>` on GitHub. It moves the live tag only when `behind_by` is 0, meaning the image commit is the live revision or a descendant of it, and the release commit is still contained in `production`. Any other run, including one whose commit has diverged, writes its alias and stops, with a summary saying so. A `workflow_dispatch` input `move_live_tag: true` overrides this for deliberate corrections.
  - If `cdo-rails:production` does not exist yet, the run proceeds. That is how the first seed creates the tag, and how the first release-triggered run would if nothing had been seeded.
  - If the live index has no revision annotation, or GitHub does not know the live revision, the run fails before the live copy as "cannot determine" and points at `move_live_tag` for an intentional overwrite. Only a hand-placed image produces that state.
  - Why not "only the newest release moves the tag", checked against `GET /releases/latest`: one failed or cancelled run for the newest release would stop every older run that executes after it from moving the tag. Production would sit behind on releases that were fine, with nothing saying so. With the forward-only rule the order of queued runs does not matter: production ends at the newest release whose run resolved an image, and every alias exists. The cost is that two releases published minutes apart can produce two production rollouts instead of one, which is what legacy does too.
  - Alternative rejected: every run converges the live tag to `GET /releases/latest` regardless of the release that triggered it. It loses the alias of any release whose run was skipped, and the summary no longer records which run moved the tag for which release. Once no queued run is dropped it buys nothing.
- **Stable aliases.** If `release-<tag>` already exists with the same digest, the write is a no-op success. If it exists with a different digest, the run fails before any write, unless the dispatch input `replace_alias: true` is set. The alias, the job summary and the Freight's revision annotation are the record of which release maps to which commit and digest.
- **Scoped overrides.** `image_commit` is checked with compare `<release sha>...<override>` and must have `ahead_by` 0. An override can only name a commit the named release contains, never something newer that happens to be in `production` today.

### 6. Trade-off accepted: nothing guarantees the promoted digest ran in test, and Kargo cannot see it either

Freight identity includes its Warehouse, so the Freight that reaches production was never verified in `test` in Kargo's eyes. The digest usually is the one that ran in staging and test, but not necessarily: `git-<sha>` can be rebuilt, the `latest` Warehouse can miss a digest between refreshes, and a Stage can be unhealthy when a digest passes through.

Production eligibility therefore rests on what is actually enforced: every published digest passed CI's smoke and boot suites, the commit gate proves the commit is in legacy production, and the release trigger proves the legacy deploy that applied its migrations finished. The runbook shows how to check whether the `latest` Warehouse holds Freight with the same digest verified in `test`, and what it means when it does not. If the team wants that execution guaranteed, the in-cluster promoter in decision 4 provides it.

### 7. Rollback and failure semantics follow from Kargo's rules

- **Rollback.** A person promotes an older production-Warehouse Freight from the UI or CLI. The gate passes for any older commit, since it certifies missing prerequisites only.
  - Before every rollback, including to the previous release, the operator lists the migrations added between the two commits and reviews them for `drop_table`, `remove_column` and renames, because one release can carry a destructive migration.
  - Because that Freight is not the current candidate, Kargo records an auto-promotion hold for the production Warehouse origin once the Promotion completes. The newest Freight is not re-promoted, and neither is Freight from any later release, until a person resumes. The Stage shows the hold in the UI meanwhile.
  - Resuming is promoting the current candidate by hand (that Promotion carries resume intent) or using the Stage's Resume action. The runbook's rollback procedure ends with that step, so a rollback is never silently left in place when the fix release arrives.
- **Transient gate failure** (GitHub outage during a promotion). The Promotion fails, and Kargo never retries that Freight because its newest Promotion did not succeed. Recovery is a manual promotion of the same Freight. It is the candidate, so no hold results. Re-running the workflow resolves the same digest, creates no Freight and retries nothing.
- **Wrong digest.** A corrected run (right release, or `image_commit` within it) moves the tag to a new digest, which creates new Freight and an automatic Promotion. When the corrected commit is older than the live revision, the dispatch needs `move_live_tag: true`, or the forward-only check writes the alias only. If the correct digest already has Freight, the tag move creates nothing and the operator promotes that Freight by hand.
- **Release that resolves to a digest already in the Warehouse.** No Freight, no Promotion, nothing to do. The summary says so.
- **Workflow failed before the live copy.** Nothing changed; re-run. **Failed at or after it.** Inspect registry and Kargo state first.
- **Pause.** `autoPromotionEnabled: false` for `production` in `project-config.yaml`. Freight keeps appearing; nothing promotes until a person does or the flag is restored. Disabling clears any hold, and restoring the flag promotes the newest Freight at once if it is not current. So the flag is restored only when that Freight is what production should run.
- **Cutover.** The production Warehouse holds Freight for the previous and the current release before the Stage switches to it, discovered in that order, so that the current release is the candidate and a rollback target exists from the first automatic promotion.
  - The order cannot be repaired afterwards. The candidate is the newest Freight by creation time, and a digest the Warehouse has already seen creates no Freight, so pointing the tag back at the current digest changes nothing.
  - So the Warehouse is added before the workflow can run, seeding goes previous then current, and the switch waits for a read-only check that the newest Freight carries the digest `production` resolves to, and that this is the latest release's digest.
  - If the check fails, the switch waits for the next release, whose Freight becomes the newest. No Freight is deleted or edited by hand.

### 8. The release trigger carries the timing that step one leaves to the runbook

Step one has no runtime guard. It accepts the window between a DTP merge and `db:migrate`, and closes it with the runbook's rule to promote only after the release exists. Here the trigger is the release, created after `db:migrate`, the fleet replacement and the CDN flush. An automatic promotion therefore never races a migration, and the rule needs no person.

What stays unguarded is the same as in step one:

- a legacy migration rollback after the promotion (nothing in k8s notices; the runbook has the operator promote the matching older Freight);
- a hand-edited values file (a reviewed commit);
- a tag moved by anyone with write access to code-dot-org to an image whose commit is in `production` but whose migrations were since rolled back (the same image a person could promote by hand today).

### 9. Failures reach a person before anything runs unattended

Argo cannot see a failed release workflow: the desired state simply does not change, and everything stays Healthy on the old release. The workflow therefore ends with a step that runs on any failure and posts the release, the stage reached and the outcome class to a channel people read. The mechanism (an existing Slack webhook secret in code-dot-org Actions, or the channel the legacy daemon's `ChatClient` posts to) is an open question. A tested notification is an entry criterion for enabling auto-promotion, not a follow-up.

### 10. Blast radius of the new write path

Anyone who can push a workflow change to code-dot-org or run `workflow_dispatch` can move the `production` tag. The worst they can achieve is a Promotion of a validated image whose commit is contained in the named release and in `production`. The gate rejects everything else, the override is scoped to the release, and a release older than what is live cannot move the live tag without an explicit input. That is the same set of images a person may promote today.

## Risks / Trade-offs

- **GHCR does not emit a `package` event for a retag.** The Warehouse's polling interval picks the change up within minutes. The rollout observes which happens, and the runbook states the expected delay.
- **The legacy release still tags the branch tip when automation is enabled.** Entry criterion: the `create-release` change is merged and observed on at least one release. Until then a release can name a commit whose deploy, migrations included, has not finished when two DTPs overlap, and nothing at runtime catches that. So this criterion is firm.
- **The exact image is missing.** The run fails and lists candidate ancestors. k8s production stays on the previous release, and the operator chooses with a compatibility review.
- **A run fails after the live copy.** Classified as unknown outcome. The runbook inspects registry and Kargo state. The digest was validated before publication, so the worst case is a confusing state, not a bad image.
- **A manually created release in the production format.** Passes the eligibility filter and triggers a promotion. The gate still applies, and the runbook notes it.
- **The promoted digest never ran in test.** Decision 6. CI suites, the gate and the release trigger are what eligibility rests on. The promoter alternative is recorded.
- **Auto-promotion starts a production rollout with nobody watching.** Argo health and alerting on `Degraded`, the failure notification, and `autoPromotionEnabled: false` as a one-line pause. The first several releases are observed by a person.
- **A failed automatic promotion is never retried by Kargo.** Visible as Failed. Recovery is a manual promotion of the same Freight. Alerting on failed Promotions is a reasonable follow-up.
- **A rollback hold is forgotten and later releases quietly stop promoting.** The Stage shows the hold in the Kargo UI, and the runbook's rollback procedure ends with the resume step. Alerting on production Freight that has no Promotion is a reasonable follow-up.
- **Toggling `autoPromotionEnabled` off and on clears a hold and promotes the newest Freight immediately.** Stated in the pause procedure. The flag is restored only when the newest Freight is the intended one.
- **`release` runs the workflow at the tag commit, so a workflow change takes one DTP to become active.** Documented. `workflow_dispatch` runs the version on the branch chosen and is available as soon as the file is on `staging`, so the workflow is exercised and the Warehouse seeded before the first release-triggered run.
- **The Warehouse discovers the current release before the previous one.** Kargo would then auto-promote the previous release at cutover, an unreviewed rollback. The cutover order (Warehouse first, then seed previous, then current) prevents it, and the pre-switch check catches it. The remedy is to wait for the next release's Freight; no Freight is edited by hand.
- **Queued runs execute in no particular order.** The forward-only check makes the end state the same for any order: the newest release whose run resolved an image is live, and every alias exists. The worst case is one extra rollout when two releases land minutes apart.
- **A person cancels a run after the live copy.** The notification step also runs on cancelled runs and reports the outcome as unknown. The runbook treats it like a failure after the live copy.
- **No notification channel is available in Actions.** Blocks enablement until one exists.

## Migration Plan

1. Entry criteria: step one complete (the gate step passed on a manual promotion, runbook used end to end); the `create-release --commit` change merged and observed tagging the deployed revision on at least one release; a failure notification wired, and tested in step 4 before step 7.
2. code-dot-org PR A to `staging`, reviewed by the legacy deploy owners: `bin/create-release --commit`, and `publish_github_release` passing the deployed revision. Merge. It reaches production with the next DTP. Confirm on the following release that the tag's commit equals the revision the daemon announced.
3. k8s-gitops commit 1: add `warehouse-production.yaml` only, before PR B merges. Confirm it syncs and holds no Freight: the `production` tag does not exist yet, so there is nothing to discover.
4. code-dot-org PR B to `staging`: `docker/rails/tag-production-image.sh`, the workflow, the README tag contract. Merge, and in the same sitting, before a DTP can carry the workflow to `production`:
   - exercise it from `staging`: a `dry_run` dispatch for the latest release, and a dispatch with a bogus tag to see the notification arrive;
   - seed: dispatch for the previous eligible release (the tag does not exist, so no `move_live_tag`), wait for the Warehouse to create Freight, then dispatch for the latest release;
   - confirm both aliases, that `production` resolves to the latest release's digest, and that the Warehouse holds two Freight in that creation order with the expected digests and annotations. Production still sources from the old Warehouse, so nothing promotes;
   - if `production` already exists when seeding starts, do not seed the previous release. Dispatch for the latest release only, and note that the rollback target arrives with the next release.
5. The next DTP carries the workflow to `production`. Its release runs the workflow unattended for the first time. Confirm the run succeeded, the alias and tag were written, and the Warehouse gained a newer Freight with that release's digest.
6. Pre-switch check: the newest production-Warehouse Freight by creation time carries the digest `production` resolves to, that digest is the latest release's, and an older Freight exists. If the newest Freight is not the latest release, do not switch; wait for the next release and check again. Nothing is deleted or edited by hand.
7. k8s-gitops commit 2: switch the production Stage's requested Freight, enable auto-promotion, update the Stage header comment, project README and runbook. Refresh `kargo-project-codeai`. Confirm Kargo creates one Promotion for the newest Freight, the gate step passes, `git-commit` reports `Skipped` if the digest is already deployed, and the Stage is Healthy with that Freight current.
8. Observe the next real release end to end: release published, workflow run, alias and tag written, Freight created, Promotion succeeded, pods rolled. Record the timings in the runbook.
9. Optional drill: promote the previous production Freight by hand after the compatibility review, confirm the Stage records a hold and Kargo does not re-promote the newest, then promote the newest again and confirm the hold clears.

Rollback of this change: set `autoPromotionEnabled: false` (pause), or revert the Stage's `requestedFreight` to the shared Warehouse with `sources.stages: [test]` (full return to the manual flow of step one). The Warehouse file and the code-dot-org workflow can stay; an unconsumed `production` tag is harmless. None of this touches the database or the legacy fleet.

## Open Questions

- Which code-dot-org branch the PRs are cut from. User decision before implementation.
- Whether the legacy deploy owners accept `create-release --commit`, and whether interactive runs should keep `production` as the default target or use the local checkout's HEAD.
- Which notification mechanism code-dot-org Actions can use (an existing Slack webhook secret, or the channel the legacy daemon posts to).
- How many manual promotions under step one the team wants before enabling this. The design assumes at least a few.
- Whether to alert on production Freight that has had no Promotion for some time, which would catch a forgotten hold and a paused policy alike.
