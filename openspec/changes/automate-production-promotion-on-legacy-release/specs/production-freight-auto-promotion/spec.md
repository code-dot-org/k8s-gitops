## ADDED Requirements

### Requirement: A dedicated Warehouse follows the production tag

The Kargo project `kargo-project-codeai` SHALL contain a Warehouse `kargo-project-codeai-production` with one image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest` and `constraint: production`. The existing Warehouse following `latest` SHALL be unchanged.

#### Scenario: The production tag moves to a new digest

- **WHEN** the release workflow moves `cdo-rails:production` to a digest the Warehouse has not seen
- **THEN** within one Warehouse refresh exactly one new Freight exists from that Warehouse, carrying that digest and its revision annotation

#### Scenario: The production tag is pointed at a known digest

- **WHEN** `cdo-rails:production` is moved to a digest for which Freight from this Warehouse already exists
- **THEN** no new Freight is created and no Promotion follows

### Requirement: The production Stage promotes Freight from that Warehouse without a person

The `production` Stage SHALL request Freight only from `kargo-project-codeai-production` with `sources.direct: true`, and the project promotion policy SHALL set `autoPromotionEnabled: true` for `production`. The promotion template SHALL keep the gate step `legacy-ancestry` as its first step.

#### Scenario: New Freight appears from the production Warehouse

- **WHEN** the Warehouse creates Freight for a new digest
- **THEN** Kargo creates a Promotion for `production` with no human action, the gate step runs first and passes, and the production values file is updated to that digest

#### Scenario: Freight from the shared Warehouse

- **WHEN** an operator attempts to promote Freight from `kargo-project-codeai` (the `latest` Warehouse) to `production`
- **THEN** Kargo rejects it because the Stage does not request Freight from that origin

### Requirement: The cutover preserves a rollback target

Before the production Stage is switched to the production Warehouse, that Warehouse SHALL hold Freight for both the previous and the current legacy release, the previous one created first. They SHALL be created by seeding the `production` tag with the previous release and then the current one, before any release-triggered run has created the tag and while the Stage still sources from the shared Warehouse, so that the current release's Freight is the newer by creation time and the auto-promotion candidate.

Before the switch, an operator SHALL confirm that the newest Freight from the Warehouse carries the digest `cdo-rails:production` resolves to and that this is the latest release's digest. If it does not, the Stage SHALL NOT be switched until a newer release has produced Freight that does.

#### Scenario: Switching the Stage

- **WHEN** the Stage's requested Freight is changed to the production Warehouse and auto-promotion is enabled
- **THEN** the Warehouse already holds at least two Freight, the newest by creation time is the current release's, Kargo promotes it, and the older one is available for rollback from the first automatic promotion onward

#### Scenario: Freight discovered in the wrong order

- **WHEN** the Warehouse created the current release's Freight before the previous release's
- **THEN** the Stage is not switched, no Freight is deleted or edited by hand, and the switch waits for the next release, whose Freight becomes the newest and the candidate

#### Scenario: The tag exists before seeding

- **WHEN** `cdo-rails:production` already exists when seeding starts
- **THEN** the previous release is not seeded, the Warehouse holds the current release only, and the rollback target arrives with the next release

### Requirement: Manual rollback is possible, reviewed, and holds automation until a person resumes

A person SHALL be able to promote an older Freight from the production Warehouse to `production`.

- Before doing so, for every rollback including to the previous release, they SHALL review the migrations added between the two commits for destructive changes, because the gate certifies missing prerequisites only.
- Because that Freight is not the auto-promotion candidate, Kargo SHALL record an auto-promotion hold for the Stage once the Promotion completes.
- While the hold stands, Kargo SHALL NOT auto-promote any Freight from the production Warehouse, including Freight from later releases.
- The hold SHALL end when a person promotes the current candidate by hand or uses the Stage's Resume action.

#### Scenario: Rollback to the previous release

- **WHEN** an operator reviews the migrations between the two releases, finds none destructive, and promotes the previous production Freight
- **THEN** the gate passes, the rollout completes, the Stage shows an auto-promotion hold, and the newest Freight is not re-promoted

#### Scenario: A release arrives while a hold stands

- **WHEN** the release workflow moves the `production` tag to a new digest during a hold
- **THEN** the Warehouse creates Freight for it and no Promotion is created until a person resumes

#### Scenario: Resuming after a rollback

- **WHEN** the operator promotes the newest production Freight by hand after the compatibility review, or uses the Stage's Resume action
- **THEN** the hold ends and later releases auto-promote again

### Requirement: A failed automatic promotion is visible, not retried by Kargo, and recoverable by hand

When the gate step fails an automatic Promotion, the following SHALL hold:

- Kargo SHALL NOT create another Promotion for that Freight while its newest Promotion is not Succeeded.
- The Promotion SHALL show as Failed at `legacy-ancestry` with the HTTP status and the message naming the cause.
- The production values file SHALL be unchanged.
- Recovery from a transient cause SHALL be a manual promotion of the same Freight.
- Recovery from a wrong digest SHALL be a corrected tag move that yields new Freight (with `move_live_tag` when the corrected commit is older than the live revision), or a manual promotion when the correct digest already has Freight.

#### Scenario: GitHub is unavailable during the automatic promotion

- **WHEN** the gate step times out and the Promotion fails
- **THEN** Kargo creates no further Promotion for that Freight, re-running the release workflow creates no Freight, and the operator promotes the same Freight by hand once GitHub is back

#### Scenario: The workflow resolved a commit that is not in production

- **WHEN** the production Freight's revision is not contained in `production`
- **THEN** the automatic Promotion fails at `legacy-ancestry` with the ahead-by message and nothing is written
- **AND** a corrected `workflow_dispatch` run, with `move_live_tag` if the corrected commit is older than the live revision, moves the tag to a new digest and produces new Freight and a new automatic Promotion

### Requirement: Automation can be paused with one commit

Setting `autoPromotionEnabled: false` for `production` in `project-config.yaml` SHALL stop automatic Promotions while leaving Freight creation and manual promotion working. Disabling it clears any auto-promotion hold, and restoring it SHALL promote the newest production Freight at once if that Freight is not current.

#### Scenario: Pause during an incident

- **WHEN** the flag is set to `false` and the change is synced
- **THEN** new production Freight appears without a Promotion until a person promotes it or restores the flag

#### Scenario: Resuming after a pause

- **WHEN** the flag is restored while the newest production Freight is not the one deployed
- **THEN** Kargo promotes that Freight immediately, so the operator restores the flag only once that Freight is what production should run
