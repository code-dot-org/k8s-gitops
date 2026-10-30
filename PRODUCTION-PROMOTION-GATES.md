# Gating production promotion so k8s Freight is never ahead of legacy production

## Context

Task F1 (PRODUCTION-READINESS-JIRA.md, "Write the production promotion checklist") exists
because of rule 3.9 in PRODUCTION-READINESS.md: the `cdo-rails` image carries no migrations,
schema changes reach the production database only through the legacy EC2 deploy, and a k8s
worker running code newer than that schema fails jobs confusingly. Running behind is safe.

Today the only control is a human at the Kargo gate (`autoPromotionEnabled: false` for
`production` in `apps/kargo/projects/codeai/project-config.yaml`). The first pass in this
session looked at automating the promotion off the GitHub release. This pass broadens the
question: what are the ways, manual or automatic, to guarantee the Freight promoted into the
`production` namespace was built from a commit at or behind what the production EC2 fleet
runs, and which one should we adopt.

### Facts established so far (verified against source and live state on 2026-10-26)

- Images are built only on pushes to `staging` (`.github/workflows/cdo-rails-image.yml`),
  tagged `git-<sha>` and `latest`. The index is a Docker manifest list with no OCI annotations,
  so a Freight carries only `tag: latest` and a digest, never a commit.
- The Warehouse (`apps/kargo/projects/codeai/warehouse.yaml`) follows `latest` by digest. All
  four Stages share it; `production` requests Freight from `test`.
- Legacy DTP: `bin/dotd` `do_dtp` merges a `dtp_candidate_<sha>` PR into `production`; the
  production hosts then run the deploy; `lib/rake/infra.rake` `publish_github_release` runs
  `bin/create-release --force` as the last task of `infra:all` for production. The release tag
  (e.g. `v2026-10-23.0`) therefore marks "legacy production finished deploying this commit".
  `create-release` skips when production HEAD is not a merge (hotfixes get no release).
- The staging commit whose image matches a release is `git merge-base <tag> origin/staging`
  (equal to `<tag>^2^2` for the latest release). That image exists (`git-fe90f17b…`,
  digest `sha256:2d9298d4…`) and Kargo already holds Freight `62af0e5b…` for it, verified in
  staging and test. Kargo staging/test were five commits ahead of production that day.
- Kargo 1.9.5 facts: GitHub receiver refreshes on `push` (any ref, tags included) and
  `package` events; the org webhook already sends both. Git subscriptions support
  `Lexical`/`NewestTag` with `allowTagsRegexes`. `Image` has an `Annotations` map. Built-in
  steps include `http` (success/failure expressions, terminal failure stops the promotion) but
  no exec/Job step. Creating a `Promotion` requires RBAC verb `promote` on the named `stages`
  resource in the project namespace (SubjectAccessReview in the admission webhook), so any
  Kubernetes identity can be granted it. `kargo login --kubeconfig` also works for machines.
- No GitHub OIDC provider or Actions access entry exists in tofu; no Kyverno, Gatekeeper,
  Argo Rollouts or Argo Events under `apps/`.
