# Scope and conventions

Two repositories. Tasks 1-4 are edits in `code-dot-org` (one PR to `staging`, branch to be
named by the user). Tasks 5-6 are edits in `k8s-gitops` on `nicklathe/prod-ready-checklist`.
Task 7 is rollout. Tasks marked **(user)** need an action only the user takes: git commit
and push, PR merge, a Kargo promotion, or a values change on the live production envType.
Everything else is file editing plus local, read-only verification. Nothing in this list
runs `kubectl` mutations or `tofu`.

## 1. code-dot-org: image provenance

- [ ] 1.1 Add `docker/rails/write-migrate-versions.sh` (leading 14-digit version of every `dashboard/db/migrate/*.rb`, sorted, unique, one per line into `dashboard/db/migrate_versions.txt`) and add `/dashboard/db/migrate_versions.txt` to the root `.gitignore`
- [ ] 1.2 In `.github/workflows/cdo-rails-image.yml`, run the script immediately after each `ensure-locales.sh` step in the `smoke-test`, `rails-boot` and `build-push` jobs
- [ ] 1.3 In the `merge` job, install regctl from a SHA-pinned `regclient/actions/regctl-installer`, replace `docker buildx imagetools create` with one `regctl index create "$IMAGE:git-$SHA" --ref "$IMAGE:git-$SHA-amd64" --ref "$IMAGE:git-$SHA-arm64" --annotation "org.opencontainers.image.revision=$SHA"`, inspect that index and fail the job unless the media type is the OCI index, the annotation equals `github.sha`, and both platform descriptors are present, and only then `regctl image copy` it to `latest` and every other tag in `$TAGS` (document the `--desc-platform` two-step and the skopeo fallbacks in a comment)
- [ ] 1.4 Add the script as a second command in the `skaffold.yaml` `build.hooks.before` so local images carry the version list
- [ ] 1.5 Extend `docker/rails/smoke-test.sh` to assert the version list is non-empty, `dashboard/bin/check-schema-migrations` is executable, and `dashboard/db/migrate` is absent
- [ ] 1.6 Update the tag contract in `docker/rails/README.md`: add the revision annotation and the version list, and correct the `git-<sha>` guarantee, which is repointed when the `cdo-deps` chain or a manual dispatch rebuilds that commit; a digest is the only immutable handle

## 2. code-dot-org: schema guard script

- [ ] 2.1 Add `dashboard/bin/check-schema-migrations` (executable Ruby; requires `deployment.rb` and `mysql2`; `SCHEMA_GUARD_MODE` enforce|warn|off, `SCHEMA_GUARD_EXTRA_VERSIONS`; connects with the `CDO.dashboard_db_reader || CDO.dashboard_db_writer` URI, `default_group: 'cdo'`, short timeouts; `SELECT version FROM schema_migrations`; prints counts, maxima and every missing version; exit 0 ok/warn, 1 ahead in enforce, 2 cannot decide)
- [ ] 2.2 Update `dashboard/bin/setup-db-minimal` to record every version from `migrate_versions.txt` into `schema_migrations` immediately after its own `db:schema:load`, and on an existing `current` database only when `schema_migrations` holds exactly one row; leave any database with more history untouched and explain why in a comment
- [ ] 2.3 Run the script locally against a MySQL in each state (all applied, one older version deleted, DB ahead, wrong URL, missing manifest, warn, off, extraVersions) and record the exit codes observed

## 3. code-dot-org: Helm chart

- [ ] 3.1 In `k8s/helm/templates/dashboard/_dashboard.yaml`, factor the container `env`/`envFrom`, `securityContext`, `resources` and `volumeMounts` into named templates (`dashboard.containerEnv`, `dashboard.containerSecurityContext`, `dashboard.containerResources`, `dashboard.volumeMounts`) and include them from the main container unchanged
- [ ] 3.2 Add the `schema-guard` initContainer to the pod template, gated by `and $isDeployment .Values.schemaGuard.enabled`, using the same image and the four shared includes, with `SCHEMA_GUARD_MODE` from `schemaGuard.mode` and `SCHEMA_GUARD_EXTRA_VERSIONS` only when `schemaGuard.extraVersions` is non-empty
- [ ] 3.3 Add `strategy: RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1` to the Deployments
- [ ] 3.4 Add `schemaGuard: {enabled: false, mode: enforce, extraVersions: ""}` to `values.yaml` with comments, add the object (mode enum, no additional properties) to `values.schema.json`, and bump `Chart.yaml` version 0.4.0 → 0.5.0
- [ ] 3.5 Add `k8s/bin/verify-schema-guard` (renders on and off; asserts the initContainer exists only when enabled, shares image, envFrom and resources with the worker container, and never appears in the Job; rejects an invalid mode) and run it from `.github/workflows/k8s-validate.yml`
- [ ] 3.6 Add a `schema-guard` skaffold profile that sets `schemaGuard.enabled: true`
- [ ] 3.7 Document the guard, the version list, the modes and the one-time local database re-setup in `k8s/README.md`

## 4. code-dot-org: verify and land

