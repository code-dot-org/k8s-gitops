# Promoting cdo-rails to production

This doc covers how to promote `cdo-rails` Freight to the k8s `production` namespace
with Kargo, what to do when it fails, how to handle rollbacks, and more.
Kargo is at https://kargo.k8s.code.org, project `kargo-project-codeai`, Stage
`production`. Argo is at https://argocd.k8s.code.org, Application
`codeai-production`.

Promotion to production is a manual decision. Nothing promotes to `production`
until a person creates a Promotion, and the Kargo path is the only sanctioned
way to change the production image.

Two read-only scripts in this repository do the lookups. Both need `gh`, logged
in. The first also needs `kubectl` with read access to the cluster, and `jq`.

- `bin/production-freight`: which Freight can be promoted right now, or why
  none can.
- `bin/rollback-review <revision>`: which migrations a rollback to that
  revision would run against.

## Promote

1. **Run the finder.**

   ```
   bin/production-freight
   ```

   It prints the latest legacy release, the current legacy `production` HEAD,
   the staging commit legacy production runs (the merge base of `production`
   and `staging`), every Freight that carries a revision annotation, and a
   verdict on the last line.

   This example was taken while a DTP was in progress, before CI stamped any image:

   ```
   Latest legacy release:   v2026-11-09.1 published 2026-11-10T02:00:28Z
   Legacy production HEAD:  791afcdc98c90b72e6ff67acb20ca38c4d4b64d0 committed 2026-11-10T21:09:26Z
   Staging commit it runs:  bb4653156e595eb29cd61cf705492afd09fdc1c2

   WAIT     a DTP merged after the latest release and its release is not out: db:migrate may still be running.
            Promote after that release exists.

   Freight with a revision annotation, newest last (246 Freight in kargo-project-codeai):
     none: no Freight carries org.opencontainers.image.revision yet

   NONE     no Freight carries bb4653156e595eb29cd61cf705492afd09fdc1c2.
            CI did not publish an image for that commit, or the Warehouse missed it.
            Wait for the next DTP. Promote an older Freight only after bin/rollback-review.
   ```

   This example was taken while a DTP was not in progress, before CI stamped any image:

   ```
   Latest legacy release:   v2026-11-12.0 published 2026-11-12T18:42:20Z
   Legacy production HEAD:  eca2c4e1af7510b9cf300c7249090c29e3b25718 committed 2026-11-12T17:40:18Z
   Staging commit it runs:  8a701b7aad71e0b33ed2ee85226adda1a93cd70c

   OK       the latest release covers production HEAD, so the legacy deploy is done.

   Freight with a revision annotation, newest last (249 Freight in kargo-project-codeai):
     none: no Freight carries org.opencontainers.image.revision yet

   NONE     no Freight carries 8a701b7aad71e0b33ed2ee85226adda1a93cd70c.
           CI did not publish an image for that commit, or the Warehouse missed it.
           Wait for the next DTP. Promote an older Freight only after bin/rollback-review.
   ```

