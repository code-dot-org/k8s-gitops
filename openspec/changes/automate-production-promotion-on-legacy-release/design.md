## Context

After `gate-production-freight-on-legacy-production` is rolled out, the `codeai` Kargo project looks like this. One Warehouse (`kargo-project-codeai`) follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest; every image index carries `org.opencontainers.image.revision` naming the `staging` commit it was built from. `staging` and `test` auto-promote. `production` requests Freight verified in `test`, has `autoPromotionEnabled: false`, and its promotion template runs two gate steps, `freight-has-revision` and `revision-in-legacy-production` (GitHub compare `production...<revision>`; the first fails on 404 or 422, the second passes only on `ahead_by == 0`), before `git-clone`, `yaml-update`, `git-commit`, `git-push` and `argocd-update`. Every Deployment pod runs the `schema-guard` initContainer; production is in `enforce`. A person promotes by following `docs/production-promotion.md`.

Legacy production deploys through DTP: `bin/dotd` merges a candidate into the `production` branch; the `ci_build` daemon pulls, records the revision it is about to deploy, and runs `infra:all` (chef, `db:migrate`, seed, worker restart, assets, a rolling AMI replacement of about 45 minutes, a CDN flush); the final task `publish_github_release` runs `bin/create-release --force`, which creates a GitHub release through the API with a tag of the form `vYYYY-MM-DD.N`. `create-release` exits without a release when production HEAD is not a merge commit, so hotfixes (direct pushes) never produce one. Two details matter. First, `create-release` passes `target_commitish: production`, which GitHub resolves to the branch tip at that moment, not to the revision the daemon deployed; if a second DTP lands during the deploy, the release names a commit that has not finished deploying, and only the test daemon checks for a revision change during its build. Second, the release's changelog is already computed from the local checkout, so tagging the deployed revision also makes the release consistent with its own notes. With that fix, the release is the one machine-readable signal meaning "legacy production finished deploying this commit".

The staging commit a release contains is the merge base of `staging` and the release commit, which the GitHub compare API returns as `merge_base_commit`. That commit is the head of a push to `staging`, so CI normally published `cdo-rails:git-<sha>` for it. `git-<sha>` is not an immutable handle, though: the image workflow also runs after each weekly `cdo-deps` publish and on manual dispatch, both on the default branch, and republishes `git-<sha>` and `latest` with new bytes. Only a digest pins bytes. A rebuilt digest may never have been seen by the `latest` Warehouse, and even a first-build digest can be skipped when `latest` moves twice between Warehouse refreshes or when a Stage was unhealthy at the time, so no digest can be assumed to have run in staging or test.

Kargo 1.9.5 facts, verified in source: `autoPromoteFreight` takes the newest promotable Freight by creation time for each requested origin, skips when it is already current, and with the default selection policy skips whenever any Promotion already exists for that Stage and Freight, successful or not, so a failed auto-promotion is never retried by Kargo and a manual promotion of older Freight is never undone. A Warehouse with the Digest strategy creates Freight only for a digest it has not produced before. The `git-commit` step returns `Skipped` with the existing commit ID when the working tree has no diffs, so a promotion that writes the digest already in `values.yaml` is a clean no-op. The GitHub webhook receiver refreshes Warehouses on `package` events, and Warehouses also poll on an interval.

GitHub facts: `release: published` fires for prereleases too; `GET /releases/latest` returns the newest release that is neither a draft nor a prerelease; a `release` workflow runs the workflow file at the release's tag commit; the Actions `concurrency` key serializes runs in a group but does not order them.

## Goals / Non-Goals

**Goals:**

- Promote to `production`, without a person, the exact image built from the staging commit each legacy production release contains, within minutes of the release.
- Keep both gates from step one in force on every automatic promotion.
- Never move the live tag to an unvalidated digest, never move it backward because of run ordering, and never leave it changed by a run that then fails silently.
- Keep rollback a one-step manual action in Kargo that the automation does not fight, with the same compatibility review every time.
- Make the automation pausable with one reviewed commit and auditable from the release, the registry and the Freight.
- Tell a person whenever a release did not produce a promotion.