- Repo facts from exploration (2026-10-28):
  - No NetworkPolicy exists anywhere; pods carry the legacy frontend security group and egress
    via NAT, so an in-cluster guard can reach api.github.com, ghcr.io and the production DB.
    Readiness 4.4 plans default-deny later with 443-to-internet and 3306-to-DB allows.
  - `apps/infra/standard-envtypes/chart/templates/_envtype.tpl` already renders the
    `production` Namespace, ServiceAccount, SecretStore and ExternalSecret. Only the workload is
    off (`deployment.yaml.disabled`). A production-only Role/ConfigMap/CronJob fits there.
  - Closest hook-Job template to copy: `apps/infra/crossplane/chart/templates/postsync-health-hook.yaml`
    (ServiceAccount + RBAC + Job, `hook-delete-policy: BeforeHookCreation,HookSucceeded`).
  - Kargo RBAC: no project Roles exist; admins are the `engineers@` and `infrastructure@`
    OIDC groups (`apps/kargo/values.yaml`), so any engineer can promote today. No ServiceAccount
    has `promote`.
  - Backlog already contains D9 (cosign sign in CI, verify at admission for production) and
    readiness 6.4 (ValidatingAdmissionPolicy "digests required in production").
  - The `cdo-rails` image ships `dashboard/db/schema.rb` (version baked in, e.g.
    `define(version: 2026_10_09_170000)`) and `schema_cache.yml`, but not `db/migrate`. Rails'
    schema-cache initializer reads `ActiveRecord::Migrator.current_version` from the DB at boot
    and only warns on mismatch. `dashboard/bin/setup-db-minimal` already parses the schema.rb
    version and compares it to the DB, but it also runs `db:create`/`db:schema:load`, so a
    check-only variant is needed. The chart has a reusable one-shot Job template
    (`k8s/helm/templates/dashboard/dashboard-job.yaml`, gated by `dashboardJob.enabled`) and no
    initContainers or hook annotations today. DB credentials reach pods as `CDO_db_*` env from
    the `cdo-external-secrets` Secret.

### Legacy-side timing (from `aws/ci_build` and `lib/rake/infra.rake`)

Each production daemon polls the branch every minute (`cookbooks/cdo-apps/templates/default/crontab.erb:125`).
`infra:all` order: `build` (chef, then `db:setup_or_migrate` = `db:migrate`, `seed:default`,
worker restart, asset build), `deploy_multi` (console chef + CloudFormation rolling AMI
replacement, ~45 min), `flush_cloudfront_cache`, `publish_github_release`.

- **Schema reaches the DB ~1-2 minutes after merge**, before any frontend is upgraded.
- **Release tag is the "fleet finished" marker**, but hotfixes (direct pushes, non-merge HEAD)
  produce no release. Nothing requires a PR to `production`.
- Other markers: `#infra-production` Slack topic (`DTP Status: <sha8>`), `cdo-build-logs` S3
  object metadata (`commit`, `success`), EC2 instance tag `git-commit=<sha5>`, Honeybadger and
  Sentry deploy events. No HTTP endpoint exposes the running revision (`/health_check` only).
- **Ground truth for the schema**: `SELECT version FROM schema_migrations` on the production DB.

### The invariant, two ways to state it

- **Commit rule (3.9 as written):** image source commit `C_k` is an ancestor of the legacy
  production commit `C_ec2`. Needs `C_k` (not in Freight today) and a `C_ec2` marker.
- **Schema rule (why 3.9 exists):** every migration the image expects is applied in the
  production DB. Needs DB access and the image's migration list. Independent of GitHub and of
  knowing `C_ec2`. Caveat: `schema.rb` carries only the max version, so a max-version compare
  misses a migration with an older timestamp merged after a newer one (long-lived PRs make this
  common). The precise form compares the set of versions, which is what Rails' own
  `check_pending!` does; that needs the migration version list in the image.

## Options

Layers, not mutually exclusive. "Enforces on" says which paths the gate actually covers.

