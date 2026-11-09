## Context

**Kargo today.** Kargo is 1.12.5 with its admission webhooks enabled. The `codeai` Kargo project has four Stages fed by one Warehouse, which follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest. `production` requests Freight from `test` and has `autoPromotionEnabled: false`. The production Argo Application exists but its workload is disabled; enabling it is a separate change. The disabled deployment file currently sets `branch: staging` behind a FIXME comment. This design assumes the enabling change sets `branch: production`, so the chart deployed to production comes from the same commit lineage as the promoted image.

**How legacy production deploys (DTP, "deploy to production").** `bin/dotd` merges a candidate into the `production` branch. Each production daemon polls that branch every minute. `db:migrate` runs within one to two minutes of the merge. The CloudFormation rolling AMI replacement takes about 45 minutes. `publish_github_release` tags a release at the end. Hotfixes are direct, non-merge pushes and never get a release.

**The image.** CI builds `cdo-rails` only on pushes to `staging`, tags the result `git-<sha>` and `latest`, and merges the two per-architecture images into a Docker manifest list with `docker buildx imagetools create`. That list carries no annotations, so a Kargo Freight knows a digest and nothing else. The same workflow also runs after each weekly `cdo-deps` publish and on manual dispatch, both on the default branch, and republishes `git-<sha>` and `latest` with new bytes. So `git-<sha>` is not immutable, despite the README's promise; only a digest is.

**What the image contains.** It ships `dashboard/db/schema.rb` and `schema_cache.yml` but not `dashboard/db/migrate`, so it cannot migrate. Rails itself only warns at boot when the database's schema version differs from the image's.

**Network.** The Kargo controller reaches api.github.com through NAT. There are no NetworkPolicies yet, so nothing stops the Kargo controller from calling GitHub as planned.

**Staging and test.** The k8s `staging` and `test` namespaces share databases with legacy staging and test and run images built from `staging` pushes. They already run ahead of their databases for minutes (staging) or hours (test) after a migration lands. That is out of scope here and recorded as an accepted risk.

## Goals / Non-Goals

**Goals:**

- Make it impossible, through Kargo, to promote Freight to `production` whose commit is not contained in the legacy `production` branch.
- Keep the gate fail-closed: no commit annotation, an unknown commit, or an unreachable GitHub all block.
- Give the person at the Kargo gate a short runbook with the rule for when to promote and the checks the machinery does not do.
- Land everything before the production deployment is enabled, so the first production promotion is gated.

**Non-Goals:**

- A runtime schema guard: an initContainer comparing the image's migration set with `schema_migrations`, with a warn mode, a RollingUpdate strategy and a version manifest in the image. Considered alongside the gate and not adopted. It returns as a follow-up only if one of the accepted gaps bites.
- Protecting staging and test, which share databases with legacy staging and test and run ahead of them today.
- Automating the promotion decision itself (release-driven retagging, a `production` Warehouse, Kargo auto-promotion). That is step two, built on top of this gate.
- Narrowing who may promote (Kargo RBAC). Separate decision.
- Applying the commit gate to `staging` or `test`. For staging it is trivially true. For test it would fail every auto-promotion until the next DTT (the legacy "deploy to test"). Making k8s test track the legacy `test` branch by selecting Freight on each DTT is a possible follow-up, not part of this change.
- Admission-time enforcement or image signing.
- Shipping migrations in the image or letting the image run `db:migrate`.

## Decisions

### 1. One gate, at the Kargo step, with its gaps named

The commit gate catches the mistake at the moment a person presses the button, before any write to k8s-gitops, with a failure message naming the rule that broke. It runs once, on the Kargo path, against the `production` branch. Four things are outside it, each with a stand-in:

- **The one-to-two-minute window between a DTP merge and `db:migrate` finishing.** The runbook's rule is to promote only after the GitHub release for that DTP exists. `publish_github_release` creates that release after the migration, the fleet replacement and the CDN flush. Step two removes the person from this path altogether.
- **A digest that reaches the production values file without Kargo.** That is a reviewed commit. The runbook says the Kargo gate is the only sanctioned path.
- **A legacy migration rollback after promotion.** Nothing in k8s notices. The runbook has the operator re-promote the Freight whose commit matches the rolled-back branch. Legacy rarely rolls migrations back.
- **Staging and test.** Unchanged, as they are today.

Alternatives considered:

- **A pod self-gate**: an initContainer in the chart comparing the image's migration set with `schema_migrations`. It would have closed all four gaps. The cost: a version manifest in the image, a check script, a chart refactor, a warn-to-enforce rollout per envType, and new `Init:Error` and Argo `Degraded` failure states to operate.
- **A PreSync hook Job in the chart**: the same check on every Argo sync.
- **An admission policy with cosign attestations**: the strongest option, but it needs a policy engine and a signing pipeline in CI.
- **A Kargo `verification` on `test`**: runs at the wrong moment, since the commit is not yet in production when it reaches `test`.
- **Building the image from the `production` branch**: matches legacy exactly, but the bytes would never have run in `test`.

### 2. Legacy marker: the `production` branch HEAD, read through the GitHub compare API

`GET /repos/code-dot-org/code-dot-org/compare/production...<sha>` answers the ancestry question directly. `ahead_by == 0` (status `behind` or `identical`) means every change in the image is already in the branch. `ahead` or `diverged` means it is not. An unknown or empty sha returns 404.

The branch moves on hotfixes too, which the release tag does not. The branch also moves one to two minutes before `db:migrate` finishes; the runbook's rule to promote only after the release exists covers that.

The call is unauthenticated for now: 60 requests per hour per source IP, far above promotion rates. If rate limiting ever appears, Kargo's `secret()` expression function can supply a token header from a generic credential Secret.

Kargo 1.12.5's `http` step has `successExpression`, `failureExpression` and, since 1.11, `errorExpression`. When the failure criterion is met, the error expression is evaluated against the same response and its string result is appended to the step's error. The Promotion reports it as `HTTP (<status>) response met failure criteria: "<text>"`. Outputs are produced on success alone.

The gate is therefore one step, `legacy-ancestry`:

- It succeeds on 200 with `ahead_by == 0`.
- It fails terminally on 404 or 422 (no annotation, or a sha GitHub does not know), with the message `no revision annotation, or GitHub does not know the commit (HTTP <status>)`.
- It fails terminally on 200 with `ahead_by > 0`, with the message `image commit is <n> commit(s) ahead of legacy production (<status>)`.
- A response matching neither expression (5xx, timeout) leaves the step running. Kargo re-polls at the step's `pollInterval` (default 30 seconds) until the step's five-minute retry timeout, then fails.

So the Promotion itself tells the operator which rule broke and by how much. One call per promotion stays far inside the unauthenticated limit.

Alternatives:

- **The latest GitHub release as the marker** (compare `<release tag>...<sha>`). It would close the migrate window mechanically, because the release is created after `db:migrate`. The cost is a second `http` step to look the release up and, until step two's `create-release --commit` fix lands, a release that can name an undeployed commit when two DTPs overlap. Kept as an open question.
- **The `cdo-build-logs` S3 metadata or EC2 `git-commit` tags.** Both need AWS credentials in the Kargo controller and a step that can sign AWS requests, which Kargo has no built-in step for.
- **The Slack topic.** Not machine-readable with any guarantee.

### 3. The commit travels as an OCI index annotation built with regctl

Kargo populates `imageFrom(...).Annotations` from the index annotations (then manifest and descriptor annotations, at lower precedence), never from image config labels. So the commit must be on the index.

`docker buildx imagetools create --annotation` silently drops annotations when the result is a Docker manifest list, which it is whenever every child is Docker-typed, as ours are. `regctl index create <ref> --ref <child>... --annotation k=v` always emits `application/vnd.oci.image.index.v1+json` and leaves the per-arch images, the bytes that ran in CI's smoke test, untouched.

The merge job therefore:

1. Installs regctl from a SHA-pinned `regclient/actions/regctl-installer`.
2. Builds the index once under the immutable `git-<sha>` tag.
3. Inspects it and fails the job unless the media type is OCI, the annotation equals `github.sha`, and both platform descriptors are present.
4. Only then copies the validated index to `latest` and any other tag in `$TAGS` with `regctl image copy`. The tag Kargo follows never points at an index that has not passed the check.

Fallbacks: if regctl does not derive the platform from a single-arch child, use the two-step form (`index create ... --desc-platform linux/amd64`, then `index add ... --desc-platform linux/arm64`). If that fails too, `skopeo copy --format oci` per leg plus buildx.

Alternatives: pushing the per-arch images as OCI manifests so buildx emits an OCI index (changes the tested bytes' media types and the Dockerfile build flags); a Kargo git subscription to `staging` alongside the image (Freight would carry a commit, but nothing ties it to the image digest in the same Freight).

### 4. Fail closed, with no bypass mode

Freight without an annotation produces a URL ending in `...`. GitHub returns 404 and `legacy-ancestry` fails with the no-revision message. A commit GitHub does not know returns 422 and fails the same way. A GitHub outage or rate limit leaves the step running until its five-minute timeout, then fails; the promotion can simply be retried.

There is no bypass mode. The only way past the gate is a reviewed commit that removes the step, which the runbook treats as an incident action to be reverted.

### 5. Manual promotion stays, nothing about "who" changes

`autoPromotionEnabled: false` for `production` and `levelbuilder` is untouched. The gate makes the manual decision safe; it does not replace it. Kargo RBAC narrowing remains available as a separate change.

### 6. Rehearsal on the production Stage, before its deployment exists

The k8s production deployment is disabled today: no workload in the `production` namespace, no `codeai-production` Application in Argo, and no Promotion in the Stage's history. Until it is enabled, a promotion to the production Stage can reach neither the pods nor the database. The step is therefore rehearsed where it lives, by promoting three Freight to `production` with the step in place:

- One unannotated: expect `legacy-ancestry` to fail with HTTP 404 and the no-revision message. Nothing is written, because the step runs before `git-clone`.
- The newest: expect it to fail with HTTP 200 and the ahead-by message, unless a DTP has just landed. Nothing is written.
- The one whose annotation equals `git merge-base production staging`: expect the step to pass. The later steps then commit that digest into the production values file on `main`, and the Promotion ends Failed at `argocd-update` because `codeai-production` does not exist yet. That is the expected end state. The commit is useful: when the deployment is enabled, Argo brings production up on a gate-approved image.

The three promotions happen in one sitting, before the deployment is enabled, and the three Promotion statuses are recorded in the runbook as reference signatures. `argocd-update` stays in the template, so the rehearsed template is the one that guards production; the runbook lists its "application not found" failure as expected only while the deployment is disabled.

This rehearsal is mandatory, not optional. The expressions are the part of the gate most likely to be wrong. A wrong expression could fail every promotion or pass every one, and no second check stands behind the gate.

Alternatives: the `levelbuilder` Stage, which tests the wrong marker (legacy levelbuilder is deployed from `test` by DTL and its database is migrated on that cadence) and would need a temporary copy of the step; a throwaway Stage, which needs cleanup and still is not the template that ships.

### 7. The gate is production-only

For staging the image commit is always the branch head or an ancestor. For test the newest Freight is always ahead of the `test` branch until the next DTT, so the step would fail every auto-promotion. Staging and test keep running ahead of their databases, as they do today.

## Risks / Trade-offs

- **A mixed-media index (OCI index wrapping Docker manifests) breaks some puller.** Verified by `docker pull` on both architectures and a staging pod pull after the first publish. Fallback is `skopeo copy --format oci` per leg so every child is OCI.
- **regctl does not derive platform descriptors from single-arch children.** The merge job inspects the pushed index and fails if a platform is missing. The two-step `--desc-platform` form is the documented fallback.
- **GitHub rate limit or outage during a promotion.** 5xx and timeouts retry for up to five minutes, then fail. The promotion can simply be retried. A token header via `secret()` is the next step if limits bite.
- **A promotion inside the window between a DTP merge and `db:migrate`.** Accepted. The runbook's rule is to promote only after the release for that DTP exists, and step two removes the person from this path. If the rule proves unreliable, the marker can become the latest release (decision 2) or the runtime guard can return.
- **Legacy rollback moves `production` HEAD backwards.** Running pods keep running. A re-promotion of an older Freight passes the gate. If a migration is rolled back legacy-side, nothing in k8s notices; the runbook has the operator re-promote the Freight whose commit matches the rolled-back branch. Accepted; rare.
- **An older Freight passes the gate but expects a table or column a later migration removed.** The gate certifies only that no prerequisite migration is missing, not that older code fits a newer schema. The runbook requires, before every rollback including to the previous Freight, a review of the migrations added between the two commits for `drop_table`, `remove_column` and renames. That is the same review a legacy code rollback needs. One release can carry a destructive migration, so no distance is exempt.
- **Hand-edited production `values.yaml` bypasses the gate.** Accepted. It is a reviewed commit, and the runbook says the Kargo gate is the only sanctioned path.
- **A default-deny NetworkPolicy added later.** Must allow the Kargo controller namespace to reach api.github.com on 443. Noted in the runbook.
- **The `http` step's failure text is limited to what `errorExpression` can compute from one response.** The message names the rule and the number of commits ahead. The runbook maps message and HTTP status to the cause and gives the compare URL to run by hand for anything more.
- **The gate's expressions are wrong.** A wrong expression could fail every promotion or pass every one, and no second check stands behind it. The rehearsal on the production Stage (decision 6) is mandatory for that reason, and the runbook records the three reference outcomes.
- **The rehearsal leaves Failed Promotions in the production Stage's history.** Two fail at the gate by design, and the passing one fails at `argocd-update` because the Application does not exist yet. Cosmetic. Kargo never auto-promotes Freight whose newest Promotion failed, which does not matter while promotion is manual, and step two's production Freight come from another Warehouse.
- **Someone enables the production deployment during the rehearsal.** The rehearsal would become a real promotion. The three promotions are done in one sitting, and the enablement change is sequenced after them (migration plan).

## Migration Plan

1. code-dot-org PR to `staging`: the regctl-built OCI index and the README tag contract. Merge. After the next `latest` publish, confirm the index media type, annotation and platforms, and confirm the newest Freight shows the annotation.
2. k8s-gitops on `INF-2281/promotion-gates`: the Kargo gate step in `stages/production.yaml`, `docs/production-promotion.md`, and the Kargo project README. Argo applies the Stage change. Nothing deploys to production, because that workload is still disabled.
3. Rehearse the Kargo step on the production Stage while its deployment is still disabled (decision 6): three promotions in one sitting, the three outcomes recorded in the runbook. The passing one leaves the gate-approved digest in the production values file.
4. The production deployment is enabled by its own change, which also sets `branch: production`. Argo creates `codeai-production` on the digest the rehearsal left in the values file. The first promotion follows the runbook: wait for the release of the DTP that carried the Freight's commit, promote, and check the pods.

Rollback: remove the gate step, and the Kargo path returns to today's behaviour. Nothing here touches the database, the chart or the legacy fleet. Rolling the promoted image back to an older Freight is a runbook procedure, subject to the destructive-migration review every time.

## Open Questions

- Whether to authenticate the GitHub compare call from day one, or wait for evidence of rate limiting.
- Whether the change that enables the production deployment will set `branch: production`, as this design assumes. Confirm before the first production promotion.
- Whether regctl derives platform descriptors from single-arch children. Resolved by the merge job's own inspect check on the first run.
- Whether the legacy marker should become the latest GitHub release rather than the `production` branch HEAD. That would close the migrate window mechanically, at the cost of a second `http` step and, until step two's `create-release --commit` fix lands, a release that can name an undeployed commit when two DTPs overlap.
