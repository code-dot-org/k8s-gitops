## Context

Kargo is 1.12.5 with its admission webhooks enabled. The `codeai` Kargo project has four Stages fed by one Warehouse that follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest. `production` requests Freight from `test` and has `autoPromotionEnabled: false`. The production Argo Application exists but its workload is disabled; enabling it is a separate change. The disabled deployment file currently sets `branch: staging` behind a FIXME comment; this design assumes the enabling change sets `branch: production`, so the chart deployed to production comes from the same commit lineage as the promoted image. Legacy production is an EC2 fleet deployed by DTP: `bin/dotd` merges a candidate into the `production` branch, each production daemon polls that branch every minute, `db:migrate` runs within one to two minutes of the merge, the CloudFormation rolling AMI replacement takes about 45 minutes, and `publish_github_release` tags a release at the end (never for hotfixes, which are direct non-merge pushes).

The image side: CI builds `cdo-rails` only on pushes to `staging`, tags `git-<sha>` and `latest`, and merges the two per-arch images into a Docker manifest list with `docker buildx imagetools create`. That list carries no annotations, so Kargo Freight knows a digest and nothing else. The same workflow also runs after each weekly `cdo-deps` publish and on manual dispatch, both on the default branch, and republishes `git-<sha>` and `latest` with new bytes, so `git-<sha>` is not immutable despite the README's promise; only a digest is. The image contains `dashboard/db/schema.rb` and `schema_cache.yml` but not `dashboard/db/migrate`, so it cannot migrate; Rails itself only warns at boot when the database's schema version differs from the image's. The Kargo controller reaches api.github.com through NAT, and there are no NetworkPolicies yet.

The k8s `staging` and `test` namespaces share databases with legacy staging and test and run images built from `staging` pushes, so they already run ahead of their databases for minutes (staging) or hours (test) after a migration lands. That is out of scope here and recorded as an accepted risk.

The options analysis that led here (nine candidate gates, their coverage and cost) lives in `PRODUCTION-PROMOTION-GATES.md` at the repo root. The user chose gates 7 (pod self-gate) and 3 (Kargo http guard) on 2026-10-28, then on 2026-11-03 dropped gate 7 as more than the problem needs, keeping gate 3 with the `production` branch HEAD as the legacy marker.

## Goals / Non-Goals

**Goals:**

- Make it impossible, through Kargo, to promote Freight to `production` whose commit is not contained in the legacy `production` branch.
- Keep the gate fail-closed: no commit annotation, an unknown commit, or an unreachable GitHub all block.
- Give the human at the Kargo gate a short runbook with the rule for when to promote and the checks the machinery does not do.
- Land everything before the production deployment is enabled, so the first production promotion is gated.

**Non-Goals:**