| # | Gate | Where | Manual/auto | Enforces on | Needs | Strength |
|---|------|-------|-------------|-------------|-------|----------|
| 1 | Checklist at the Kargo gate (F1 as written) | docs/ | manual | nothing, relies on discipline | nothing | weak; any engineer can promote today |
| 2 | Kargo RBAC: `promote` on `production` limited to `infrastructure@` (project Role + claim annotation; drop `engineers@` from `api.oidc.admins`) | `apps/kargo/projects/codeai`, `apps/kargo/values.yaml` | manual | who can promote | Kargo RBAC change | process control only |
| 3 | Kargo promotion guard: `http` step in `stages/production.yaml` calls GitHub compare `production...C_k` (or latest release tag) and fails the Promotion when status is `ahead`/`diverged` | k8s-gitops + one CI line | auto, applies to manual and auto promotions | every Kargo promotion to production | CI stamps `org.opencontainers.image.revision` on the index (`imagetools create --annotation`); Kargo 1.9.5 exposes `imageFrom().Annotations` | hard rule for Kargo path; bypassed by hand-edited values.yaml |
| 4 | Release-driven selection: release workflow retags merge-base image as `cdo-rails:production`; dedicated Warehouse (Digest strategy, constraint `production`); production Stage sources it directly with auto-promotion | code-dot-org workflow + Kargo | auto | selection of Freight | GitHub Actions retag step, new Warehouse | correct by construction for releases; misses hotfixes; separate Freight so `verifiedIn: test` does not carry |
| 5 | Kargo `verification` on `test` (F9) | needs Argo Rollouts CRDs | auto | eligibility | new infra | wrong moment for an ancestry predicate (commit not yet in production when it reaches test); keep F9 for smoke tests |
| 6 | Argo CD PreSync hook Job in the chart, production only: same image runs the schema check before the new ReplicaSet exists | `k8s/helm` (reuse `dashboard-job.yaml`) | auto | every sync of `codeai-production`, any source | hook annotations, check script | blocks rollout cleanly; hook runs on every sync |
| 7 | Pod self-gate: initContainer (or boot check) in the worker that compares the image's migration versions to `schema_migrations` and exits non-zero if ahead | `k8s/helm` + small script in code-dot-org | auto | every pod start, however the digest arrived (Kargo, manual edit, rollback, node replacement) | check script; migration version list in image for the precise form | strongest guarantee at the point of execution; failure mode is a stalled rollout plus alert |
| 8 | Admission policy: ValidatingAdmissionPolicy/Kyverno allowing only digests attested as released (cosign attestation from the release workflow, D9) | new infra | auto | every pod admission | policy engine, signing in CI | strong, largest scope; fits the P2 supply-chain track |
| 9 | Build the image from the `production` branch (or at release) and have Kargo watch it | code-dot-org CI | auto | selection | second build per DTP | matches EC2 commit exactly, covers hotfixes; bytes never ran in Kargo test; race if triggered at merge |

### Assessment

- Only 6, 7 and 8 enforce regardless of how a digest reaches `values.yaml`. Of those, 7 is the
  cheapest and checks the thing that actually breaks (schema), with no external dependency.
- 3 is the cheapest hard rule on the Kargo path and gives the human at the gate the check they
  would otherwise do by hand. It needs the OCI revision stamp, which 8.1/F8 wants anyway.
- 4 or 9 are about automation of *selection*; they are optional on top of 3 and 7.
- 1 and 2 remain useful as process: the checklist shrinks to verification items (Honeybadger
  exception, canary, drain/rollback timing) and RBAC decides who may press the button.
- Marker choice for the commit rule: `production` branch HEAD covers hotfixes and is schema-safe
  after the ~1-2 minute migrate window; the release tag is strict but misses hotfixes. The
  runtime schema gate (7) closes the window either way.

Recommended combination: **7 + 3**, keep manual promotion (`autoPromotionEnabled: false`) and
F1 as the verification checklist; 4 later if automation of the button is wanted; 2 if the
"who" matters.

## Recommended approach (user choice 2026-10-28): gates 7 + 3

Two independent gates, both fail closed, plus the F1 checklist reduced to verification items.
Manual promotion stays (`autoPromotionEnabled: false`). Marker for the commit rule: the
`production` branch HEAD. Runtime check: precise migration-set comparison.

Empirical facts the design relies on (checked 2026-10-28 against the public GitHub API):

- `GET /repos/code-dot-org/code-dot-org/compare/production...<sha>` works with SHAs. An ancestor
  of production returns `status: behind, ahead_by: 0`; production HEAD itself returns
  `identical`; the staging tip returned `diverged, ahead_by: 5`; an unknown sha returns 404.
  So the predicate is `response.status == 200 && response.body.ahead_by == 0`.
  Unauthenticated limit is 60 requests/hour per IP, fine for promotions; the token from
  `repoCredentials(...)` can be added later if needed.
