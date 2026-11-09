## ADDED Requirements

### Requirement: Eligible legacy releases move the production tag

A code-dot-org workflow SHALL run whenever a GitHub release of `code-dot-org/code-dot-org` is published. It SHALL act only on eligible releases: not a draft or prerelease, a tag matching `^v\d{4}-\d{2}-\d{2}\.\d+$`, and a release commit that is a merge commit contained in the `production` branch. For an eligible release it SHALL resolve the image commit, validate the image, write the alias `ghcr.io/code-dot-org/cdo-rails:release-<release tag>`, and move the mutable tag `ghcr.io/code-dot-org/cdo-rails:production`, preserving the index digest and the `org.opencontainers.image.revision` annotation.

#### Scenario: A DTP finishes and a release is published

- **WHEN** `bin/create-release` publishes release `vYYYY-MM-DD.N` at the end of the legacy production deploy
- **THEN** within one workflow run `cdo-rails:production` and `cdo-rails:release-vYYYY-MM-DD.N` resolve to the digest of the image built from the release's staging commit
- **AND** the index behind `production` carries `org.opencontainers.image.revision` equal to that commit

#### Scenario: A prerelease or a release with a foreign tag format

- **WHEN** a release is published as a prerelease, as a draft, or with a tag that does not match the production format
- **THEN** the workflow logs that the release is not eligible and writes nothing

#### Scenario: A hotfix is pushed to production

- **WHEN** a direct push to `production` produces no release
- **THEN** the workflow does not run and `cdo-rails:production` is unchanged

### Requirement: The release names the revision the legacy deploy actually ran

`lib/rake/infra.rake` `publish_github_release` SHALL pass the revision `ci_build` recorded for the build to `bin/create-release`. `bin/create-release` SHALL accept `--commit <sha>` and use it as the release's `target_commitish`. Interactive use without the option SHALL behave as today.

#### Scenario: Production advances during a deploy

- **WHEN** deploy A is running and a second DTP moves `production` to B before A publishes its release
- **THEN** A's release tag points at A's commit, not at B
- **AND** the k8s workflow resolves A's staging commit

### Requirement: The image commit is resolved exactly, without automatic fallback

The workflow SHALL take `merge_base_commit.sha` from the GitHub compare API for `staging...<release sha>` as the image commit. It SHALL require that `ghcr.io/code-dot-org/cdo-rails:git-<sha>` exists, and SHALL resolve that tag to a digest once, using the digest for every later read and write.

- If the manifest is absent, the workflow SHALL fail without writing. The failure SHALL name the release and the commit and list up to thirty ancestors of that commit for which an image exists, for an operator to choose with the `image_commit` override after a compatibility review.
- A not-found response SHALL be distinguished from authentication errors, timeouts and server errors. Those SHALL fail as "cannot determine" without suggestions.

#### Scenario: The merge base has an image

- **WHEN** CI published `git-<merge base>`
- **THEN** that commit and its current digest are used and the job summary names both

#### Scenario: The merge base has no image

- **WHEN** the registry returns not-found for `git-<merge base>`
- **THEN** the workflow fails before any write, lists the nearest ancestors that have images, and points at the `image_commit` override

#### Scenario: The registry cannot be queried

- **WHEN** the manifest request fails with an authentication error, a timeout or a 5xx response
- **THEN** the workflow fails before any write as "cannot determine" and suggests no fallback commit

### Requirement: Writes happen by digest, in a safe order, and are classified on failure

Before any write the workflow SHALL validate the resolved index by digest: OCI index media type, revision annotation equal to the resolved commit, both platform descriptors present. It SHALL then, in order:

1. copy the digest to `release-<tag>` and read it back;
2. perform the forward-only check;
3. copy the digest to `production` and read it back.

A failure before the live copy SHALL be reported as "nothing published". A failure at or after the live copy SHALL be reported as "outcome unknown, inspect registry and Kargo".

#### Scenario: Validation fails

- **WHEN** the resolved index lacks the annotation or a platform descriptor
- **THEN** the workflow fails with the inspection output and neither tag has changed

#### Scenario: Read-back of the live tag fails

- **WHEN** the copy to `production` returns an error or the read-back digest differs
- **THEN** the workflow fails as "outcome unknown" and the summary tells the operator to inspect the registry digest of `production`, the Warehouse and any Promotion before acting

