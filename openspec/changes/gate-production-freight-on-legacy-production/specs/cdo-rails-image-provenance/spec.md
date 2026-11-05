## ADDED Requirements

### Requirement: Published image index names its source commit

The `cdo-rails` image index that CI publishes for each push to `staging` SHALL be an OCI image index (`application/vnd.oci.image.index.v1+json`). Its index annotations SHALL include `org.opencontainers.image.revision`, set to the full 40-character SHA of the commit the image was built from. The annotation SHALL be present on every tag CI publishes for that build (`git-<sha>` and `latest`). The per-architecture images SHALL be the same manifests that CI smoke-tested, and the index SHALL list both `linux/amd64` and `linux/arm64` with platform descriptors.

#### Scenario: CI publishes a staging build

- **WHEN** the image workflow's merge job runs for a push to `staging`
- **THEN** it builds the index under `:git-<sha>` first and inspects it
- **AND** it copies the index to `:latest` only after confirming the OCI media type, the revision annotation equal to that push's SHA, and two platform entries
- **AND** the job fails before `latest` moves if any of those three checks does not hold, so Kargo never observes an unvalidated index

#### Scenario: Kargo discovers the build

- **WHEN** the Warehouse next refreshes after the publish
- **THEN** the resulting Freight's `cdo-rails` image entry carries the same revision annotation

#### Scenario: The index is pullable everywhere it is used

- **WHEN** `latest` is pulled by Docker on an amd64 host, on an arm64 host, and by a pod on the cluster
- **THEN** each pull resolves to the matching per-architecture image and succeeds

### Requirement: Tag contract documents the provenance guarantee

`docker/rails/README.md` SHALL list, alongside the existing tag guarantees, that the published index carries `org.opencontainers.image.revision` naming the staging commit it was built from. It SHALL also correct the existing `git-<sha>` guarantee: that tag is republished when the `cdo-deps` chain or a manual dispatch rebuilds the commit, so a digest is the only immutable handle.

#### Scenario: Reading the tag contract

- **WHEN** an engineer reads the tag contract section
- **THEN** it states the revision annotation as a guarantee of every published build, and states that `git-<sha>` can be repointed by a rebuild