- Kargo 1.9.5 populates `imageFrom().Annotations` from the OCI **index** annotations (plus
  manifest/descriptor annotations at lower precedence), never from config labels. buildx
  `imagetools create --annotation index:...` silently drops annotations unless the result is an
  OCI index, which it only emits when at least one source manifest is non-Docker-typed. The
  per-arch images are pushed Docker-typed today, so the CI change must switch the per-arch push
  to OCI media types or build the index with a tool that always emits OCI (see code-dot-org
  section).

### Landing order

1. code-dot-org PR to `staging`: migration version list + OCI revision annotation in CI,
   schema-guard script, chart initContainer behind a value defaulting to off. Merge, wait for a
   `latest` publish and confirm the index is OCI with the revision annotation.
2. k8s-gitops (this repo, branch `nicklathe/prod-ready-checklist`): production envType flag,
   Kargo guard step, docs page. Argo picks up the stage change; nothing deploys until F2.
3. The chart change reaches `production` branch with the next DTP; F2 flips the deployment after
   that. The first promotion follows the checklist.

### k8s-gitops changes

**`apps/kargo/projects/codeai/stages/production.yaml`**: insert an `http` step as the FIRST
step (before `git-clone`) so a bad Freight fails before anything is cloned or written:

```yaml
        - uses: http
          as: legacy-ancestry
          retry:
            timeout: 5m          # 5xx from GitHub keeps retrying until this; 404/ahead fail at once
          config:
            method: GET
            url: https://api.github.com/repos/code-dot-org/code-dot-org/compare/production...${{ imageFrom("ghcr.io/code-dot-org/cdo-rails").Annotations["org.opencontainers.image.revision"] }}
            headers:
              - name: Accept
                value: application/vnd.github+json
            timeout: 30s
            successExpression: response.status == 200 && response.body.ahead_by == 0
            failureExpression: response.status == 404 || response.status == 422 || (response.status == 200 && response.body.ahead_by > 0)
            errorExpression: response.status == 200 ? ("image commit is " + string(response.body.ahead_by) + " commit(s) ahead of legacy production (" + response.body.status + ")") : ("GitHub compare returned HTTP " + string(response.status) + "; Freight without a revision annotation cannot be promoted")
            outputs:
              - name: status
                fromExpression: response.body.status
```

Notes: a Freight built before the CI change has no annotation, so the URL ends in `...` and
GitHub returns 404: fail closed, by design. Add a header comment in the file pointing at the
docs page. Do not add the step to `staging`/`test` (their images are meant to be ahead).
Optionally add it to `levelbuilder` only while rehearsing (see Verification), then remove.

**`apps/codeai/envTypes/production.values.yaml`**: enable the chart value the code-dot-org
change introduces (name per that section, e.g. `schemaGuard.enabled: true`). Leave staging and
test off: their k8s images are built from staging HEAD and would correctly but constantly be
blocked against the test DB.