**Non-Goals:**

- Promoting hotfixes that bypass a release. They do not move the merge base, so k8s production stays one step behind until the next DTP; the schema guard and the gate make that safe.
- Falling back automatically to an older image when the exact one is missing. That is an operator decision after a compatibility review.
- Guaranteeing in Kargo that the promoted digest ran in `test`. The in-cluster promoter alternative below provides it and is not chosen.
- Changing how `staging`, `test` or `levelbuilder` select or promote Freight. Making k8s test follow the legacy `test` branch is a separate follow-up.
- Narrowing who may promote, or adding verification processes to the production Stage.
- Any new in-cluster component.

## Decisions

### 1. The trigger is the GitHub release, and the release must name the deployed revision

The release is created by the last task of `infra:all` on a production host, after `db:migrate`, the fleet replacement and the CDN flush, and only for merge commits. Triggering on it means "legacy production is running this" rather than "this was merged into `production`", and a legacy build that fails after the merge produces no release and so no k8s promotion.

That claim holds only if the release tags the revision the daemon deployed. Today it tags the branch tip at release time. The prerequisite change in code-dot-org is small: `publish_github_release` passes the revision `ci_build` recorded (`RakeUtils.git_revision`, the local checkout's HEAD during the whole build) to `bin/create-release --commit <sha>`, which uses it as `target_commitish`; GitHub accepts a SHA there. Interactive use of `create-release` is unchanged. This is a change in the legacy deploy path and needs its owners' review; it also fixes the existing mismatch between the tag and the changelog.

The workflow treats a release as eligible only when it is not a draft or prerelease, its tag matches `^v\d{4}-\d{2}-\d{2}\.\d+$`, and its commit is a merge commit contained in `production` (compare `production...<sha>` with `ahead_by` 0). Anything else is logged and ignored.

Alternatives: `push` to `production` fires about fifty minutes earlier, during the legacy rollout and inside the window before `db:migrate` finishes; a legacy build that fails after migrating would still have moved k8s production; and it fires for hotfixes. A Kargo git subscription to release tags gives Freight a commit but nothing ties it to an image digest, and no built-in step computes a merge base. Inferring the deployed revision from timing heuristics instead of fixing `create-release` is fragile and was rejected.

The `release` event runs the workflow file at the release's tag commit, so the workflow starts firing only after a DTP has carried it to the `production` branch. `workflow_dispatch` covers the first runs, seeding, re-runs and recovery.

### 2. The exact image is resolved through the GitHub API, and there is no automatic fallback

`GET /repos/code-dot-org/code-dot-org/compare/staging...<release sha>` returns `merge_base_commit.sha`. The workflow requires `ghcr.io/code-dot-org/cdo-rails:git-<merge base>` to exist, resolves it to a digest once with `regctl manifest head`, and uses `@sha256:<digest>` for every later read and write, so a concurrent rebuild of `git-<sha>` cannot swap the bytes mid-run.

If the manifest is absent, the run fails. It does not promote an older image: an image from before a destructive migration can pass both gates and still break, and recording the gap in a job summary is not the compatibility review that case needs. The failure message lists up to thirty ancestors of the merge base that do have images, for the operator to choose from with the `image_commit` override after reviewing the migrations between them. A not-found response is distinguished from authentication errors, timeouts and 5xx responses; those fail as "cannot determine" with no suggestions, because the exact image may well exist.

No bounded wait for a running build: the merge-base push happened hours or days before the release, so a build still in progress is not a realistic state at release time; a re-run covers it if it ever is.

Alternatives: a full checkout and `git merge-base` (slow on this repository, gains nothing over the API); reading `<tag>^2^2` through the commits API (depends on the merge shape `dotd` produces, which is not a contract); automatic walk-back (rejected above).

### 3. Writes happen by digest, in an order that moves the live tag last

The script validates the resolved index first: media type `application/vnd.oci.image.index.v1+json`, `org.opencontainers.image.revision` equal to the resolved commit, both platform descriptors present. It then copies the digest to `cdo-rails:release-<tag>` and reads the alias back, runs the freshness check (decision 5), copies the digest to `cdo-rails:production`, and reads that back. `regctl image copy` within one repository copies the index manifest byte for byte, so digest and annotation survive and the blobs already exist.

Every failure is classified. Before the live copy: nothing a consumer can see has changed, and the run can simply be repeated. At or after the live copy, including a failed read-back: the state is unknown, the failure says so, and the runbook has the operator inspect the registry digest of `production`, the Warehouse and any Promotion before acting. Because validation precedes publication, a digest that reached `production` is at worst a correct image in a confusing state, never an unvalidated one.

regctl is installed with the SHA-pinned `regclient/actions/regctl-installer`, authenticates through the same `docker/login-action` with `GITHUB_TOKEN` and `packages: write` the image workflow uses, and the logic lives in `docker/rails/tag-production-image.sh` with a `--dry-run` flag that performs every read and no write.

Alternative: `docker buildx imagetools create -t production <source>`, which re-marshals the index and, for a mixed-media index, can change its media type and drop annotations, the very problem step one solved.

### 4. A dedicated Warehouse and direct sourcing, with auto-promotion on

`warehouse-production.yaml` defines Warehouse `kargo-project-codeai-production` with one image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest`, `constraint: production`. The production Stage's `requestedFreight` becomes `origin: {kind: Warehouse, name: kargo-project-codeai-production}` with `sources: {direct: true}`; `project-config.yaml` sets `autoPromotionEnabled: true` for `production`. The promotion template is otherwise unchanged: the two gate steps still run first and `imageFrom("ghcr.io/code-dot-org/cdo-rails")` stays unambiguous because the Stage has one origin. Each move of the tag to a new digest produces exactly one new Freight and one Promotion. The project Application sources the directory recursively, so the new file needs no wiring. The Warehouse lands in its own commit before the Stage switch, so it can be seeded with Freight for the previous and current releases while production still sources from the old Warehouse (decision 7, migration plan).

Alternative rejected: turning `autoPromotionEnabled` on with the existing Warehouse. Kargo would promote the newest Freight verified in `test`, which is almost always ahead of legacy production; the gate would fail it; Kargo never retries a Freight whose Promotion failed; and nothing fires when the DTP lands.

Alternative not chosen: an in-cluster CronJob with a ServiceAccount granted the `promote` verb on the production Stage, which every few minutes lists Freight verified in `test`, asks the compare API for the newest one contained in `production`, and creates a Promotion if none exists for it. It keeps the single Warehouse and so the Kargo-visible chain "this Freight was verified in test", and it keeps `autoPromotionEnabled: false`. It costs a Role, a ServiceAccount, an image with kubectl, curl and jq, a script to own, and a second trigger mechanism (polling) next to the release. If the team decides test execution must be guaranteed, this is the design to come back to.

### 5. Runs are serialized, only the newest release moves the live tag, aliases are stable, overrides are scoped

- Serialization: the workflow declares a `concurrency` group with `cancel-in-progress: false`, so two releases or a release and a dispatch never write at the same time.
- Freshness: immediately before the live copy, the run re-reads `GET /releases/latest` and proceeds only if that is the release it is processing and its commit is still contained in `production`. Any other run writes its alias and stops, with a summary saying so. A `workflow_dispatch` input `move_live_tag: true` overrides this for seeding and deliberate corrections.
- Stable aliases: if `release-<tag>` already exists with the same digest the write is a no-op success; if it exists with a different digest the run fails before any write, unless the dispatch input `replace_alias: true` is set. The alias, the job summary and the Freight's revision annotation are the record of which release maps to which commit and digest.
- Scoped overrides: `image_commit` is checked with compare `<release sha>...<override>` and must have `ahead_by` 0, so an override can only name a commit the named release contains, never something newer that happens to be in `production` today.

### 6. Trade-off accepted: nothing guarantees the promoted digest ran in test, and Kargo cannot see it either

Freight identity includes its Warehouse, so the Freight that reaches production was never verified in `test` in Kargo's eyes. The digest usually is the one that ran in staging and test, but not necessarily: `git-<sha>` can be rebuilt, the `latest` Warehouse can miss a digest between refreshes, and a Stage can be unhealthy when a digest passes through. Production eligibility therefore rests on what is actually enforced: every published digest passed CI's smoke and boot suites, the commit gate proves the commit is in legacy production, and the schema guard proves the database has the migrations. The runbook shows how to check whether the `latest` Warehouse holds Freight with the same digest verified in `test`, and what it means when it does not. If the team wants that execution guaranteed, the in-cluster promoter in decision 4 provides it.

### 7. Rollback and failure semantics follow from Kargo's rules

- Rollback: a person promotes an older production-Warehouse Freight from the UI or CLI. Both gates pass for any older commit, which certifies missing prerequisites only; before every rollback, including to the previous release, the operator lists the migrations added between the two commits and reviews them for `drop_table`, `remove_column` and renames, because one release can carry a destructive migration. Kargo does not re-promote the newest Freight, since a Promotion already exists for it. Automation resumes when a release yields a digest the Warehouse has not seen.
- Transient gate failure (GitHub outage during a promotion): the Promotion fails and Kargo never retries that Freight. Recovery is a manual promotion of the same Freight. Re-running the workflow resolves the same digest, creates no Freight and retries nothing.
- Wrong digest: a corrected run (right release, or `image_commit` within it) moves the tag to a new digest, which creates new Freight and an automatic Promotion. If the correct digest already has Freight, the tag move creates nothing and the operator promotes that Freight by hand.
- Release that resolves to a digest already in the Warehouse: no Freight, no Promotion, nothing to do; the summary says so.
- Workflow failed before the live copy: nothing changed; re-run. Failed at or after it: inspect registry and Kargo state first.
- Pause: `autoPromotionEnabled: false` for `production` in `project-config.yaml`. Freight keeps appearing; nothing promotes until a person does or the flag is restored.
- Cutover: the production Warehouse holds Freight for the previous and the current release before the Stage switches to it, so a rollback target exists from the first automatic promotion.

### 8. The schema guard is unchanged and still load-bearing

The release fires long after `db:migrate`, so the guard should pass at once on every automatic promotion. It stays in `enforce` because it is the only protection against a legacy database rollback, a hand-edited values file, and a tag moved by anyone with write access to code-dot-org to an image whose commit is in `production` but whose migrations were since rolled back.

### 9. Failures reach a person before anything runs unattended

Argo cannot see a failed release workflow: the desired state simply does not change and everything stays Healthy on the old release. The workflow therefore ends with a step that runs on any failure and posts the release, the stage reached and the outcome class to a channel people read. The mechanism (an existing Slack webhook secret in code-dot-org Actions, or the channel the legacy daemon's `ChatClient` posts to) is an open question, and a tested notification is an entry criterion for enabling auto-promotion, not a follow-up.

### 10. Blast radius of the new write path

Anyone who can push a workflow change to code-dot-org or run `workflow_dispatch` can move the `production` tag. The worst they can achieve is a Promotion of a validated image whose commit is contained in the named release and in `production`, because the gate rejects everything else, the override is scoped to the release, and a non-latest release cannot move the live tag without an explicit input. That is the same set of images a person may promote today.

## Risks / Trade-offs

- [GHCR does not emit a `package` event for a retag] → The Warehouse's polling interval picks the change up within minutes; the rollout observes which happens and the runbook states the expected delay.
- [The legacy release still tags the branch tip when automation is enabled] → Entry criterion: the `create-release` change is merged and observed on at least one release. Until then a release can name an undeployed commit; the schema guard covers its migrations but not the commit rule.
- [The exact image is missing] → The run fails and lists candidate ancestors; k8s production stays on the previous release; the operator chooses with a compatibility review.
- [A run fails after the live copy] → Classified as unknown outcome; the runbook inspects registry and Kargo state; the digest was validated before publication, so the worst case is a confusing state, not a bad image.
- [A manually created release in the production format] → Passes the eligibility filter and triggers a promotion; both gates still apply; the runbook notes it.
- [The promoted digest never ran in test] → Decision 6; CI suites and the two gates are what eligibility rests on; the promoter alternative is recorded.
- [Auto-promotion starts a production rollout with nobody watching] → Argo health and alerting on `Degraded`, the failure notification, and `autoPromotionEnabled: false` as a one-line pause; the first several releases are observed by a person.
- [A failed automatic promotion is never retried by Kargo] → Visible as Failed; recovery is a manual promotion of the same Freight; alerting on failed Promotions is a reasonable follow-up.
- [`release` runs the workflow at the tag commit, so a workflow change takes one DTP to become active] → Documented; `workflow_dispatch` from the `production` branch exercises the current version at any time.
- [No notification channel is available in Actions] → Blocks enablement until one exists.

## Migration Plan

1. Entry criteria: step one complete (production in `enforce`, both gate steps passed on a manual promotion, runbook used end to end); the `create-release --commit` change merged and observed tagging the deployed revision on at least one release; a failure notification wired and tested from a dry run.
2. code-dot-org PR A to `staging`, reviewed by the legacy deploy owners: `bin/create-release --commit`, `publish_github_release` passing the deployed revision. Merge; it reaches production with the next DTP; confirm on the following release that the tag's commit equals the revision the daemon announced.
3. code-dot-org PR B to `staging`: `docker/rails/tag-production-image.sh`, the workflow, the README tag contract. Merge; the next DTP carries the workflow to `production`.
4. k8s-gitops commit 1: add `warehouse-production.yaml` only. Confirm it syncs; it reports no tag until step 5.
5. Seed: dispatch the workflow for the previous eligible release with `move_live_tag: true`, wait for the Warehouse to create Freight, then dispatch for the latest release. Confirm both aliases, that `production` resolves to the latest release's digest, and that the Warehouse holds two Freight with the expected digests and annotations. Production still sources from the old Warehouse, so nothing promotes.
6. k8s-gitops commit 2: switch the production Stage's requested Freight, enable auto-promotion, update the Stage header comment, project README and runbook. Refresh `kargo-project-codeai`. Confirm Kargo creates one Promotion for the newest Freight, both gate steps pass, `git-commit` reports `Skipped` if the digest is already deployed, and the Stage is Healthy with that Freight current.
7. Observe the next real release end to end: release published, workflow run, alias and tag written, Freight created, Promotion succeeded, pods rolled, guard log clean. Record the timings in the runbook.
8. Optional drill: promote the previous production Freight by hand after the compatibility review, confirm Kargo does not re-promote the newest, then promote the newest again.

Rollback of this change: set `autoPromotionEnabled: false` (pause); or revert the Stage's `requestedFreight` to the shared Warehouse with `sources.stages: [test]` (full return to the manual flow of step one). The Warehouse file and the code-dot-org workflow can stay; an unconsumed `production` tag is harmless. None of this touches the database or the legacy fleet.

## Open Questions

- Which code-dot-org branch the PRs are cut from. User decision before implementation.
- Whether the legacy deploy owners accept `create-release --commit`, and whether interactive runs should keep `production` as the default target or use the local checkout's HEAD.
- Which notification mechanism code-dot-org Actions can use (an existing Slack webhook secret, or the channel the legacy daemon posts to).
- How many manual promotions under step one the team wants before enabling this; the design assumes at least a few.
