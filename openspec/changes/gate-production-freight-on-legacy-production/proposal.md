## Why

The `cdo-rails` image promoted into the `production` namespace must never be built from a commit newer than the one legacy production runs. The image carries no migrations. Schema changes reach the production database only through the legacy EC2 deploy. A worker running code ahead of that schema fails jobs in confusing ways.

Today nothing enforces this rule. The only control is a person at the Kargo gate (`autoPromotionEnabled: false` for `production`). That person cannot even tell which commit a Freight came from: the image index carries no commit, and the Warehouse follows the mutable `latest` tag by digest.

This change makes the rule machine-enforced at the Kargo promotion step. It is required before the production deployment is turned on.

### The rule, precisely

A k8s image is built from a `staging` commit. Legacy production runs a merge commit on the `production` branch. "The same commit is running in legacy production" therefore means the image's source commit is contained in the commit legacy production runs: it is an ancestor of it, or equal to it.

Running behind is safe with respect to the hazard this change addresses, because an older image has no unapplied migration prerequisites. It is not a guarantee that older code works against a newer schema. The repository ships destructive migrations every year (tables and columns dropped or renamed), and an image from before such a migration can pass the gate and still break, exactly as a legacy code rollback would. The gate certifies the first property only. The runbook's rollback procedure carries the second.

### Where this fits

This is step one of a two-step plan. Step two, `automate-production-promotion-on-legacy-release`, keeps this gate and removes the person from the promotion. Read this change first.

A runtime schema guard (an initContainer comparing the image's migration set with the database's `schema_migrations` table) was designed alongside the gate and dropped as more than the problem needs. The gaps it would have closed are listed under Accepted risks, each with what stands in for it.

## What Changes

- **Image provenance (code-dot-org CI).** Every published `cdo-rails` index becomes an OCI image index annotated with `org.opencontainers.image.revision`, the staging commit it was built from. Kargo Freight then carries the commit.
- **Kargo commit gate (k8s-gitops).** The `production` Stage's promotion template gets one `http` step, `legacy-ancestry`, that runs before anything is cloned or written.
  - It asks GitHub to compare the Freight's commit with the `production` branch and passes only when the commit is contained in the branch.
  - Otherwise it fails the Promotion with a message naming the cause: the revision is missing or unknown, or the commit is a stated number of commits ahead of the branch.
  - **BREAKING** for the Kargo path: Freight built before the CI change has no annotation and can no longer be promoted to production. This is intentional; no Freight is in production today.
- **Promotion runbook (k8s-gitops).** A new `docs/production-promotion.md` covers the rule, the gate, when to promote, what the person still verifies, rollback, timing, failure signatures, the hotfix caveat and the accepted gaps. It is linked from the Kargo project directory. Its central rule: promote only after the GitHub release for that DTP exists, which closes the window between a merge and `db:migrate`.
- **Unchanged on purpose.** Promotion to production stays a manual decision, and who may promote is not narrowed. The gate applies to `production` only: for staging it is trivially true, and for test it would fail every auto-promotion until the next DTT. The Helm chart, the pods and the staging and test namespaces are untouched. No new cluster infrastructure: no policy engine, no Argo Rollouts, no tofu.

## Accepted risks

The gate runs once, at promotion time, on the Kargo path. The gaps below are accepted. A runtime guard is the follow-up if any of them bites.

- **The window between a DTP merge and `db:migrate`.** The `production` branch moves one to two minutes before the migration finishes. A promotion inside that window passes the gate and starts a pod ahead of the schema. The runbook's rule is to promote only after the GitHub release for that DTP exists, which is created after the whole legacy deploy. Step two removes the person from this path entirely.
- **Anything that bypasses Kargo.** A hand-edited production `values.yaml` deploys whatever digest it names. That is a reviewed commit, and the runbook states that the Kargo gate is the only sanctioned path.
- **A legacy migration rollback after promotion.** Nothing in k8s notices. Legacy rarely rolls a migration back. When it does, the runbook has the operator re-promote the Freight whose commit matches the rolled-back branch.
- **Staging and test.** The gate is production-only. Those namespaces share databases with legacy staging and test and already run images ahead of them today. This change leaves that as it is.

## Capabilities

### New Capabilities

- `cdo-rails-image-provenance`: the published image index names its source commit.
- `production-freight-commit-gate`: Kargo refuses to promote Freight to `production` unless its commit is contained in the legacy `production` branch, and fails closed.
- `production-promotion-runbook`: the manual procedure around the gate. When to promote, checks before and after, rollback, failure signatures, the accepted gaps, and the policy that production promotion stays manual.

### Modified Capabilities

None. `openspec/specs/` holds no existing capabilities.

## Impact

- **code-dot-org**, one PR to `staging`: `.github/workflows/cdo-rails-image.yml` (the merge job builds the index with regctl) and `docker/rails/README.md` (tag contract). No image content, chart or runtime change.
- **k8s-gitops**, branch `INF-2281/promotion-gates`: `apps/kargo/projects/codeai/stages/production.yaml`, new `docs/production-promotion.md`, new `apps/kargo/projects/codeai/README.md`. No chart under `apps/` changes, so no `Chart.yaml` bump. No `apps/app-of-apps` structure change, so no mimic-tree edit.
- **Runtime behaviour**: one GitHub API call per production promotion from the Kargo controller, unauthenticated, within a 60-per-hour limit. One new failure state for operators to recognise: a Promotion failed at `legacy-ancestry` with a message naming the cause.
- **Sequencing**:
  - The Kargo step can land any time after the first annotated image exists.
  - Before the production deployment is enabled, the step is rehearsed on the production Stage itself, where a promotion can reach neither pods nor database until then.
  - The production deployment is enabled by a separate change, which this design assumes sets `branch: production`, so the chart deployed to production comes from the same commit lineage as the promoted image.
  - The step's failure message uses the `http` step's `errorExpression`, available since Kargo 1.11; the cluster runs Kargo 1.12.5 with its admission webhooks enabled.
  - Any NetworkPolicy added later must keep allowing the Kargo controller's GitHub egress.

## Terms

- **DTP, DTT**: the legacy "deploy to production" and "deploy to test" processes. A DTP merges a candidate into the `production` branch and rolls the EC2 fleet; a DTT does the same for `test`.
- **Legacy**: the EC2 fleet deployed by DTP, as opposed to the k8s (`codeai`) deployment.
- **Warehouse, Freight, Stage, Promotion**: Kargo terms. A Warehouse watches the registry and creates a Freight for each new image digest. A Stage is a deployment target (`staging`, `test`, `production`, `levelbuilder`). A Promotion is one run of a Stage's promotion template for one Freight.
- **OCI image index**: the multi-architecture manifest a tag points to. Its annotations are what Kargo can read.
- **Digest**: the immutable `sha256:` identity of an index. Tags move; digests do not.