**`docs/production-promotion.md`** (new; `docs/` does not exist yet): the F1 checklist. Contents:
the rule (3.9) and the two automated gates that enforce it; what the human still verifies
(Freight was verified in `test`, Honeybadger test exception from a production worker after E2,
canary job/alert E1 green after promotion); rollout and rollback timing (worker
`terminationGracePeriodSeconds` 2100 from A1, so a rollout or rollback can take up to 35 minutes
per pod while a job finishes); the rollback procedure (re-promote earlier Freight; the Kargo
guard re-runs and passes for any older commit); what a guard failure looks like in Kargo
(Promotion Failed at step `legacy-ancestry` with the error text) and in Argo/kubectl (pod stuck
in `Init:Error`/`Init:CrashLoopBackOff`, `kubectl logs -c schema-guard`), and the hotfix
caveat (a direct push to `production` moves the marker without a release; the gates still work
because they read the branch and the DB). Link it from a new `apps/kargo/projects/codeai/README.md`
(Argo's directory source ignores `.md`) and from the comment in `stages/production.yaml`.

**`PRODUCTION-READINESS-JIRA.md` / `PRODUCTION-READINESS-TASKS.md`**: note under F1 that 3.9 is now
enforced by the two gates and that the checklist holds the remaining manual items; no checkbox
flips until the first production promotion has used it.

No Helm chart under `apps/` changes, so no `Chart.yaml` bump. No `apps/app-of-apps` structure
change, so no mimic-tree edit.

### code-dot-org changes (one PR to `staging`; repo at `/Users/nicklathe/Code/code-dot-org/code-dot-org`)

Verified facts behind this section: `mysql2` is in the default Gemfile group; `require './deployment'`
already loads DB-less in the image (`docker/rails/smoke-test.sh:19-20`) and resolves
`CDO.dashboard_db_reader` → `db_writer` (`config.yml.erb:584-593`); `dashboard/config/database.yml:9-10`
builds the connection from that URI; `dashboard/bin` is in the slice; `Dockerfile.dockerignore:45`
carves out `dashboard/db/migrate` only (a sibling file `dashboard/db/migrate_versions.txt` is admitted
by `!dashboard`); the worker has a fixed `activeJobWorker.replicas: 1` (`k8s/helm/values.yaml:67`) and
the HPA targets only the dashboard Deployment (`templates/dashboard/autoscaler.yaml:1`); the pod
template sets no `strategy` (`_dashboard.yaml:55-68`); `regctl index create <ref> --ref <child>...
--annotation k=v` defaults to `application/vnd.oci.image.index.v1+json`.

1. **Migration version list in the image**
   - New `docker/rails/write-migrate-versions.sh` (sibling of `ensure-locales.sh`): list
     `dashboard/db/migrate/*.rb`, take the leading 14-digit version, sort, write one per line to
     `dashboard/db/migrate_versions.txt`. Add that path to the root `.gitignore`.
   - `.github/workflows/cdo-rails-image.yml`: run it right after each `ensure-locales.sh` step in
     the `smoke-test`, `rails-boot` and `build-push` jobs (all have a full checkout before `docker build`).
   - `skaffold.yaml` `build.hooks.before`: add it as a second command so local images carry the file.
   - `docker/rails/smoke-test.sh`: assert `dashboard/db/migrate_versions.txt` is non-empty and
     `dashboard/bin/check-schema-migrations` is executable (next to the existing `setup-db-minimal` assert).
   - Do NOT re-admit `db/migrate` into the slice; keep the design statement that `db:migrate` cannot
     run from this image.

2. **OCI index annotation `org.opencontainers.image.revision`**
   - Leave both per-arch build/push legs alone (the pushed bytes stay the tested bytes).
   - In the `merge` job replace the `docker buildx imagetools create` call with regctl
     (install via a SHA-pinned `regclient/actions/regctl-installer`; `login-action` already wrote
     `~/.docker/config.json`, add `regctl registry login ghcr.io` if needed). Per tag in `$TAGS`:
     `regctl index create "$ref" --ref "$IMAGE:git-$SHA-amd64" --ref "$IMAGE:git-$SHA-arm64" --annotation "org.opencontainers.image.revision=${{ github.sha }}"`.
     If the inspect check (Verification) shows missing `platform` entries, use the two-step form:
     `index create` with the amd64 ref and `--desc-platform linux/amd64`, then `index add` with the
     arm64 ref and `--desc-platform linux/arm64`.
   - Fallback if regctl proves awkward: `skopeo copy --format oci docker-daemon:... docker://...` per
     leg, then keep buildx with `--annotation "index:org.opencontainers.image.revision=..."`.
   - `docker/rails/README.md` tag contract: add a fifth guarantee: "the index carries
     `org.opencontainers.image.revision` naming the staging commit it was built from".

3. **`dashboard/bin/check-schema-migrations`** (new, executable, modelled on `setup-db-minimal`)
   - `require File.expand_path('../../deployment', __dir__)`, `require 'mysql2'`, `$stdout.sync = true`.
   - Env `SCHEMA_GUARD_MODE` = `enforce` (default) | `warn` | `off`. Not a `CDO_*` name: those are
     parsed into config and need a default in `config.yml.erb` (`lib/cdo.rb:42-68`).
   - Optional test hook `SCHEMA_GUARD_EXTRA_VERSIONS` (comma list) appended to the expected set.
   - Read `dashboard/db/migrate_versions.txt`; missing or empty → exit 2 with "image carries no version
     list; build via CI or skaffold".
   - Connect exactly as `database.yml` does: `URI.parse(CDO.dashboard_db_reader || CDO.dashboard_db_writer)`
     → `Mysql2::Client.new(host:, port: uri.port || 3306, username:, password:, database: uri.path[1..],
     connect_timeout: 5, read_timeout: 30, default_group: 'cdo')`. Any `Mysql2::Error`/`SocketError`
     → exit 2 "schema guard could not query the database" (fail closed, distinct code).
   - `SELECT version FROM schema_migrations`; `missing = expected - applied` (string compare). Print
     counts and max of each side plus every missing version. Missing non-empty → exit 1 (`enforce`)
     or exit 0 with `WARN` (`warn`). DB ahead (extra rows) → exit 0 and note the count.
   - Rejected: `Cdo::Sequel.database_connection_pool` (pulls DCDO/Gatekeeper = DynamoDB in production)
     and `rails runner` (eager load, ~3 GiB; the worker needs that much already). Fallback if the
     plain client ever diverges from Rails' settings: `rails runner 'puts ActiveRecord::SchemaMigration.all_versions'`
     with `SKIP_SCRIPT_PRELOAD=1`.

4. **Helm chart `k8s/helm`**
   - `templates/dashboard/_dashboard.yaml`: factor the container plumbing into named templates so the
     init container cannot drift: `dashboard.containerEnv` (the `env:` + `envFrom:` blocks, l.89-133,
     parametrised by rails env / extraEnv), `dashboard.containerSecurityContext` (l.135-136),
     `dashboard.containerResources` (l.139-151), `dashboard.volumeMounts` (l.186-194). Main container
     includes them unchanged.
   - Add, inside `spec.template.spec`, gated by `and $isDeployment .Values.schemaGuard.enabled` (Jobs
     stay unguarded: `setup-db-minimal` populates an empty DB), `initContainers:` with one entry
     `schema-guard`: same `image`/`imagePullPolicy`, `command: ["sh","-c"]`,
     `args: ["exec bundle exec ruby dashboard/bin/check-schema-migrations"]`, extra env
     `SCHEMA_GUARD_MODE` from `.Values.schemaGuard.mode`, and the four shared includes. `RAILS_ENV`
     is load-bearing (`dashboard_db_name` is `dashboard_#{env}`); sharing `resources` keeps QoS
     Guaranteed at no scheduling cost.
   - Add for Deployments `strategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}`
     so "old pods keep running while the new one fails Init" holds at any replica count.
   - `values.yaml`: new block `schemaGuard: {enabled: false, mode: enforce}` after `activeJobWorker`,
     commented: production enables it from k8s-gitops; `mode: warn` is the staged-rollout and
     emergency setting. `values.schema.json`: add the object (`additionalProperties: false`, `mode` enum).
     Bump `Chart.yaml` `version` (0.4.0 → 0.5.0).
   - New `k8s/bin/verify-schema-guard` (modelled on `verify-worker-priorities`): `helm template` with
     the value on/off; assert the init container exists only when enabled, shares `image`, `envFrom`
     and `resources` with the worker container, and never appears in the `dashboardJob` Job. Wire into
     `.github/workflows/k8s-validate.yml`.
   - `skaffold.yaml`: a `schema-guard` profile setting `schemaGuard.enabled: true` (pattern of the
     `setup-db-minimal` profile).

5. **Local DB parity**: `dashboard/bin/setup-db-minimal` after `db:schema:load` (and idempotently
   in its `current` branch) inserts every version from `migrate_versions.txt` absent from
   `schema_migrations`. Reason: `ActiveRecord::Schema.define` back-fills only versions found in
   `db/migrate`, which the image lacks, so a schema-loaded local DB would hold one row and the guard
   would report ~950 missing. `k8s/README.md`: document the guard, the versions file, and that
   existing local DBs must re-run the setup profile.

**Failure mode on the cluster**: new pod `Init:Error` → `Init:CrashLoopBackOff`; kubelet retries
with backoff (≤5 min), so once the legacy deploy applies the migration the rollout completes by
itself. Deployment hits `progressDeadlineSeconds` (600) → Argo Progressing then Degraded (alerting
per 7.2). Old ReplicaSet untouched. Recovery: wait for the legacy deploy, re-promote an older
Freight, or set `schemaGuard.mode: warn`.

**Rollout**: first production enablement with `mode: warn` for one promotion to prove DB
connectivity and credentials from an init container, then `enforce`.

## Verification

**code-dot-org, before merge**: `ruby k8s/bin/verify-schema-guard`; `./docker/rails/write-migrate-versions.sh && docker build ...`
then `docker/rails/smoke-test.sh` (file and script present); local skaffold: `skaffold dev -p setup-db-minimal`
(seeds history), then `skaffold dev -p schema-guard` → worker starts; delete a non-max row
(`DELETE FROM schema_migrations WHERE version='<some older version>'`) to prove set semantics,
restart the worker, expect `Init:Error` and the version in `kubectl logs -c schema-guard`; re-insert
and watch it proceed without a resync. Also exercise `mode: warn` and a wrong DB URL (exit 2).

**CI annotation**: after the first `staging` publish post-merge,
`docker buildx imagetools inspect --raw ghcr.io/code-dot-org/cdo-rails:latest | jq '.mediaType,.annotations,[.manifests[].platform]'`
shows `application/vnd.oci.image.index.v1+json`, the revision annotation equal to the staging sha,
and both platforms. `docker pull` of `latest` and a staging pod pull confirm the mixed-child index.
Then `kubectl get freight -n kargo-project-codeai -o jsonpath='{.items[-1].images[0].annotations}'`
shows the same (Kargo refreshes the Warehouse on the `package` webhook).

**Kargo guard rehearsal (before F2, on the `levelbuilder` Stage)**: temporarily add the same
step to `stages/levelbuilder.yaml`; promote (a) an old Freight without annotation: expect
failure at `legacy-ancestry` with the 404 text; (b) the newest Freight: expect failure with
`ahead_by > 0` unless a DTP just landed; (c) the Freight whose annotation equals
`git merge-base production staging`: expect the step to pass (later steps may fail on the
missing `codeai-levelbuilder` app; that is fine). Remove the step from levelbuilder afterwards.
All of this is read-only on production.

**Runtime guard**: local skaffold test per the code-dot-org section (run the worker against a
local DB, delete one `schema_migrations` row, expect `Init:Error` and a log line naming the
missing version; restore, expect the pod to start). On the cluster, the first production
promotion: `kubectl -n production get pods` shows the init container completing in seconds and
`kubectl logs -c schema-guard` prints the counts compared. To exercise the failure path in
production without touching the DB, the script supports an extra-versions override env
(`CDO_SCHEMA_GUARD_EXTRA_VERSIONS=20991231000000`) set temporarily via values; expect
`Init:Error`, old pods untouched, Argo `Progressing` then `Degraded`; remove the override.

**Checklist**: the first production promotion is done by following `docs/production-promotion.md`
end to end; F1 "Done when" is met when that happened.
