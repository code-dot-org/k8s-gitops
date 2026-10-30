## ADDED Requirements

### Requirement: A dedicated Warehouse follows the production tag

The Kargo project `kargo-project-codeai` SHALL contain a Warehouse `kargo-project-codeai-production` with one image subscription to `ghcr.io/code-dot-org/cdo-rails`, `imageSelectionStrategy: Digest` and `constraint: production`. The existing Warehouse following `latest` SHALL be unchanged.

#### Scenario: The production tag moves to a new digest

- **WHEN** the release workflow moves `cdo-rails:production` to a digest the Warehouse has not seen
- **THEN** within one Warehouse refresh exactly one new Freight exists from that Warehouse carrying that digest and its revision annotation

#### Scenario: The production tag is pointed at a known digest

- **WHEN** `cdo-rails:production` is moved to a digest for which Freight from this Warehouse already exists
- **THEN** no new Freight is created and no Promotion follows

### Requirement: The production Stage promotes Freight from that Warehouse without a person

The `production` Stage SHALL request Freight only from `kargo-project-codeai-production` with `sources.direct: true`, and the project promotion policy SHALL set `autoPromotionEnabled: true` for `production`. The promotion template SHALL keep the two gate steps, `freight-has-revision` and `revision-in-legacy-production`, as its first steps.

#### Scenario: New Freight appears from the production Warehouse

- **WHEN** the Warehouse creates Freight for a new digest
- **THEN** Kargo creates a Promotion for `production` with no human action, the two gate steps run first and pass, and the production values file is updated to that digest

#### Scenario: Freight from the shared Warehouse

- **WHEN** an operator attempts to promote Freight from `kargo-project-codeai` (the `latest` Warehouse) to `production`
- **THEN** Kargo rejects it because the Stage does not request Freight from that origin

### Requirement: The cutover preserves a rollback target

Before the production Stage is switched to the production Warehouse, that Warehouse SHALL hold Freight for both the previous and the current legacy release, created by seeding the `production` tag with each in turn while the Stage still sources from the shared Warehouse.

#### Scenario: Switching the Stage

- **WHEN** the Stage's requested Freight is changed to the production Warehouse and auto-promotion is enabled
- **THEN** the Warehouse already holds at least two Freight, Kargo promotes the newest, and the older one is available for rollback from the first automatic promotion onward

### Requirement: Manual rollback is possible, reviewed, and not undone

A person SHALL be able to promote an older Freight from the production Warehouse to `production`. Before doing so, for every rollback including to the previous release, they SHALL review the migrations added between the two commits for destructive changes, because the gates certify missing prerequisites only. Kargo SHALL NOT automatically re-promote the newest Freight afterwards, because a Promotion for it already exists.

#### Scenario: Rollback to the previous release

- **WHEN** an operator reviews the migrations between the two releases, finds none destructive, and promotes the previous production Freight
- **THEN** both gates pass, the rollout completes, and the Stage stays on that Freight until a release yields a digest the Warehouse has not seen

### Requirement: A failed automatic promotion is visible, not retried by Kargo, and recoverable by hand

When a gate step fails an automatic Promotion, Kargo SHALL NOT create another Promotion for that Freight, the Promotion SHALL show as Failed at that step with Kargo's HTTP status message, and the production values file SHALL be unchanged. Recovery from a transient cause SHALL be a manual promotion of the same Freight. Recovery from a wrong digest SHALL be a corrected tag move that yields new Freight, or a manual promotion when the correct digest already has Freight.

#### Scenario: GitHub is unavailable during the automatic promotion

- **WHEN** the gate steps time out and the Promotion fails
- **THEN** Kargo creates no further Promotion for that Freight, re-running the release workflow creates no Freight, and the operator promotes the same Freight by hand once GitHub is back

#### Scenario: The workflow resolved a commit that is not in production

- **WHEN** the production Freight's revision is not contained in `production`
- **THEN** the automatic Promotion fails at `revision-in-legacy-production`, nothing is written, and a corrected `workflow_dispatch` run that moves the tag to a new digest produces new Freight and a new automatic Promotion

### Requirement: Automation can be paused with one commit

Setting `autoPromotionEnabled: false` for `production` in `project-config.yaml` SHALL stop automatic Promotions while leaving Freight creation and manual promotion working.

#### Scenario: Pause during an incident

- **WHEN** the flag is set to `false` and the change is synced
- **THEN** new production Freight appears without a Promotion until a person promotes it or restores the flag
