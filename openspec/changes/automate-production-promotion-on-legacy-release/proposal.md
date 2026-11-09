## Why

The change `gate-production-freight-on-legacy-production` (step one) makes the manual promotion of Freight into the `production` namespace safe: a Kargo step rejects Freight whose commit is not yet in the legacy `production` branch. It does not press the button. After every legacy production deploy (DTP), a person still has to notice that it finished, find the Freight built from the matching `staging` commit, and promote it. That is toil. It leaves k8s production behind legacy for as long as nobody is looking, and it is exactly the kind of step that gets skipped.

This change automates the button. When legacy production publishes a release, the image built from the staging commit that release contains is promoted to `production`, with the gate still in force.

### The whole plan, for reviewers

This is step two of a two-step plan. Read both changes together.

1. **Gate it** (`gate-production-freight-on-legacy-production`, prerequisite). Every published `cdo-rails` image index carries the staging commit it was built from (`org.opencontainers.image.revision`). The production Stage's first promotion step asks GitHub whether that commit is known and contained in the `production` branch, and fails the promotion otherwise with a message naming the cause. Promotion stays manual, done only after the release for that DTP exists, and a runbook covers the procedure.
2. **Automate it** (this change). The legacy production release becomes the trigger. A code-dot-org workflow resolves the staging commit the release contains and moves the `cdo-rails:production` tag to that commit's existing image. A second Kargo Warehouse follows that tag and feeds the production Stage with auto-promotion on. The gate from step one runs on every automatic promotion. The release trigger fires only after the legacy deploy, migrations included, has finished.

Step two depends on step one being rolled out: production running behind the gate, and a few manual promotions done from the runbook, so a person has watched the gate and the first production workloads before a robot takes over. It also depends on a small legacy change. Today the release tags the `production` branch tip at the moment it is created, not the revision the deploy ran, so the release must first be made to name the deployed revision.

## What Changes

- **Legacy release identity (code-dot-org, prerequisite).** `bin/create-release` gains `--commit <sha>`, and `publish_github_release` passes the revision the build deployed. The release tag then names what legacy production is actually running, instead of the branch tip at release time. This also makes the tag consistent with the release's own changelog, which is already computed from the deployed checkout.
- **Production image tag (code-dot-org).** A new workflow runs when a GitHub release is published and acts only on eligible releases: not a draft or prerelease, a production-format tag, a merge commit contained in `production`. For an eligible release it:
  - asks the GitHub compare API for the merge base of `staging` and the release commit, which is the staging commit the release contains;
  - requires that CI published an image for exactly that commit, and resolves that image to a digest once;
  - validates the index by digest, writes the `cdo-rails:release-<tag>` alias, confirms the image commit is not behind the one already live, and only then moves the mutable `cdo-rails:production` tag. Every write is by digest with regctl, which preserves the digest and the revision annotation.
  - Runs are serialized and queued, and no queued run is dropped. A release older than what is live can only write its alias. An existing alias is never repointed without an explicit input. Failures are classified as published or not, and every failure notifies a person.
  - A missing exact image fails the run and lists candidate ancestors for an operator to choose from after a compatibility review. Nothing older is promoted automatically.
  - A `workflow_dispatch` entry point re-runs it for a named release, with an optional commit override that must be contained in that release, and a dry-run mode.
- **Production Warehouse and auto-promotion (k8s-gitops).** A second Warehouse follows `cdo-rails:production` by digest, exactly as the existing one follows `latest`. The `production` Stage requests Freight directly from that Warehouse instead of from `test`, and the project promotion policy turns `autoPromotionEnabled` on for `production`.
  - **BREAKING** for the manual flow: Freight from the shared Warehouse, including Freight verified in `test`, can no longer be promoted to production. Only Freight from the production Warehouse can.
  - Rollback becomes a manual promotion of an older production-Warehouse Freight. Kargo then records an auto-promotion hold on the Stage, so nothing promotes automatically, not even a later release, until a person resumes it. Every rollback, including to the previous release, follows the runbook's destructive-migration review, since the gate certifies missing prerequisites only.
  - The Warehouse is added before the workflow can run and seeded with the previous release and then the current one, so that the current release is Kargo's candidate and a rollback target exists from the first automatic promotion. The switch waits for a check that the newest Freight is the latest release's.
