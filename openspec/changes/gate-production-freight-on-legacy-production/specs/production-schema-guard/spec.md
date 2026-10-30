## ADDED Requirements

### Requirement: Deployment pods verify the schema before the application starts

When `schemaGuard.enabled` is true, every Deployment rendered by the `k8s/helm` chart SHALL include an initContainer named `schema-guard` that runs `dashboard/bin/check-schema-migrations` from the same image and digest as the main container, with the same `env`/`envFrom`, `securityContext`, `resources` and `volumeMounts`, rendered from shared named templates so the two cannot drift. One-shot Jobs rendered by the chart SHALL NOT include the initContainer. The value SHALL default to `false`.

#### Scenario: Guard enabled

- **WHEN** the chart is rendered with `schemaGuard.enabled: true`
- **THEN** the dashboard and active-job-worker Deployments each contain the `schema-guard` initContainer sharing image, env, envFrom, securityContext, resources and volumeMounts with the main container
- **AND** the `dashboardJob` Job contains no initContainers

#### Scenario: Guard disabled

- **WHEN** the chart is rendered with default values
- **THEN** no workload contains an initContainer

### Requirement: The check compares the exact migration set

The check SHALL read the expected versions from `dashboard/db/migrate_versions.txt`, connect to the dashboard database with the same URI Rails uses (`CDO.dashboard_db_reader`, falling back to `CDO.dashboard_db_writer`, so `RAILS_ENV` selects the database name), read `SELECT version FROM schema_migrations`, and compute the set of expected versions absent from the database. It SHALL print the expected and applied counts, the maximum version on each side, and every missing version.

#### Scenario: Every expected migration is applied

- **WHEN** the database holds every version in the manifest
- **THEN** the check exits 0 and logs the counts and maxima

#### Scenario: An older-timestamped migration is missing

- **WHEN** the database holds the manifest's maximum version but lacks a lower version from the manifest
- **THEN** the check reports that version as missing and, in `enforce` mode, exits 1

#### Scenario: The database is ahead of the image

- **WHEN** the database holds versions not in the manifest and none are missing
- **THEN** the check exits 0 and logs how many extra versions the database holds

#### Scenario: The database cannot be queried

- **WHEN** the connection fails, authentication fails, or the query errors
- **THEN** the check exits 2 with a message saying the guard could not query the database
- **AND** the pod does not start

#### Scenario: The image carries no manifest

- **WHEN** `dashboard/db/migrate_versions.txt` is missing or empty
- **THEN** the check exits 2 with a message saying the image carries no version list

### Requirement: Guard mode is configurable and defaults to enforce

The initContainer SHALL receive `SCHEMA_GUARD_MODE` from `schemaGuard.mode`, one of `enforce` (default), `warn`, or `off`, and the chart's values schema SHALL reject any other value. When `schemaGuard.extraVersions` is non-empty the initContainer SHALL receive it as `SCHEMA_GUARD_EXTRA_VERSIONS`, a comma-separated list the check appends to the expected set, for drills only.

#### Scenario: Warn mode with a missing migration

- **WHEN** `SCHEMA_GUARD_MODE` is `warn` and a version is missing
- **THEN** the check logs a `WARN` line listing the missing versions and exits 0

#### Scenario: Off mode

- **WHEN** `SCHEMA_GUARD_MODE` is `off`
- **THEN** the check exits 0 without connecting to the database

#### Scenario: Drill with a far-future version

- **WHEN** `SCHEMA_GUARD_EXTRA_VERSIONS` is `20991231000000` in `enforce` mode
- **THEN** the check exits 1 naming that version, and the pod stays in `Init:Error`

#### Scenario: Invalid mode value

- **WHEN** the chart is rendered with `schemaGuard.mode: sometimes`
- **THEN** rendering fails schema validation

### Requirement: A failed guard never reduces running capacity

Deployments rendered by the chart SHALL use a `RollingUpdate` strategy with `maxUnavailable: 0` and `maxSurge: 1`. When the initContainer fails, the previous ReplicaSet's pods SHALL keep running, the kubelet SHALL keep retrying the initContainer with backoff, and the rollout SHALL complete without manual action once the check passes.

#### Scenario: New pod blocked by a missing migration

- **WHEN** a rollout starts and the database lacks a migration the new image expects
- **THEN** the old pod keeps serving, the new pod shows `Init:Error` then `Init:CrashLoopBackOff`, and `kubectl logs -c schema-guard` names the missing version
- **AND** the Deployment reports `Progressing` and, after its progress deadline, Argo reports the Application `Degraded`

