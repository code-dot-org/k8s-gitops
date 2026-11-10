## ADDED Requirements

### Requirement: A runbook defines the production promotion procedure

k8s-gitops SHALL contain `docs/production-promotion.md` describing how Freight is promoted to `production`. It SHALL cover:

- **The rule and the gate.** The image's commit is contained in what legacy production runs, and the `legacy-ancestry` step enforces it.
- **When to promote.** Only after the GitHub release for the DTP that carried the commit exists. The `production` branch moves one to two minutes before that deploy's `db:migrate` finishes, and the gate reads the branch.
- **Checks before promoting.** The Freight is verified in `test`; the release exists.
- **Checks after promoting.** Production pods are `Running`, plus whatever application-level health signal exists at the time, such as a Honeybadger test exception raised from a production worker or a canary job.
- **Rollout and rollback timing**, given the worker's 2100-second termination grace period.
- **The rollback procedure.** Re-promote an earlier Freight, which passes the gate. Before every rollback, including to the previous Freight, list the migrations between the older Freight's commit and the revision legacy production has deployed, and review them for `drop_table`, `remove_column` and renames. The Freight being replaced is not the upper bound, since the shared database can be ahead of it. The gate certifies missing prerequisites only, not that older code fits a newer schema.
- **Failure signatures in Kargo.** A Promotion failed at `legacy-ancestry` with either the no-revision message and HTTP 404 or 422, or the ahead-by message and HTTP 200. The compare URL to run by hand for the full comparison. A Promotion failed at `argocd-update` with "application not found", expected only while the production deployment is disabled, and how the rehearsal's passing case ends.
- **The rehearsal record.** The three reference Promotion statuses from the rehearsal on the production Stage, so a live failure can be matched against a known one.
- **The hotfix caveat.** A direct push to `production` moves the marker without a release, and the gate still works.
- **The accepted gaps.** A legacy migration rollback after a promotion, which nothing in k8s notices and which the operator answers by re-promoting the Freight whose commit matches the rolled-back branch. Hand edits to the production values file, which bypass the gate and are not a sanctioned path.

#### Scenario: First production promotion

- **WHEN** an operator performs the first promotion to `production`
- **THEN** they can complete every step and check from the runbook alone

#### Scenario: Promotion blocked by the gate

- **WHEN** a promotion fails at the gate step
- **THEN** the runbook explains the cause, the expected wait (the next DTP and its release), and the alternatives (wait, or promote an older Freight)

#### Scenario: Rollback

- **WHEN** a promoted Freight must be rolled back
- **THEN** the runbook's procedure reviews the migrations between the older Freight's commit and the legacy `production` branch, re-promotes the earlier Freight through Kargo, and states how long the worker pod may take to drain

#### Scenario: Legacy rolled a migration back

- **WHEN** legacy production is rolled back to a commit from before a migration
- **THEN** the runbook has the operator re-promote the Freight whose commit is contained in the rolled-back branch, after the same destructive-migration review

### Requirement: The runbook is discoverable from the places an operator looks

`apps/kargo/projects/codeai/README.md` SHALL link to the runbook, and the header comment in `stages/production.yaml` SHALL link to it.

#### Scenario: Reading the production Stage

- **WHEN** an engineer opens `apps/kargo/projects/codeai/stages/production.yaml`
- **THEN** the header comment above the gate step names it and links to `docs/production-promotion.md`

#### Scenario: Reading the Kargo project directory

- **WHEN** an engineer opens `apps/kargo/projects/codeai/`
- **THEN** the README explains the gate and links to the runbook, and Argo ignores the README

### Requirement: Promotion to production remains a manual decision

`autoPromotionEnabled` SHALL remain `false` for the `production` Stage, and this change SHALL NOT alter who may create a Promotion.

#### Scenario: New Freight verified in test

- **WHEN** Freight becomes verified in `test`
- **THEN** no Promotion to `production` is created until a person creates one