- **The gate stays, the runbook changes.** The gate step `legacy-ancestry` keeps running first on every promotion, now including the automatic ones, as defense in depth against a mis-resolved commit. The runbook describes what the automation does, how to confirm which release a digest came from and whether that digest ran in `test`, how to pause the automation with one commit, how rollback behaves and how to resume after it, and what to do when the workflow fails before or after publishing or the gate fails. Its requirement that promotion remains a manual decision is removed.
- **Unchanged on purpose.** The `staging`, `test` and `levelbuilder` Stages; who may create a Promotion; no new cluster infrastructure. The alternative that keeps a single Warehouse, an in-cluster job that creates Promotions, is recorded in the design and not chosen.

## Capabilities

### New Capabilities

- `cdo-rails-production-tag`: the legacy release names the deployed revision. On every eligible release the `cdo-rails:production` tag is moved, by digest and live tag last, to the exact image of the staging commit the release contains. Each release gets an alias, runs are serialized and queued, the live tag only moves forward, and every failure notifies a person.
- `production-freight-auto-promotion`: a dedicated Warehouse, seeded in order with the previous and current releases before cutover, turns each move of that tag into Freight. The production Stage promotes it without a person. Manual rollback is reviewed and holds automation until a person resumes it. Failed promotions are recovered by hand, and the automation can be paused with one commit.

### Modified Capabilities

Both come from `gate-production-freight-on-legacy-production`, which must be archived into `openspec/specs/` before this change is applied.

- `production-freight-commit-gate`: the requirement that the gate applies to every promotion drops its clause that `autoPromotionEnabled` stays `false` for `production`, and gains the automatic promotion as a scenario.
- `production-promotion-runbook`: the runbook describes the automated procedure and the person's role around it. The requirement that promotion remains a manual decision is removed.

## Impact

- **code-dot-org**, two PRs to `staging`. First `bin/create-release` and `lib/rake/infra.rake` (release identity, reviewed by the legacy deploy owners). Then the new `.github/workflows/cdo-rails-production-tag.yml`, the new `docker/rails/tag-production-image.sh`, and the `docker/rails/README.md` tag contract. No image content or chart change. The workflow runs on the release's tag commit, so it only starts firing after a DTP has carried it to the `production` branch.
- **k8s-gitops**: new `apps/kargo/projects/codeai/warehouse-production.yaml` (picked up by the project Application's recursive directory source), `apps/kargo/projects/codeai/stages/production.yaml`, `apps/kargo/projects/codeai/project-config.yaml`, `apps/kargo/projects/codeai/README.md`, `docs/production-promotion.md`. No chart under `apps/` changes, so no `Chart.yaml` bump. No `apps/app-of-apps` structure change, so no mimic-tree edit.
- **Runtime behaviour**: one short GitHub Actions run per legacy release (a few GitHub API calls and one in-registry copy); one more tag for Kargo to watch; production rollouts start within minutes of a release instead of when a person acts.
- **New failure states**:
  - The workflow fails before the live tag moves: nothing changed, k8s production stays on the previous release.
  - The workflow fails at or after the live tag moves: state unknown until the operator inspects the registry and Kargo.
  - The exact image is missing: the run fails with candidates, and the operator decides.
  - A Promotion fails at the gate step: Kargo never retries that Freight. A transient cause is recovered by promoting the same Freight by hand; a wrong digest by a corrected tag move that yields new Freight.
  - A rollback leaves an auto-promotion hold on the Stage, visible in the Kargo UI, that stays until a person resumes.
- **Sequencing**:
  1. step one rolled out; the release identity change merged, carried to `production` by a DTP and observed on a release;
  2. the Warehouse added in its own k8s-gitops commit while no `production` tag exists;
  3. the workflow merged to `staging` and, in the same sitting, exercised (notification tested) and the `production` tag seeded with the previous and then the current release, so the Warehouse holds two Freight in that order;
  4. the next DTP carries the workflow to `production` and its release produces the first unattended run;
  5. a check that the newest Freight is the latest release's;
  6. the Stage switch and auto-promotion in a second commit.

## Terms

Step one's proposal defines DTP, legacy, Warehouse, Freight, Stage, Promotion, OCI index and digest. This change adds:

- **Live tag**: `cdo-rails:production`, the mutable tag the production Warehouse follows. Moving it is what triggers a promotion.
- **Alias**: `cdo-rails:release-<tag>`, one per legacy release, pointing at the digest the live tag was moved to for that release. The durable record of which release maps to which image.
- **Merge base**: the newest commit two branches share. For a release commit and `staging`, it is the staging commit the release contains.
- **Candidate**: in Kargo's auto-promotion, the newest available Freight for a Stage's origin. It is what Kargo promotes when auto-promotion is on.
- **Hold**: Kargo's record, on a Stage, that a person promoted something other than the candidate. While a hold stands, Kargo auto-promotes nothing from that origin. Resuming is promoting the candidate by hand or using the Stage's Resume action.
