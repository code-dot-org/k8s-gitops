## ADDED Requirements

### Requirement: A runbook defines the production promotion procedure

k8s-gitops SHALL contain `docs/production-promotion.md` describing how Freight is promoted to `production`. It SHALL state the rule (the image's commit is contained in what legacy production runs, and every migration the image expects is applied in the production database) and the two gates that enforce it; the checks the operator performs before promoting (the Freight is verified in `test`; `schemaGuard.mode` is `enforce`); the checks after promoting (production pods `Running`, the `schema-guard` log, and whatever application-level health signal exists at the time, such as a Honeybadger test exception raised from a production worker or a canary job); rollout and rollback timing given the worker's 2100-second termination grace period; the rollback procedure (re-promote an earlier Freight, which passes both gates; before every rollback, including to the previous Freight, list the migrations added between the two commits and review them for `drop_table`, `remove_column` and renames, because the gates certify missing prerequisites only and not that older code fits a newer schema); the failure signatures in Kargo (Promotion failed at `freight-has-revision`, meaning no or unknown revision with HTTP 404, or at `revision-in-legacy-production`, meaning the commit is ahead with HTTP 200, with the compare URL to run by hand since Kargo's own message is generic), in the cluster (`Init:Error`, `kubectl logs -c schema-guard`) and in Argo (`Degraded` while a rollout waits for the legacy deploy); the hotfix caveat (a direct push to `production` moves the marker without a release, and both gates still work); the emergency use of `mode: warn` with the obligation to revert it; and that a Freight blocked by the guard in staging or test is not verified in that Stage, and so not promotable to production, until that database has caught up.

#### Scenario: First production promotion

- **WHEN** an operator performs the first promotion to `production`
- **THEN** they can complete every step and check from the runbook alone

#### Scenario: Promotion blocked by a gate

- **WHEN** a promotion fails at one of the two gate steps or a pod sits in `Init:Error`
- **THEN** the runbook explains the cause, the expected wait (legacy DTP merge or `db:migrate`), and the alternatives (wait, promote an older Freight)

#### Scenario: Rollback

- **WHEN** a promoted Freight must be rolled back
- **THEN** the runbook's procedure reviews the migrations added between the two commits, re-promotes the earlier Freight through Kargo, and states how long the worker pod may take to drain

### Requirement: The runbook is discoverable from the places an operator looks

`apps/kargo/projects/codeai/README.md` SHALL link to the runbook, and the header comment in `stages/production.yaml` SHALL link to it.

#### Scenario: Reading the production Stage

- **WHEN** an engineer opens `apps/kargo/projects/codeai/stages/production.yaml`
- **THEN** the header comment above the two gate steps names them and links to `docs/production-promotion.md`

#### Scenario: Reading the Kargo project directory

- **WHEN** an engineer opens `apps/kargo/projects/codeai/`
- **THEN** the README explains the gate and links to the runbook, and Argo ignores the README

### Requirement: Promotion to production remains a manual decision

`autoPromotionEnabled` SHALL remain `false` for the `production` Stage, and this change SHALL NOT alter who may create a Promotion.

#### Scenario: New Freight verified in test

- **WHEN** Freight becomes verified in `test`
- **THEN** no Promotion to `production` is created until a person creates one
