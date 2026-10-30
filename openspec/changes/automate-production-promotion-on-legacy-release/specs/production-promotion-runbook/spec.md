## MODIFIED Requirements

### Requirement: A runbook defines the production promotion procedure

k8s-gitops SHALL contain `docs/production-promotion.md` describing how Freight reaches `production` and what a person does around it. It SHALL state the rule (the image's commit is contained in what legacy production runs, and every migration the image expects is applied in the production database) and the two gates that enforce it; the automated path (legacy release, the release workflow, the `production` tag, the production Warehouse, auto-promotion, the two gate steps running first) with the expected delay from release to rollout; how to map a release to a digest and a digest to a release (the workflow job summary, the `release-<tag>` alias, the Freight's revision annotation) and how to check whether the `latest` Warehouse holds Freight with the same digest verified in `test`, with the statement that production eligibility rests on CI's suites and the two gates rather than on that check; the checks after an automatic promotion (production pods `Running`, the `schema-guard` log, and whatever application-level health signal exists at the time); rollout and rollback timing given the worker's 2100-second termination grace period; the rollback procedure (promote an older production Freight by hand, which passes both gates and which Kargo does not undo until a release yields a new digest; before every rollback, including to the previous release, list the migrations added between the two commits and review them for destructive changes, since the gates certify missing prerequisites only); how to pause automation (`autoPromotionEnabled: false` in `project-config.yaml`) and the obligation to restore it; the failure signatures and recoveries (workflow failed before the live copy: nothing changed, re-run; workflow failed at or after the live copy: inspect the registry digest of `production`, the Warehouse and any Promotion before acting; exact image missing: choose a candidate with the `image_commit` override after the compatibility review; Promotion failed at `freight-has-revision` or `revision-in-legacy-production`: Kargo never retries that Freight, the step name and HTTP status say why, a transient cause means promoting the same Freight by hand, a wrong digest means a corrected tag move that yields new Freight; pod `Init:Error` with `kubectl logs -c schema-guard`; Argo `Degraded` while a rollout waits); the hotfix caveat (no release, so no promotion, and k8s production stays one step behind until the next DTP); that a manually created release in the production format triggers a promotion like any other; the emergency use of `schemaGuard.mode: warn` with the obligation to revert it; and that a Freight blocked by the guard in staging or test is not verified in that Stage.

#### Scenario: A release promotes itself

- **WHEN** an operator is paged or curious after a legacy release
- **THEN** the runbook lets them find the workflow run, the tag, the Freight, the Promotion and the pods for that release, and tells them what to check

#### Scenario: Promotion blocked by a gate

- **WHEN** an automatic promotion fails at a gate step or a pod sits in `Init:Error`
- **THEN** the runbook explains the cause, the expected wait or the recovery, that Kargo will not retry the failed Freight by itself, and that a transient failure is recovered by promoting the same Freight by hand

#### Scenario: Rollback

- **WHEN** a promoted release must be rolled back
- **THEN** the runbook's procedure reviews the migrations added between the two commits, promotes the older production Freight through Kargo, states how long the worker pod may take to drain, and states that automation resumes when a release yields a new digest

#### Scenario: Workflow failed after publishing

- **WHEN** a release workflow run reports "outcome unknown"
- **THEN** the runbook has the operator read the registry digest of `production`, list the production Warehouse's Freight and any Promotion for it, and decide from that state rather than re-running blindly

#### Scenario: Pausing automation

- **WHEN** an operator must stop releases from reaching k8s production for a while
- **THEN** the runbook gives the one-line change to `project-config.yaml` and the steps to resume

## REMOVED Requirements

### Requirement: Promotion to production remains a manual decision

**Reason**: Promotion to `production` is now created by Kargo's auto-promotion whenever the release workflow moves the `production` tag; the person's role moves to observing, pausing and rolling back.

**Migration**: The behaviour is specified by `production-freight-auto-promotion`. Who may create a Promotion is still unchanged; manual promotion remains the rollback mechanism and is covered by the runbook requirement above.