- A runtime schema guard (an initContainer comparing the image's migration set with `schema_migrations`, with a warn mode, a RollingUpdate strategy and a version manifest in the image). Designed, then dropped on 2026-11-03; it returns as a follow-up only if one of the accepted gaps bites.
- Protecting staging and test, which share databases with legacy staging and test and run ahead of them today.
- Automating the promotion decision itself (release-driven retagging, a `production` Warehouse, Kargo auto-promotion). Possible later on top of this gate.
- Narrowing who may promote (Kargo RBAC). Separate decision.
- Applying the commit gate to `staging` or `test`. For staging it is trivially true; for test it would fail every auto-promotion until the next DTT. Making k8s test track the legacy `test` branch by selecting Freight on each DTT is a possible follow-up, not part of this change.
- Admission-time enforcement or image signing.
- Shipping migrations in the image or letting the image run `db:migrate`.

## Decisions

### 1. One gate, at the Kargo step, with its gaps named

The commit gate catches the mistake at the moment a human presses the button, before any write to k8s-gitops, with a failure message naming the rule that broke. It runs once, on the Kargo path, against the `production` branch, so four things are outside it, each with a stand-in:

- The one-to-two-minute window between a DTP merge and `db:migrate` finishing: the runbook's rule is to promote only after the GitHub release for that DTP exists, which `publish_github_release` creates after the migration, the fleet replacement and the CDN flush. The automation change removes the human from this path altogether.
- A digest that reaches the production values file without Kargo: a reviewed commit; the runbook says the Kargo gate is the only sanctioned path.
- A legacy migration rollback after promotion: nothing in k8s notices; the runbook has the operator re-promote the Freight whose commit matches the rolled-back branch. Legacy rarely rolls migrations back.
- Staging and test: unchanged, as they are today.

Alternatives considered: a pod self-gate (gate 7), an initContainer in the chart comparing the image's migration set with `schema_migrations`, which would have closed all four gaps at the cost of a version manifest in the image, a check script, a chart refactor, a warn-to-enforce rollout per envType, and new `Init:Error` and Argo `Degraded` failure states to operate; a PreSync hook Job in the chart (gate 6), the same check on every Argo sync; an admission policy with cosign attestations (gate 8), the strongest but needing a policy engine and a signing pipeline in CI; a Kargo `verification` on `test` (gate 5), which runs at the wrong moment, since the commit is not yet in production when it reaches `test`; building the image from the `production` branch (gate 9), which matches legacy exactly but whose bytes would never have run in `test`.

### 2. Legacy marker: the `production` branch HEAD, read through the GitHub compare API

`GET /repos/code-dot-org/code-dot-org/compare/production...<sha>` answers the ancestry question directly: `ahead_by == 0` (status `behind` or `identical`) means every change in the image is already in the branch; `ahead` or `diverged` means it is not; an unknown or empty sha returns 404. The branch moves on hotfixes too, which the release tag does not, and the branch moves one to two minutes before `db:migrate` finishes, which the runbook's rule to promote only after the release exists covers. The call is unauthenticated for now (60 requests per hour per source IP, far above promotion rates); if rate limiting ever appears, Kargo's `secret()` expression function can supply a token header from a generic credential Secret.

Kargo 1.12.5's `http` step has `successExpression`, `failureExpression` and, since 1.11, `errorExpression`: when the failure criterion is met, the error expression is evaluated against the same response and its string result is appended to the step's error, which the Promotion reports as `HTTP (<status>) response met failure criteria: "<text>"`. Outputs are produced on success alone. The gate is therefore one step, `legacy-ancestry`. It succeeds on 200 with `ahead_by == 0`. It fails terminally on 404 or 422 (no annotation, or a sha GitHub does not know) and on 200 with `ahead_by > 0`. Its error expression renders `no revision annotation, or GitHub does not know the commit (HTTP <status>)` for the first case and `image commit is <n> commit(s) ahead of legacy production (<status>)` for the second, so the Promotion itself tells the operator which rule broke and by how much. A response that matches neither expression (5xx, timeout) leaves the step running; Kargo re-polls at the step's `pollInterval` (default 30 seconds) until the step's five-minute retry timeout, then fails. One call per promotion stays far inside the unauthenticated limit.

Alternatives: the latest GitHub release as the marker (compare `<release tag>...<sha>`), which would close the migrate window mechanically because the release is created after `db:migrate`, at the cost of a second `http` step to look the release up and, until the automation change's `create-release --commit` fix lands, a release that can name an undeployed commit when two DTPs overlap; kept as an open question. The `cdo-build-logs` S3 metadata or EC2 `git-commit` tags (both need AWS credentials in the Kargo controller and a step that can sign AWS requests, which Kargo has no built-in step for); a Slack topic (not machine-readable with any guarantee).

### 3. The commit travels as an OCI index annotation built with regctl

Kargo populates `imageFrom(...).Annotations` from the index annotations (then manifest and descriptor annotations, at lower precedence), never from image config labels, so the commit must be on the index. `docker buildx imagetools create --annotation` silently drops annotations when the result is a Docker manifest list, which it is whenever every child is Docker-typed, as ours are. `regctl index create <ref> --ref <child>... --annotation k=v` always emits `application/vnd.oci.image.index.v1+json` and leaves the per-arch images (the bytes that ran in CI's smoke test) untouched. The merge job installs regctl from a SHA-pinned `regclient/actions/regctl-installer`, builds the index once under the immutable `git-<sha>` tag, inspects it, and fails the job unless the media type is OCI, the annotation equals `github.sha`, and both platform descriptors are present. Only then does it copy that validated index to `latest` and any other tag in `$TAGS` with `regctl image copy`, so the tag Kargo follows never points at an index that has not passed the check. If regctl does not derive the platform from a single-arch child, the two-step form (`index create ... --desc-platform linux/amd64`, then `index add ... --desc-platform linux/arm64`) is the fallback; `skopeo copy --format oci` per leg plus buildx is the fallback to that.

Alternatives: pushing the per-arch images as OCI manifests so buildx emits an OCI index (changes the tested bytes' media types and the Dockerfile build flags); a Kargo git subscription to `staging` alongside the image (Freight would carry a commit, but nothing ties it to the image digest in the same Freight).

### 4. Fail closed, with no bypass mode

Freight without an annotation produces a URL ending in `...`, GitHub returns 404, and `legacy-ancestry` fails with the no-revision message. A commit GitHub does not know returns 422 and fails the same way. A GitHub outage or rate limit leaves the step running until its five-minute timeout, then fails; the promotion can simply be retried. There is no bypass mode: the only way past the gate is a reviewed commit that removes the step, which the runbook treats as an incident action to be reverted.

### 5. Manual promotion stays, nothing about "who" changes

`autoPromotionEnabled: false` for `production` and `levelbuilder` is untouched. The gate makes the manual decision safe; it does not replace it. Kargo RBAC narrowing remains available as a separate change.

### 6. Rehearsal without touching production

The Kargo step is rehearsed, before the production deployment is enabled, on the `levelbuilder` Stage by adding it there temporarily and promoting three Freight: one unannotated (expect `legacy-ancestry` to fail with HTTP 404 and the no-revision message), the newest (expect it to fail with HTTP 200 and the ahead-by message, unless a DTP has just landed), and the one whose annotation equals `git merge-base production staging` (expect the step to pass; later steps may fail on the missing levelbuilder Application, which is fine). This rehearsal is mandatory, not optional: the expressions are the part of the gate most likely to be wrong, a wrong expression could fail every promotion or pass every one, and no second check stands behind the gate.

### 7. The gate is production-only

For staging the image commit is always the branch head or an ancestor, and for test the newest Freight is always ahead of the `test` branch until the next DTT, so the step would fail every auto-promotion. Staging and test keep running ahead of their databases, as they do today.

## Risks / Trade-offs

- [A mixed-media index (OCI index wrapping Docker manifests) breaks some puller] → Verified by `docker pull` on both architectures and a staging pod pull after the first publish; fallback is `skopeo copy --format oci` per leg so every child is OCI.
- [regctl does not derive platform descriptors from single-arch children] → The merge job inspects the pushed index and fails if a platform is missing; the two-step `--desc-platform` form is the documented fallback.
- [GitHub rate limit or outage during a promotion] → 5xx and timeouts retry for up to five minutes then fail; the promotion can simply be retried; a token header via `secret()` is the next step if limits bite.
- [A promotion inside the window between a DTP merge and `db:migrate`] → Accepted. The runbook's rule is to promote only after the release for that DTP exists; the automation change removes the human from this path. If the rule proves unreliable, the marker can become the latest release (decision 2) or the runtime guard can return.
- [Legacy rollback moves `production` HEAD backwards] → Running pods keep running. A re-promotion of an older Freight passes the gate. If a migration is rolled back legacy-side, nothing in k8s notices; the runbook has the operator re-promote the Freight whose commit matches the rolled-back branch. Accepted; rare.
- [An older Freight passes the gate but expects a table or column a later migration removed] → The gate certifies only that no prerequisite migration is missing, not that older code fits a newer schema. The runbook requires, before every rollback including to the previous Freight, a review of the migrations added between the two commits for `drop_table`, `remove_column` and renames, the same review a legacy code rollback needs; one release can carry a destructive migration, so no distance is exempt.
- [Hand-edited production `values.yaml` bypasses the gate] → Accepted. It is a reviewed commit; the runbook says the Kargo gate is the only sanctioned path.
- [A default-deny NetworkPolicy added later] → Must allow the Kargo controller namespace to reach api.github.com on 443; noted in the runbook.
- [The `http` step's failure text is limited to what `errorExpression` can compute from one response] → The message names the rule and the number of commits ahead; the runbook maps message and HTTP status to the cause and gives the compare URL to run by hand for anything more.
- [The gate's expressions are wrong] → A wrong expression could fail every promotion or pass every one, and no second check stands behind it; the levelbuilder rehearsal (decision 6) is mandatory for that reason, and the runbook records the three reference outcomes.

## Migration Plan

1. code-dot-org PR to `staging`: the regctl-built OCI index and the README tag contract. Merge; after the next `latest` publish confirm the index media type, annotation and platforms, and confirm the newest Freight shows the annotation.
2. k8s-gitops on `INF-2281/promotion-gates`: the Kargo gate step in `stages/production.yaml`, `docs/production-promotion.md`, Kargo project README. Argo applies the Stage change; nothing deploys to production because that workload is still disabled.
3. Rehearse the Kargo step on `levelbuilder` (decision 6) and record the three outcomes in the runbook.
4. The production deployment is enabled by its own change, which also sets `branch: production`. The first promotion follows the runbook: wait for the release of the DTP that carried the Freight's commit, promote, and check the pods.

Rollback: remove the gate step (the Kargo path returns to today's behaviour). Nothing here touches the database, the chart or the legacy fleet. Rolling the promoted image back to an older Freight is a runbook procedure, subject to the destructive-migration review every time.

## Open Questions

- Whether to authenticate the GitHub compare call from day one, or wait for evidence of rate limiting.
- Whether the change that enables the production deployment will set `branch: production`, as this design assumes; confirm before the first production promotion.
- Whether regctl derives platform descriptors from single-arch children; resolved by the merge job's own inspect check on the first run.
- Whether the legacy marker should become the latest GitHub release rather than the `production` branch HEAD, which would close the migrate window mechanically at the cost of a second `http` step and, until the automation change's `create-release --commit` fix lands, a release that can name an undeployed commit when two DTPs overlap.