#### Scenario: Legacy deploy applies the migration later

- **WHEN** the missing version appears in `schema_migrations`
- **THEN** the next initContainer retry exits 0 and the rollout completes without a resync

### Requirement: Local databases carry full migration history

`dashboard/bin/setup-db-minimal` SHALL record every version from `dashboard/db/migrate_versions.txt` into `schema_migrations` immediately after its own `db:schema:load`, so a schema-loaded local database passes the guard. Against an existing database it SHALL backfill only when `schema_migrations` holds exactly one row, which identifies a database an earlier image schema-loaded. A database with more history SHALL be left untouched, because the script's table-name and maximum-version check cannot distinguish a pending older-timestamp migration from an applied one, and recording it would hide a missing column from both the guard and `db:migrate`.

#### Scenario: Fresh local database

- **WHEN** the `setup-db-minimal` skaffold profile creates a database from the image
- **THEN** `schema_migrations` holds every manifest version and the `schema-guard` profile starts the worker

#### Scenario: Existing schema-loaded database

- **WHEN** `setup-db-minimal` runs against a database at the current schema whose `schema_migrations` holds one row
- **THEN** it inserts the absent manifest versions and changes nothing else

#### Scenario: Database with real migration history

- **WHEN** `setup-db-minimal` runs against a database at the current schema whose `schema_migrations` holds more than one row
- **THEN** it inserts nothing, and any version the image expects but the database lacks is reported by the guard rather than hidden

### Requirement: Chart validation covers the guard

The chart SHALL ship `k8s/bin/verify-schema-guard`, wired into the `k8s-validate` workflow, that renders the chart with the guard on and off and asserts the initContainer contract. The chart package version SHALL be bumped with this change.

#### Scenario: Validation on a pull request

- **WHEN** `k8s-validate` runs
- **THEN** `verify-schema-guard` passes, confirming the initContainer exists only when enabled, shares image, envFrom and resources with the worker container, and never appears in the Job

### Requirement: Every envType that shares a legacy database enables the guard

The k8s `staging`, `test` and `production` namespaces use the databases that legacy staging, test and production migrate, so each of those envTypes in k8s-gitops SHALL set `schemaGuard.enabled: true`. Production SHALL start in `enforce`: a connection failure exits 2 in every mode, so `warn` would prove nothing about credentials, and at first enablement no k8s capacity exists to protect while legacy serves every job, so a false block costs nothing and a false start is the hazard itself. Staging SHALL start in `warn` for one rollout, to read the comparison against a real legacy database and surface any false positive before production, and SHALL then move to `enforce`. Test SHALL stay in `warn` until the observed gap between the test database and staging-built images has been reviewed, and SHALL then either move to `enforce` or be re-pointed at Freight built from the legacy `test` branch in a follow-up change. The Kargo commit gate SHALL apply to `production` only.

#### Scenario: First guarded rollout in staging

- **WHEN** the first staging pod starts with `mode: warn`
- **THEN** the initContainer log shows the counts compared and the pod starts
- **AND** a follow-up commit sets staging to `enforce` before production is enabled

#### Scenario: First production pod

- **WHEN** the first production promotion rolls out with `mode: enforce`
- **THEN** the initContainer exits 0 and logs the counts, or blocks in `Init:Error` naming the missing versions while legacy keeps serving every job
- **AND** no switch to `warn` happens without a reviewed decision based on those versions

#### Scenario: Staging image arrives before the legacy staging build has migrated

- **WHEN** a migration is pushed to `staging` while a legacy staging build is already running, the new image reaches k8s staging first, and the mode is `enforce`
- **THEN** the new staging pod blocks in `Init:Error` naming the version, the old pod keeps serving, and the rollout completes by itself once the next legacy staging build has migrated

#### Scenario: Test image is ahead of the test database

- **WHEN** a staging-built image reaches k8s test before a robo-DTT has migrated the test database, and the mode is `warn`
- **THEN** the initContainer logs a `WARN` line listing the missing versions and the pod starts
- **AND** those logs, one per pod start, record how often test pods started ahead of their database; how long each gap lasted is inferred from the time of the next robo-DTT build, not measured

#### Scenario: Blocked Freight is not verified in that Stage

- **WHEN** a Promotion's Argo sync completes but the new pod is blocked by the guard in `enforce` mode
- **THEN** the Promotion succeeds, the Stage is not Healthy while the Deployment is stalled, and the Freight is not marked verified in that Stage until the pod starts and the Stage is Healthy
