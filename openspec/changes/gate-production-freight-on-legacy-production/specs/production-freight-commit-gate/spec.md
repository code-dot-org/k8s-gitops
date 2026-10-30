## ADDED Requirements

### Requirement: Production promotion verifies legacy ancestry before any write

The `production` Stage promotion template SHALL run, before `git-clone`, two HTTP steps against the GitHub compare endpoint for `production...<revision>`, where the revision is the Freight's `cdo-rails` image annotation `org.opencontainers.image.revision`. The step `freight-has-revision` SHALL succeed on response status 200 and fail terminally on 404 or 422. The step `revision-in-legacy-production` SHALL succeed on status 200 with `ahead_by` 0 and fail terminally on status 200 with `ahead_by` greater than 0. Any other response SHALL be retried until the step's five-minute timeout and then fail. When either step fails, the Promotion SHALL fail at that step and no later step SHALL run. Kargo 1.9.5 reports a met failure criterion only as `HTTP (<status>) response met failure criteria`, so the failing step's name SHALL be the operator's diagnostic.

#### Scenario: Freight commit is already in legacy production

- **WHEN** the revision is an ancestor of, or equal to, the `production` branch HEAD
- **THEN** GitHub reports status `behind` or `identical` with `ahead_by` 0
- **AND** both steps succeed and the promotion proceeds to clone, update, commit, push and Argo sync

#### Scenario: Freight commit is ahead of legacy production

- **WHEN** the revision contains commits not in the `production` branch
- **THEN** GitHub reports `ahead` or `diverged` with `ahead_by` greater than 0
- **AND** `freight-has-revision` succeeds and the Promotion fails at `revision-in-legacy-production` with Kargo's message carrying HTTP 200
- **AND** the production values file in k8s-gitops is unchanged

#### Scenario: Freight has no revision annotation

- **WHEN** the Freight was built before the image carried `org.opencontainers.image.revision`
- **THEN** the compare URL has an empty revision, GitHub returns 404, and the Promotion fails at `freight-has-revision` with Kargo's message carrying HTTP 404
- **AND** the production values file in k8s-gitops is unchanged

#### Scenario: GitHub is unavailable

- **WHEN** the compare call returns a 5xx status or times out
- **THEN** the step retries for up to five minutes and then fails
- **AND** neither step ever succeeds without a 200 response

### Requirement: Gate applies to every promotion into production

The ancestry steps SHALL run for every Promotion targeting the `production` Stage, whether created from the Kargo UI, the CLI, or any future automation. The `staging` and `test` Stages SHALL NOT carry them. The project's promotion policy SHALL keep `autoPromotionEnabled: false` for `production`.

#### Scenario: Manual promotion from the UI

- **WHEN** an engineer promotes Freight to `production` from the Kargo UI
- **THEN** the ancestry steps run first and their results are visible on the Promotion

#### Scenario: Staging and test are unaffected

- **WHEN** new Freight is auto-promoted to `staging` and `test`
- **THEN** no ancestry check runs and those promotions behave as before

### Requirement: Gate failures lead the operator to the runbook

The production Stage manifest SHALL carry a header comment that names both gate steps and links to the promotion runbook, and the Kargo project directory SHALL carry a README that links to the runbook. The runbook SHALL map each step and HTTP status to its cause and give the compare URL to run by hand.

#### Scenario: A promotion fails at the gate

- **WHEN** an operator sees a Promotion failed at `freight-has-revision` or `revision-in-legacy-production`
- **THEN** the step name identifies the rule that failed, and the Stage manifest comment and project README point to `docs/production-promotion.md`

### Requirement: The gate expressions are rehearsed before production is enabled

Before the production deployment is enabled, both steps SHALL be exercised on the `levelbuilder` Stage by adding them there temporarily and promoting three Freight: one without a revision annotation, the newest available, and the one whose revision equals the merge base of `production` and `staging`. The steps SHALL be removed from `levelbuilder` afterwards.

#### Scenario: Rehearsal outcomes

- **WHEN** the three Freight are promoted to `levelbuilder` with the steps in place
- **THEN** the first fails at `freight-has-revision`, the second fails at `revision-in-legacy-production`, and the third passes both steps
- **AND** the three Promotion statuses are recorded in the runbook as reference signatures