2. **Act on the verdict.**

   | verdict                                       | meaning                                                                                                                                                                                                                                                                                | do                                                                                                  |
   | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
   | `PROMOTE`                                     | The Freight named carries the merge base, is verified in `test`, and the legacy deploy that put that commit on `production` has finished.                                                                                                                                              | Step 3.                                                                                             |
   | `WAIT`, a DTP merged after the latest release | The `production` branch moves one to two minutes before that deploy's `db:migrate` finishes, and the gate reads the branch. The release is created after the migration, the fleet replacement and the CDN flush, so until it exists a promotion could start a pod ahead of the schema. | Wait for the release, then run the finder again.                                                    |
   | `CHECK`, a hotfix moved production            | A direct push to `production` moved HEAD after the latest release, and hotfixes get no release.                                                                                                                                                                                        | Confirm in `#infra-production` that the hotfix deploy finished, then act on the rest of the output. |
   | `WAIT`, not yet verified in test              | Freight for the merge base exists, but `test` has not verified it. The Stage only accepts Freight verified there.                                                                                                                                                                      | Wait, then run the finder again.                                                                    |
   | `NONE`                                        | No Freight carries the merge base: CI did not publish an image for that commit, or the `latest` Warehouse missed it.                                                                                                                                                                   | Wait for the next DTP. Promoting an older Freight is a rollback; see [Roll back](#roll-back).       |
   | `DONE`                                        | The merge-base Freight is already in production.                                                                                                                                                                                                                                       | Nothing.                                                                                            |

3. **Promote in the Kargo UI.** Project `kargo-project-codeai`, Stage
   `production`, Promote, pick the alias the finder named. The Promotion's step
   list shows `legacy-ancestry` first; its output `status` is GitHub's word for
   the comparison, `behind` or `identical` on success. If a step fails, see
   [When it fails](#when-it-fails). TODO: Update this step with a screenshot of
   the Kargo Freight picker UI.

4. **Verify.**
   - The Promotion is Succeeded, and
     `apps/codeai/deployments/production/values.yaml` on `main` names the new
     digest.
   - Argo `codeai-production` is Synced and Healthy, with the new pods Running.
   - Whatever application-level signal exists at the time, such as a Honeybadger
     test exception raised from a production worker, or a canary job.

   An old worker pod stays until its current job finishes or its 35-minute
   grace period ends, so the rollout can take that long per worker pod. See
   [Rollout and rollback timing](#rollout-and-rollback-timing).

## Roll back

Rolling back is promoting an older Freight through Kargo. The gate passes for
any older commit, because it certifies only that no prerequisite migration is
missing. It does not certify that older code fits a newer schema. The schema is
whatever legacy production has deployed, which can be ahead of the Freight
being replaced, so the review below runs against the legacy `production`
branch, not against the Freight being replaced.

1. **Pick the target.** `bin/production-freight` lists every Freight with a
   revision, newest last. Note the full revision of the one to go back to.

2. **Review the migrations the database has that the target does not.**

   ```
   bin/rollback-review <revision>
   ```

   Example, for a revision two weeks behind production:

   ```
   Legacy production is 713 commits ahead of 18d5b1bd6649246d53611c25f52325d14142d39d.
   Migrations added between 18d5b1bd6649246d53611c25f52325d14142d39d and production:
     20261015120000_add_unique_index_on_key_to_practice_problems.rb
     20261026120000_create_objectives_script_levels.rb
     20261029140602_rename_ai_challenge_enabled_in_section.rb   <-- destructive operation
           3:    rename_column :sections, :ai_tutor_enabled, :ai_challenge_enabled
           https://github.com/code-dot-org/code-dot-org/blob/production/dashboard/db/migrate/20261029140602_rename_ai_challenge_enabled_in_section.rb
     20261104120000_add_keys_to_challenges.rb

   REVIEW   read each flagged line in context. A drop_table or remove_column inside a
            down method reverses that migration's own change and is not destructive.
            Anything in up or change is: the older image may fail against the schema.
   ```

   While a DTP is in progress the branch is ahead of the schema, so the list
   then includes migrations not yet applied, which errs on the safe side.

3. **Decide.** `OK` means no `drop_table`, `remove_column`, `rename_table` or
   `rename_column` was added in the range. `REVIEW` means at least one was:
   open each flagged file. A drop or remove inside a `down` method reverses
   that migration's own change and is harmless. One in `up` or `change` means
   the older image may fail against the current schema, exactly as a legacy
   code rollback to that commit would, and it is the same decision. One release
   can carry a destructive migration, so no distance is exempt.

4. **Promote the older Freight** as in [Promote](#promote) step 3, and allow
   for the worker drain: up to 35 minutes per worker pod.

## When it fails

Kargo shows the failed step's message on the Promotion. For `legacy-ancestry`
the message carries the HTTP status and one of two texts.

| what you see                                                                                                         | cause                                                                                                                                                                                                                                               | what to do                                                                                                                    |
| -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `legacy-ancestry` failed, HTTP 404 or 422, "no revision annotation, or GitHub does not know the commit"              | The Freight has no `org.opencontainers.image.revision` (built before CI stamped it), or the annotation names a commit GitHub does not have.                                                                                                         | Promote a Freight that carries a revision. `bin/production-freight` lists them.                                               |
| `legacy-ancestry` failed, HTTP 200, "image commit is N commit(s) ahead of legacy production (ahead)" or "(diverged)" | The image is newer than what legacy production runs.                                                                                                                                                                                                | Wait for the DTP that carries that commit and its release, then promote. Or promote the merge-base Freight the finder names.  |
| `legacy-ancestry` still Running for minutes, then failed with a timeout                                              | GitHub returned 5xx, rate-limited the call, timed out or was unreachable. Kargo retries until the step's 5 minute timeout. The step's `errorThreshold` of 20 is what lets request errors retry at all; Kargo's default of 1 stops at the first one. | Retry the promotion. If it repeats, run the compare by hand (below) and check GitHub's status page.                           |
| `argocd-update` failed, application `codeai-production` not found                                                    | The production deployment is still disabled, so the Argo Application does not exist. Expected only in that state, and how the gate rehearsal's passing case ends. The values file was already updated.                                              | Nothing, while the deployment is disabled. After it is enabled this signature means the Application was deleted; investigate. |

The full comparison, by hand:

```
gh api repos/code-dot-org/code-dot-org/compare/production...<revision> --jq '.status, .ahead_by, .behind_by'
```

or in a browser, `https://github.com/code-dot-org/code-dot-org/compare/production...<revision>`.

### Reference statuses from the rehearsal

Recorded during the rehearsal on the production Stage before its deployment was
enabled (one sitting, three promotions). Fill in the Promotion names and the
exact messages so a live failure can be matched against a known one.

| case                   | Freight | Promotion | outcome                                                                                                      |
| ---------------------- | ------- | --------- | ------------------------------------------------------------------------------------------------------------ |
| no revision annotation |         |           | expected: failed at `legacy-ancestry`, HTTP 404, no-revision text, no commit on `main`                       |
| newest Freight         |         |           | expected: failed at `legacy-ancestry`, HTTP 200, ahead-by text, no commit on `main`                          |
| merge-base Freight     |         |           | expected: `legacy-ancestry` passed, values file committed, failed at `argocd-update` (application not found) |

## Background

### The rule, and the gate that enforces it

The image promoted to `production` must be built from a commit that legacy
production already runs: a `staging` commit that is an ancestor of, or equal
to, the legacy `production` branch HEAD.

Why: the `cdo-rails` image carries no migrations. Schema changes reach the
production database only through the legacy EC2 deploy (DTP, "deploy to
production"). A k8s worker running code newer than that schema fails jobs in
confusing ways. Running behind is safe with respect to that hazard, with the
caveat covered under [Roll back](#roll-back).

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

### Why the finder waits for the release

The gate reads the `production` branch, and the branch moves one to two
minutes before that deploy's `db:migrate` finishes. The release is created by
`publish_github_release` after the migration, the fleet replacement and the
CDN flush, so its existence means the deploy is done. The finder compares the
latest release's publish time with the time of the `production` HEAD commit.

Until the legacy `create-release --commit` change lands, the release's
`target_commitish` names the branch tip at release time, not necessarily the
deployed revision. If two DTPs overlapped, wait for the second one's release
too.

### Hotfixes

A hotfix is a direct, non-merge push to `production`. It moves the branch, so
the gate sees it, but legacy publishes no release for it. The finder reports
it as `CHECK`: confirm in `#infra-production` that the hotfix deploy finished
before promoting a Freight that depends on it. Usually nothing needs doing: a
hotfix rarely changes which staging commit is the merge base.

### Rollout and rollback timing

The production envType sets the worker's `terminationGracePeriodSeconds` to
2100 (35 minutes), to cover the 30 minute `AnonymousGeoBackfillingJob` cap. An
old worker pod stays until its current job finishes or that period ends, so a
rollout or a rollback can take up to 35 minutes per worker pod. An idle worker
exits in seconds. Web pods use the chart default.

### What the gate does not cover

Accepted gaps, each with what stands in for it:

- **The window between a DTP merge and `db:migrate`.** The branch moves one to
  two minutes before the migration finishes. Covered by the finder's release
  check.
- **A legacy migration rollback after a promotion.** Nothing in k8s notices.
  If legacy rolls `production` back past a migration, re-promote the Freight
  whose commit is contained in the rolled-back branch, after
  `bin/rollback-review`.
- **Hand edits to `apps/codeai/deployments/production/values.yaml`.** They
  bypass the gate. That is a reviewed commit, and it is not a sanctioned path.
- **Staging and test.** Their k8s namespaces share databases with legacy
  staging and test and run ahead of them today. Out of scope.

### Network

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

| date | Freight | revision | digest | notes                                       |
| ---- | ------- | -------- | ------ | ------------------------------------------- |
|      |         |          |        | rehearsal: see the reference statuses above |
