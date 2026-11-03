## ADDED Requirements

### Requirement: A runbook defines the production promotion procedure

k8s-gitops SHALL contain `docs/production-promotion.md` describing how Freight is promoted to `production`. It SHALL state the rule (the image's commit is contained in what legacy production runs) and the gate that enforces it; when to promote (only after the GitHub release for the DTP that carried the commit exists, because the `production` branch moves one to two minutes before that deploy's `db:migrate` finishes and the gate reads the branch); the checks the operator performs before promoting (the Freight is verified in `test`; the release exists); the checks after promoting (production pods `Running`, and whatever application-level health signal exists at the time, such as a Honeybadger test exception raised from a production worker or a canary job); rollout and rollback timing given the worker's 2100-second termination grace period; the rollback procedure (re-promote an earlier Freight, which passes the gate; before every rollback, including to the previous Freight, list the migrations added between the two commits and review them for `drop_table`, `remove_column` and renames, because the gate certifies missing prerequisites only and not that older code fits a newer schema); the failure signatures in Kargo (Promotion failed at `legacy-ancestry` with either the no-revision message and HTTP 404 or 422, or the ahead-by message and HTTP 200, with the compare URL to run by hand for the full comparison); the hotfix caveat (a direct push to `production` moves the marker without a release, and the gate still works); and the accepted gaps: a legacy migration rollback after a promotion, which nothing in k8s notices and which the operator answers by re-promoting the Freight whose commit matches the rolled-back branch, and hand edits to the production values file, which bypass the gate and are not a sanctioned path.

#### Scenario: First production promotion

- **WHEN** an operator performs the first promotion to `production`
- **THEN** they can complete every step and check from the runbook alone

#### Scenario: Promotion blocked by the gate

- **WHEN** a promotion fails at the gate step
- **THEN** the runbook explains the cause, the expected wait (the next DTP and its release), and the alternatives (wait, promote an older Freight)

#### Scenario: Rollback

- **WHEN** a promoted Freight must be rolled back
- **THEN** the runbook's procedure reviews the migrations added between the two commits, re-promotes the earlier Freight through Kargo, and states how long the worker pod may take to drain

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
