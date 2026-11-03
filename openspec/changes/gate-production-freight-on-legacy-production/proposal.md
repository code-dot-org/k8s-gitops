## Why

The `cdo-rails` image promoted into the `production` namespace must never be built from a commit newer than the one legacy production runs: the image carries no migrations, schema changes reach the production database only through the legacy EC2 deploy, and a worker running code ahead of that schema fails jobs confusingly. Today nothing enforces the rule. The only control is a human at the Kargo gate (`autoPromotionEnabled: false`), and that human cannot even tell which commit a Freight came from, because the image index carries no commit and the Warehouse follows the mutable `latest` tag by digest. This change makes the rule machine-enforced at the Kargo step, and is required before we turn the production deployment on.

Precisely: a k8s image is built from a `staging` commit, while legacy production runs a merge commit on the `production` branch, so "the same commit is running in legacy production" means the image's source commit is contained in (is an ancestor of, or equal to) the commit legacy production runs. Running behind is safe with respect to the hazard this change addresses: an older image has no unapplied migration prerequisites. It is not a guarantee that older code works against a newer schema. The repository ships destructive migrations every year (tables and columns dropped or renamed), and an image from before such a migration can pass the gate and still break, exactly as a legacy code rollback would. The gate certifies the first property only; the runbook's rollback procedure carries the second.

A runtime schema guard (an initContainer comparing the image's migration set with `schema_migrations`) was designed alongside the gate and dropped as more than the problem needs. The gaps it would have closed are listed under Accepted risks below, each with what stands in for it.

## What Changes

- **Image provenance (code-dot-org CI).** Every published `cdo-rails` index becomes an OCI image index annotated with `org.opencontainers.image.revision` = the staging commit it was built from, so Kargo Freight carries the commit.
- **Kargo commit gate (k8s-gitops).** The `production` Stage promotion template gets one `http` step, `legacy-ancestry`, before anything is cloned or written. It asks GitHub to compare the Freight's commit with the `production` branch, passes only when the commit is contained in the branch, and fails the Promotion with a message naming the cause: the revision is missing or unknown, or the commit is a stated number of commits ahead of or diverged from the branch. **BREAKING** for the Kargo path: Freight built before the CI change has no annotation and can no longer be promoted to production. Intentional; no Freight is in production today.
- **Promotion runbook (k8s-gitops).** New `docs/production-promotion.md`: the rule, the gate, when to promote (only after the GitHub release for that DTP exists, which closes the window between a merge and `db:migrate`), what the human still verifies, rollback, timing, failure signatures, the hotfix caveat and the accepted gaps. Linked from the Kargo project directory.
- **Unchanged on purpose.** Promotion to production stays a manual decision; who may promote is not narrowed; the gate applies to `production` only, since for staging it is trivially true and for test it would fail every auto-promotion until the next DTT; the Helm chart, the pods and the staging and test namespaces are untouched; no new cluster infrastructure (no policy engine, no Argo Rollouts, no tofu).

## Accepted risks

The gate runs once, at promotion time, on the Kargo path. These gaps are accepted; a runtime guard is the follow-up if any of them bites.

- **The window between a DTP merge and `db:migrate`.** The `production` branch moves one to two minutes before the migration finishes, so a promotion inside that window passes the gate and starts a pod ahead of the schema. The runbook's rule is to promote only after the GitHub release for that DTP exists, which is created after the whole legacy deploy; the automation change removes the human from this path entirely.
- **Anything that bypasses Kargo.** A hand-edited production `values.yaml` deploys whatever digest it names. That is a reviewed commit; the runbook states the Kargo gate is the only sanctioned path.
- **A legacy migration rollback after promotion.** Nothing in k8s notices. Legacy rarely rolls a migration back; when it does, the runbook has the operator re-promote the Freight whose commit matches the rolled-back branch.
- **Staging and test.** The gate is production-only. Those namespaces share databases with legacy staging and test and already run images ahead of them today; this change leaves that as it is.

## Capabilities

### New Capabilities

- `cdo-rails-image-provenance`: the published image index names its source commit.
- `production-freight-commit-gate`: Kargo refuses to promote Freight to `production` unless its commit is contained in the legacy `production` branch; fails closed.
- `production-promotion-runbook`: the manual procedure around the gate: when to promote, pre- and post-promotion checks, rollback, failure signatures, the accepted gaps, and the policy that production promotion stays manual.

### Modified Capabilities

None. `openspec/specs/` holds no existing capabilities.

## Impact

- **code-dot-org** (one PR to `staging`): `.github/workflows/cdo-rails-image.yml` (regctl-built OCI index in the merge job) and `docker/rails/README.md` (tag contract). No image content, chart or runtime change.
- **k8s-gitops** (branch `INF-2281/promotion-gates`): `apps/kargo/projects/codeai/stages/production.yaml`, new `docs/production-promotion.md`, new `apps/kargo/projects/codeai/README.md`. No chart under `apps/` changes, so no `Chart.yaml` bump there; no `apps/app-of-apps` structure change, so no mimic-tree edit.
- **Runtime behaviour**: one GitHub API call per production promotion from the Kargo controller (unauthenticated, 60/hour limit); one new failure state operators must recognise (Promotion failed at `legacy-ancestry` with a message naming the cause).
- **Sequencing**: the Kargo step can land any time after the first annotated image exists. The production deployment is enabled by a separate change, which this design assumes sets `branch: production` so the chart deployed to production comes from the same commit lineage as the promoted image. The step's failure message uses the `http` step's `errorExpression`, available since Kargo 1.11; the cluster runs Kargo 1.12.5 with its admission webhooks enabled. Any NetworkPolicy added later must keep allowing the Kargo controller's GitHub egress.
