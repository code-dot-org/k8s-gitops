## MODIFIED Requirements

### Requirement: A runbook defines the production promotion procedure

k8s-gitops SHALL contain `docs/production-promotion.md` describing how Freight reaches `production` and what a person does around it. It SHALL cover:

- **The rule and the gate.** The image's commit is contained in what legacy production runs, and the `legacy-ancestry` step enforces it. The release trigger is what keeps an automatic promotion behind the legacy deploy's `db:migrate`.
- **The automated path.** Legacy release, the release workflow, the `production` tag, the production Warehouse, auto-promotion, the gate step running first. The expected delay from release to rollout.
- **Tracing a release to a digest and back.** The workflow job summary, the `release-<tag>` alias, and the Freight's revision annotation. How to check whether the `latest` Warehouse holds Freight with the same digest verified in `test`, with the statement that production eligibility rests on CI's suites and the two gates rather than on that check.
- **Checks after an automatic promotion.** Production pods are `Running`, plus whatever application-level health signal exists at the time.
- **Rollout and rollback timing**, given the worker's 2100-second termination grace period.
- **The rollback procedure.** Promote an older production Freight by hand, which passes the gate. Kargo then records an auto-promotion hold that stops every automatic promotion, including later releases, until a person resumes by promoting the newest Freight by hand or using the Stage's Resume action. The procedure ends with that resume step. Before every rollback, including to the previous release, list the migrations added between the two commits and review them for destructive changes, since the gate certifies missing prerequisites only.
- **Pausing automation.** `autoPromotionEnabled: false` in `project-config.yaml`. Disabling clears any hold, restoring promotes the newest Freight at once if it is not current, and the operator is obliged to restore it.
- **Failure signatures and recoveries.** Workflow failed before the live copy: nothing changed, re-run. Workflow failed at or after the live copy: inspect the registry digest of `production`, the Warehouse and any Promotion before acting. Exact image missing: choose a candidate with the `image_commit` override after the compatibility review. Promotion failed at `legacy-ancestry`: Kargo never retries that Freight, the message and HTTP status say why, a transient cause means promoting the same Freight by hand, and a wrong digest means a corrected tag move that yields new Freight.
- **The hotfix caveat.** No release, so no promotion. k8s production stays one step behind until the next DTP.
- **A manually created release** in the production format triggers a promotion like any other.
- **The accepted gaps carried over from step one.** A legacy migration rollback after a promotion, answered by promoting the matching older Freight. Hand edits to the production values file, which bypass the gate.

#### Scenario: A release promotes itself

- **WHEN** an operator is paged or curious after a legacy release
- **THEN** the runbook lets them find the workflow run, the tag, the Freight, the Promotion and the pods for that release, and tells them what to check

#### Scenario: Promotion blocked by a gate

- **WHEN** an automatic promotion fails at the gate step
- **THEN** the runbook explains the cause, the expected wait or the recovery, that Kargo will not retry the failed Freight by itself, and that a transient failure is recovered by promoting the same Freight by hand

#### Scenario: Rollback

- **WHEN** a promoted release must be rolled back
- **THEN** the runbook's procedure reviews the migrations added between the two commits, promotes the older production Freight through Kargo, states how long the worker pod may take to drain, and states that automation stays held until the operator resumes it, and how

#### Scenario: Workflow failed after publishing

- **WHEN** a release workflow run reports "outcome unknown"
- **THEN** the runbook has the operator read the registry digest of `production`, list the production Warehouse's Freight and any Promotion for it, and decide from that state rather than re-running blindly

#### Scenario: Pausing automation

- **WHEN** an operator must stop releases from reaching k8s production for a while
- **THEN** the runbook gives the one-line change to `project-config.yaml`, the steps to resume, and the warning that restoring the flag promotes the newest Freight at once

## REMOVED Requirements

### Requirement: Promotion to production remains a manual decision

**Reason**: Promotion to `production` is now created by Kargo's auto-promotion whenever the release workflow moves the `production` tag. The person's role moves to observing, pausing and rolling back.

**Migration**: The behaviour is specified by `production-freight-auto-promotion`. Who may create a Promotion is still unchanged. Manual promotion remains the rollback mechanism and is covered by the runbook requirement above.