- [ ] 4.1 Run `k8s/bin/verify-schema-guard`, `k8s/bin/verify-worker-priorities`, `helm template` and `helm lint` on the chart, and the smoke test against a locally built image
- [ ] 4.2 Run the local skaffold sequence: `setup-db-minimal` profile, then `schema-guard` profile starts the worker; delete one non-maximum `schema_migrations` row, restart the worker, confirm `Init:Error` and the version in `kubectl logs -c schema-guard`; restore the row and confirm the pod proceeds without a resync; repeat for `warn` and for a wrong database URL (exit 2)
- [ ] 4.3 **(user)** Open the PR to `staging` from the chosen branch, get review, merge
- [ ] 4.4 After the first `latest` publish post-merge, confirm with `docker buildx imagetools inspect --raw` that the index is OCI, annotated with the staging SHA and lists both platforms; confirm `docker pull` on amd64 and arm64; confirm with read-only `kubectl get freight -n kargo-project-codeai` that the newest Freight carries the annotation and that a staging pod pulled it

## 5. k8s-gitops: Kargo gate and production values

- [ ] 5.1 Insert two `http` steps as the first steps of the promotion template in `apps/kargo/projects/codeai/stages/production.yaml`, both calling GitHub compare `production...${{ imageFrom("ghcr.io/code-dot-org/cdo-rails").Annotations["org.opencontainers.image.revision"] }}` with a 5-minute retry timeout: `freight-has-revision` (success `response.status == 200`, failure `response.status == 404 || response.status == 422`) and `revision-in-legacy-production` (success `response.status == 200 && response.body.ahead_by == 0`, failure `response.status == 200 && response.body.ahead_by > 0`); Kargo 1.9.5 has no custom failure text, so the step names are the diagnostic; add a header comment explaining both steps and linking to the runbook
- [ ] 5.2 Set `schemaGuard: {enabled: true, mode: enforce}` in `apps/codeai/envTypes/production.values.yaml` and `schemaGuard: {enabled: true, mode: warn}` in `staging.values.yaml` and `test.values.yaml`, each with a comment stating why (production never starts in `warn`; staging moves to `enforce` after one `warn` rollout; test is reviewed after measuring how often it runs ahead)
- [ ] 5.3 Add `apps/kargo/projects/codeai/README.md` describing the Stages, the production gate and linking to the runbook; confirm the Application's directory include still selects only `application.yaml`

## 6. k8s-gitops: runbook

- [ ] 6.1 Write `docs/production-promotion.md` per the runbook spec: the rule and the two gates, pre-promotion checks, post-promotion checks (pods `Running`, the `schema-guard` log, whatever application-level health signal exists at the time), rollout and rollback timing with the 2100-second grace period, rollback procedure (review of the migrations added between the two commits for destructive changes, every time), failure signatures in Kargo (which gate step failed and what its HTTP status means, with the compare URL to run by hand), kubectl and Argo, the hotfix caveat, emergency `warn` use, what a Freight blocked by the guard in staging or test means for its verification, and the NetworkPolicy allowances a future default-deny policy must keep

## 7. Rollout

- [ ] 7.1 **(user)** Commit and push the k8s-gitops changes; refresh the `kargo-project-codeai` Argo Application, which owns the Stage, and sync if it has not moved; confirm with read-only `kubectl get stage production -n kargo-project-codeai -o yaml` that both steps are present
- [ ] 7.2 **(user)** After the first image carrying the version list and check script rolls through staging and test in `warn` mode, confirm with read-only `kubectl logs -c schema-guard` in both namespaces that the counts compare cleanly, then set staging to `enforce`
- [ ] 7.3 Observe the first staging rollout the guard blocks during a legacy build (`Init:Error` naming the version, old pod serving, Stage not Healthy, Freight unverified in staging until the legacy build migrates) and record it in the runbook as the reference failure signature
- [ ] 7.4 **(user)** Rehearse the Kargo steps on `levelbuilder` before production is enabled: temporarily add both steps, promote an unannotated Freight (expect failure at `freight-has-revision`, HTTP 404), the newest Freight (expect failure at `revision-in-legacy-production`, HTTP 200) and the Freight whose annotation equals `git merge-base production staging` (expect both steps to pass), record the three Promotion statuses in the runbook as reference signatures, then remove the steps
- [ ] 7.5 **(user)** After the chart reaches the `production` branch via DTP and the production deployment has been enabled with `branch: production`, perform the first production promotion following the runbook with the guard in `enforce` and capture the `schema-guard` log; if the pod blocks, read the missing versions and decide with that evidence rather than switching to `warn` by default
- [ ] 7.6 **(user)** Drill once in production with `schemaGuard.extraVersions: "20991231000000"` and confirm `Init:Error`, old pods untouched and Argo `Degraded`; remove the drill value
- [ ] 7.7 Review two weeks of test `warn` logs (how often test pods started ahead of their database; each gap's duration is inferred from the next robo-DTT time, since the init container logs once per start); decide between `enforce` for test and a follow-up change that selects Freight from the legacy `test` branch, and open that follow-up if chosen
- [ ] 7.8 Record the first promotion's date and Freight in the runbook's history section
