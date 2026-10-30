## ADDED Requirements

### Requirement: Published image index names its source commit

The `cdo-rails` image index that CI publishes for each push to `staging` SHALL be an OCI image index (`application/vnd.oci.image.index.v1+json`) whose index annotations include `org.opencontainers.image.revision` set to the full 40-character SHA of the commit the image was built from. The annotation SHALL be present on every tag CI publishes for that build (`git-<sha>` and `latest`). The per-architecture images SHALL be the same manifests that CI smoke-tested, and the index SHALL list both `linux/amd64` and `linux/arm64` with platform descriptors.

#### Scenario: CI publishes a staging build

- **WHEN** the image workflow's merge job runs for a push to `staging`
- **THEN** it builds the index under `:git-<sha>` first, inspects it, and only after the OCI media type, the revision annotation equal to that push's SHA and two platform entries are confirmed copies it to `:latest`
- **AND** the job fails before `latest` moves if any of those three checks does not hold, so Kargo never observes an unvalidated index

#### Scenario: Kargo discovers the build

- **WHEN** the Warehouse next refreshes after the publish
- **THEN** the resulting Freight's `cdo-rails` image entry carries the same revision annotation

#### Scenario: The index is pullable everywhere it is used

- **WHEN** `latest` is pulled by Docker on an amd64 host, on an arm64 host, and by a pod on the cluster
- **THEN** each pull resolves to the matching per-architecture image and succeeds

### Requirement: Image carries the migration set it expects

The image SHALL contain `dashboard/db/migrate_versions.txt` listing the 14-digit version of every file in `dashboard/db/migrate` at the build commit, one per line, sorted ascending, without duplicates. The file SHALL be generated at build time by `docker/rails/write-migrate-versions.sh` and SHALL NOT be committed to the repository. The image SHALL continue to exclude `dashboard/db/migrate`.

#### Scenario: CI build

- **WHEN** CI builds the image in any job that runs `docker build`
- **THEN** the version list is written before the build and the built image contains it with one line per migration file

#### Scenario: Local build

- **WHEN** an engineer builds the image with skaffold
- **THEN** the build hook writes the same file so the local image carries it

#### Scenario: Smoke test guards the contract

- **WHEN** `docker/rails/smoke-test.sh` runs against a built image
- **THEN** it fails if `dashboard/db/migrate_versions.txt` is missing or empty, or if `dashboard/bin/check-schema-migrations` is missing or not executable, or if `dashboard/db/migrate` is present

### Requirement: Tag contract documents the provenance guarantee

`docker/rails/README.md` SHALL list, alongside the existing tag guarantees, that the published index carries `org.opencontainers.image.revision` naming the staging commit it was built from, and that the image carries its migration version list. It SHALL also correct the existing `git-<sha>` guarantee: that tag is republished when the `cdo-deps` chain or a manual dispatch rebuilds the commit, so a digest is the only immutable handle.

#### Scenario: Reading the tag contract

- **WHEN** an engineer reads the tag contract section
- **THEN** it states the revision annotation and the version list as guarantees of every published build, and states that `git-<sha>` can be repointed by a rebuild