### Requirement: Runs are serialized, no queued run is dropped, and the live tag only moves forward

The workflow SHALL declare a `concurrency` group with `cancel-in-progress: false` and `queue: max`, so that runs execute one at a time and a run waiting in the queue is not cancelled when another is queued. Immediately before the live copy the run SHALL read the `org.opencontainers.image.revision` annotation of the index `cdo-rails:production` currently resolves to, and SHALL move the live tag only when the compare API for `<live revision>...<image commit>` reports `behind_by` 0 and the release commit is still contained in `production`.

Otherwise it SHALL write only the alias and stop, with a summary saying so, unless the `workflow_dispatch` input `move_live_tag` is true.

- If `cdo-rails:production` does not exist, the run SHALL proceed.
- If the live index has no revision annotation, or GitHub does not know the live revision, the run SHALL fail before the live copy as "cannot determine".

#### Scenario: Several releases queue

- **WHEN** two more releases are published while a run is executing
- **THEN** both later runs wait and neither is cancelled
- **AND** after all three have run, `production` resolves to the newest release's digest and all three aliases exist, whatever order the runs executed in

#### Scenario: An older release is re-run

- **WHEN** an operator dispatches the workflow for a release whose image commit is behind the live revision, without `move_live_tag`
- **THEN** its alias is written or confirmed and `production` is unchanged

#### Scenario: The newest release's run fails

- **WHEN** the run for release N+1 fails to resolve its image and the run for release N executes after it
- **THEN** release N's run moves `production` to N's digest, and the failure notification names N+1

#### Scenario: The live tag does not exist yet

- **WHEN** `cdo-rails:production` does not exist and the workflow runs for an eligible release, whether the first seed or the first release after the workflow is active
- **THEN** the live tag is created at that release's digest without `move_live_tag`

### Requirement: Release aliases are stable and overrides are scoped to the release

If `release-<tag>` already exists with the same digest, the write SHALL succeed unchanged. If it exists with a different digest, the workflow SHALL fail before any write unless the dispatch input `replace_alias` is true. The `workflow_dispatch` entry point SHALL take `release_tag` (required), `image_commit`, `replace_alias`, `move_live_tag` and `dry_run`. With `image_commit`, the workflow SHALL skip resolution but SHALL call the compare API for `<release sha>...<override>` and fail unless `ahead_by` is 0. With `dry_run`, it SHALL perform every read and validation and no write.

#### Scenario: Re-run for a release already processed

- **WHEN** the workflow runs again for a release whose alias already points at the resolved digest
- **THEN** it succeeds, writes nothing new, and the summary says the alias was confirmed

#### Scenario: Conflicting alias

- **WHEN** the resolved digest differs from the digest an existing alias points at and `replace_alias` is not set
- **THEN** the workflow fails before any write and names both digests

#### Scenario: Override not contained in the release

- **WHEN** an operator dispatches the workflow with an `image_commit` that is not an ancestor of the release's commit
- **THEN** the workflow fails before any write and names the compare status

#### Scenario: Dry run

- **WHEN** the workflow is dispatched with `dry_run`
- **THEN** the summary reports the release, the commit, the digest and what would be written, and neither tag changes

### Requirement: Failures notify a person

On any failure the workflow SHALL post the release, the stage reached and the outcome class to the channel the team designates, so that a release that did not reach k8s production is noticed without anyone watching Actions.

#### Scenario: Workflow fails for any reason

- **WHEN** a run ends in failure
- **THEN** a notification names the release, the last stage completed, and whether anything was published

### Requirement: The tag contract documents the production tags

`docker/rails/README.md` SHALL state:

- that `cdo-rails:production` always points at the exact image of a staging commit contained in a legacy production release, moved only by the release workflow and never by hand;
- that `cdo-rails:release-<tag>` is an alias per release that is not repointed without an explicit correction;
- that a digest is the only immutable handle, since `git-<sha>` is republished by rebuilds.

#### Scenario: Reading the tag contract

- **WHEN** an engineer reads the README's tag section
- **THEN** they find `latest`, `git-<sha>`, `production` and `release-<tag>` each defined with who moves them and what they guarantee
