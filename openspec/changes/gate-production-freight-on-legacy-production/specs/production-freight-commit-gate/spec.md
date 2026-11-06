## ADDED Requirements

### Requirement: Production promotion verifies legacy ancestry before any write

The `production` Stage promotion template SHALL run one HTTP step named `legacy-ancestry` before `git-clone`. The step SHALL call the GitHub compare endpoint for `production...<revision>`, where the revision is the Freight's `cdo-rails` image annotation `org.opencontainers.image.revision`.

- The step SHALL succeed on response status 200 with `ahead_by` 0.
- It SHALL fail terminally on status 404 or 422, and on status 200 with `ahead_by` greater than 0.
- Its error expression SHALL render a message naming the cause: either that the Freight has no revision annotation or GitHub does not know the commit (with the HTTP status), or that the image commit is a stated number of commits ahead of legacy production (with GitHub's `status` word).
- Any other response SHALL leave the step running and re-polled until the step's five-minute timeout, then fail.
- When the step fails, the Promotion SHALL fail at it and no later step SHALL run.

#### Scenario: Freight commit is already in legacy production

- **WHEN** the revision is an ancestor of, or equal to, the `production` branch HEAD
- **THEN** GitHub reports status `behind` or `identical` with `ahead_by` 0
- **AND** the step succeeds and the promotion proceeds to clone, update, commit, push and Argo sync

#### Scenario: Freight commit is ahead of legacy production

- **WHEN** the revision contains commits not in the `production` branch
- **THEN** GitHub reports `ahead` or `diverged` with `ahead_by` greater than 0
- **AND** the Promotion fails at `legacy-ancestry` with Kargo's message carrying HTTP 200 and the text stating how many commits ahead the image is
- **AND** the production values file in k8s-gitops is unchanged

#### Scenario: Freight has no revision annotation

- **WHEN** the Freight was built before the image carried `org.opencontainers.image.revision`
- **THEN** the compare URL has an empty revision, GitHub returns 404, and the Promotion fails at `legacy-ancestry` with Kargo's message carrying HTTP 404 and the no-revision text
- **AND** the production values file in k8s-gitops is unchanged

#### Scenario: GitHub is unavailable

- **WHEN** the compare call returns a 5xx status or times out
- **THEN** the step stays running, is re-polled, and fails after five minutes
- **AND** the step never succeeds without a 200 response

### Requirement: Gate applies to every promotion into production

The ancestry step SHALL run for every Promotion targeting the `production` Stage, whether created from the Kargo UI, the CLI, or any future automation. The `staging` and `test` Stages SHALL NOT carry it. The project's promotion policy SHALL keep `autoPromotionEnabled: false` for `production`.

#### Scenario: Manual promotion from the UI

- **WHEN** an engineer promotes Freight to `production` from the Kargo UI
- **THEN** the ancestry step runs first and its result is visible on the Promotion

#### Scenario: Staging and test are unaffected

- **WHEN** new Freight is auto-promoted to `staging` and `test`
- **THEN** no ancestry check runs and those promotions behave as before

### Requirement: Gate failures lead the operator to the runbook

The production Stage manifest SHALL carry a header comment that names the gate step and links to the promotion runbook. The Kargo project directory SHALL carry a README that links to the runbook. The runbook SHALL map each failure message and HTTP status to its cause and give the compare URL to run by hand.

#### Scenario: A promotion fails at the gate

- **WHEN** an operator sees a Promotion failed at `legacy-ancestry`
- **THEN** the step's message identifies the rule that failed, and the Stage manifest comment and project README point to `docs/production-promotion.md`

### Requirement: The gate expressions are rehearsed before production is enabled

Before the production deployment is enabled, the step SHALL be exercised on the `levelbuilder` Stage by adding it there temporarily and promoting three Freight: one without a revision annotation, the newest available, and the one whose revision equals the merge base of `production` and `staging`. The step SHALL be removed from `levelbuilder` afterwards.

#### Scenario: Rehearsal outcomes

- **WHEN** the three Freight are promoted to `levelbuilder` with the step in place
- **THEN** the first fails with HTTP 404 and the no-revision message, the second fails with HTTP 200 and the ahead-by message, and the third passes the step
- **AND** the three Promotion statuses are recorded in the runbook as reference signatures
