# Promoting cdo-rails to production

How a person promotes `cdo-rails` Freight to the k8s `production` namespace with
Kargo, and what to do when it fails. Kargo is at https://kargo.k8s.code.org,
project `kargo-project-codeai`, Stage `production`. Argo is at
https://argocd.k8s.code.org, Application `codeai-production`.

Promotion to production is a manual decision. Nothing promotes to `production`
until a person creates a Promotion, and the Kargo path is the only sanctioned
way to change the production image.

## The rule, and the gate that enforces it

The image promoted to `production` must be built from a commit that legacy
production already runs: a `staging` commit that is an ancestor of, or equal
to, the legacy `production` branch HEAD.

Why: the `cdo-rails` image carries no migrations. Schema changes reach the
production database only through the legacy EC2 deploy (DTP, "deploy to
production"). A k8s worker running code newer than that schema fails jobs in
confusing ways. Running behind is safe with respect to that hazard, with one
caveat covered under [Rolling back](#rolling-back).

The production Stage's first promotion step, `legacy-ancestry`
(`apps/kargo/projects/codeai/stages/production.yaml`), enforces the rule. It
calls

```
GET https://api.github.com/repos/code-dot-org/code-dot-org/compare/production...<revision>
```

where `<revision>` is the Freight's image annotation
`org.opencontainers.image.revision`, the commit CI built the image from. The
step passes only on HTTP 200 with `ahead_by` 0, and it runs before anything is
cloned or written, so a blocked promotion changes nothing. There is no bypass.
Removing the step is an incident action, done by a reviewed commit and reverted
afterwards.

## When to promote

Promote only after the GitHub release for the DTP that carried the Freight's
commit exists. The `production` branch moves one to two minutes before that
deploy's `db:migrate` finishes, and the gate reads the branch, so a promotion
inside that window passes the gate and starts a pod ahead of the schema. The
release is created after the migration, the fleet replacement and the CDN
flush, so its existence means the deploy is done.

```
gh api repos/code-dot-org/code-dot-org/releases/latest --jq '.tag_name, .target_commitish, .published_at'
```

Until the legacy `create-release --commit` change lands, `target_commitish`
names the branch tip at release time, not necessarily the deployed revision. If
two DTPs overlapped, wait for the second one's release too.

## Finding the Freight to promote

1. The staging commit legacy production contains is the merge base of the two
   branches:

   ```
   git fetch origin production staging
   git merge-base origin/production origin/staging
   ```

2. Find the Freight whose revision annotation equals that commit. Read-only:

   ```
   kubectl get freight -n kargo-project-codeai --sort-by=.metadata.creationTimestamp \
     -o 'custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,DIGEST:.images[0].digest,REVISION:.images[0].annotations.org\.opencontainers\.image\.revision'
   ```

   A Freight without a revision was built before CI stamped the annotation. It
   cannot be promoted to production.

3. The Freight must show as verified in `test` (the Stage requests Freight from
   `test`). Kargo's UI lists only eligible Freight when you promote.

If no Freight matches the merge base, CI did not publish an image for that
commit, or the `latest` Warehouse missed it. Do not promote an older Freight
without the review under [Rolling back](#rolling-back); otherwise wait for the
next DTP.

## Promoting

Before:

- The release for the DTP exists (above).
- The Freight's revision equals the merge base (above).
- No legacy deploy is in progress (the `#infra-production` DTP status).

Then, in the Kargo UI: project `kargo-project-codeai`, Stage `production`,
Promote, pick the Freight. The Promotion's step list shows `legacy-ancestry`
first; its output `status` is GitHub's word for the comparison (`behind` or
`identical` on success).

After:

- The Promotion is Succeeded, and `apps/codeai/deployments/production/values.yaml`
  on `main` names the digest.
- Argo `codeai-production` is Synced and Healthy.
- Pods are `Running`: `kubectl get pods -n production` (read-only).
- Whatever application-level signal exists at the time, such as a Honeybadger
  test exception raised from a production worker, or a canary job.

## Rollout and rollback timing

The production envType sets the worker's `terminationGracePeriodSeconds` to
2100 (35 minutes), to cover the 30 minute `AnonymousGeoBackfillingJob` cap. An
old worker pod stays until its current job finishes or that period ends, so a
rollout or a rollback can take up to 35 minutes per worker pod. An idle worker
exits in seconds. Web pods use the chart default.

## Rolling back

Rolling back is promoting an older production Freight through Kargo. The gate
passes for any older commit, because it certifies only that no prerequisite
migration is missing. It does not certify that older code fits a newer schema.

Before every rollback, including to the previous Freight, list the migrations
added between the two commits and review them for `drop_table`,
`remove_column`, `rename_table` and `rename_column`:

```
git log --oneline <old revision>..<new revision> -- dashboard/db/migrate
git diff <old revision>..<new revision> -- dashboard/db/migrate | grep -E 'drop_table|remove_column|rename_(table|column)'
```

One release can carry a destructive migration, so no distance is exempt. If a
destructive migration is in the range, the older image may fail against the
current schema, exactly as a legacy code rollback would. That is the same
review a legacy rollback needs.

Then promote the older Freight from the Kargo UI and allow for the worker
drain above.

## Failure signatures

Kargo shows a failed step's message on the Promotion. For `legacy-ancestry` the
message carries the HTTP status and one of two texts.

| what you see | cause | what to do |
|---|---|---|
| `legacy-ancestry` failed, HTTP 404 or 422, "no revision annotation, or GitHub does not know the commit" | The Freight has no `org.opencontainers.image.revision` (built before CI stamped it), or the annotation names a commit GitHub does not have. | Promote a Freight that carries a revision. Check with the `kubectl get freight` command above. |
| `legacy-ancestry` failed, HTTP 200, "image commit is N commit(s) ahead of legacy production (ahead)" or "(diverged)" | The image is newer than what legacy production runs. | Wait for the DTP that carries that commit and its release, then promote. Or promote the merge-base Freight. |
| `legacy-ancestry` still Running for minutes, then failed with a timeout | GitHub returned 5xx, rate-limited the call, or was unreachable. The step re-polls until its 5 minute timeout. | Retry the promotion. If it repeats, run the compare URL by hand (below) and check GitHub's status page. |
| `argocd-update` failed, application `codeai-production` not found | The production deployment is still disabled, so the Argo Application does not exist. Expected only in that state, and how the gate rehearsal's passing case ends. The values file was already updated. | Nothing, while the deployment is disabled. After it is enabled this signature means the Application was deleted; investigate. |

The full comparison, by hand:

```
gh api repos/code-dot-org/code-dot-org/compare/production...<revision> --jq '.status, .ahead_by, .behind_by'
```

or in a browser, `https://github.com/code-dot-org/code-dot-org/compare/production...<revision>`.

### Reference statuses from the rehearsal

Recorded during the rehearsal on the production Stage before its deployment was
enabled (one sitting, three promotions). Fill in the Promotion names and the
exact messages so a live failure can be matched against a known one.

| case | Freight | Promotion | outcome |
|---|---|---|---|
| no revision annotation | | | expected: failed at `legacy-ancestry`, HTTP 404, no-revision text, no commit on `main` |
| newest Freight | | | expected: failed at `legacy-ancestry`, HTTP 200, ahead-by text, no commit on `main` |
| merge-base Freight | | | expected: `legacy-ancestry` passed, values file committed, failed at `argocd-update` (application not found) |

## Hotfixes

A hotfix is a direct, non-merge push to `production`. It moves the branch, so
the gate sees it, but legacy publishes no release for it. The rule above still
holds: wait until the legacy deploy for the hotfix has finished (the
`#infra-production` DTP status) before promoting a Freight that depends on it.
Usually nothing needs doing: a hotfix rarely changes which staging commit is
the merge base.

## What the gate does not cover

Accepted gaps, each with what stands in for it:

- **The window between a DTP merge and `db:migrate`.** The branch moves one to
  two minutes before the migration finishes. Covered by the rule to promote
  only after the release exists.
- **A legacy migration rollback after a promotion.** Nothing in k8s notices.
  If legacy rolls `production` back past a migration, re-promote the Freight
  whose commit is contained in the rolled-back branch, after the destructive
  migration review above.
- **Hand edits to `apps/codeai/deployments/production/values.yaml`.** They
  bypass the gate. That is a reviewed commit, and it is not a sanctioned path.
- **Staging and test.** Their k8s namespaces share databases with legacy
  staging and test and run ahead of them today. Out of scope.

## Network

The gate runs in the Kargo controller (namespace `kargo`) and reaches
`api.github.com` on port 443 through the VPC NAT gateway, unauthenticated, one
call per promotion. There are no NetworkPolicies in the cluster today, and the
EKS Auto Mode NodeClasses are set to `networkPolicy: DefaultAllow`. Any future
default-deny policy, or a switch of that NodeClass setting to `DefaultDeny`,
must keep egress for the Kargo controller to `api.github.com:443` (this gate),
`github.com:443` (the git steps), `ghcr.io:443` (Warehouse discovery), DNS, the
Kubernetes API and the Argo CD API (`argocd-update`).

Because the call is unauthenticated, GitHub's limit of 60 requests per hour
applies per source IP, which is the NAT address every pod shares. If the gate
starts failing with HTTP 403 or 429, add a token header from a credential
Secret with Kargo's `secret()` expression function.

## History

| date | Freight | revision | digest | notes |
|---|---|---|---|---|
| | | | | rehearsal: see the reference statuses above |
