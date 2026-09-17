# Implementation checkpoint — 2026-09-16

## State

Local implementation is complete on `nicklathe/k8s-observability` (k8s-gitops)
and `nicklathe/k8s-grafana` (infrastructure). Nothing was committed, pushed,
applied to AWS, or deployed to Kubernetes by the agent. The app values enable
the collector and bundled exporter for deployment when the approved PR merges
to `main`. The standalone chart defaults remain disabled. AMP settings resolve
from existing OpenTofu outputs through the cluster-values generator; publish
those generated values before merging the monitoring application.

The current task is writing and validating local files. Repository definitions
and OpenTofu references provide the implementation inputs; no AWS identity,
workspace inventory, scraper inventory, or EKS details are required from the user
to finish this work. Live discovery and operational verification belong to a
separately authorized rollout. Do not run AWS commands, live plans, applies,
pushes, merges, or Argo refreshes/syncs for the current task.

Completed local tasks: 2.1–2.4, 3.1–3.2, 4.1, 4.5 (8/8).
The full lifecycle checklist is 8/14; the remaining six tasks are explicitly
deferred rollout work. They have not been performed or marked complete.

## Local evidence

- Helm lint passes for the new wrapper chart. Dependencies are pinned, locked,
  and vendored: Alloy chart 1.12.1 / binary 1.19.2; kube-state-metrics chart 8.5.0 /
  binary 2.20.0.
- One-off local rendering checks passed for disabled, enabled, and
  existing-exporter configurations, including checks for missing/mismatched AMP
  inputs, HTTPS, IAM scope, read permissions, single-replica Recreate deployments,
  resource/storage bounds, and absence of CRDs/PVCs/host access.
- The matching Alloy 1.19.2 binary accepts the rendered configuration with
  `alloy validate`. The validation destination is fictitious and local only.
- After the OpenTofu handoff correction, two isolated OpenTofu tests pass using
  synthetic local state and the built-in provider only. They verify that changing
  the workspace ARN/endpoint and region changes the generated `amp` values. The
  test overrides the S3 backend with a local file and has no managed resources or
  AWS/GitHub providers. No live state or AWS API was accessed.
- Helm/Alloy validation also passes with synthetic cluster metadata in a different
  account/region from the checked-in generated file. Monitoring's maintained
  values no longer override generated AMP settings, and missing AMP region now
  fails validation. Wrapper chart version is 0.1.1.
- Dashboard dependency installation succeeds using Yarn 4.9.2 and the existing
  immutable lockfile. Type checking and generation pass for all 13 dashboard
  JSON files and the three existing alert-group files. Dependencies and shared
  builder/data-source code are unchanged.
- OpenTofu `validate` succeeds for a temporary copy of the whole prod
  configuration with backend initialization disabled and generated dashboards.
  The existing lockfile lacked some unpacked checksums for Darwin ARM64;
  initialization added those in the temporary copy without changing provider
  versions. No provider lockfile change was made in infrastructure.
- New OpenTofu file formatting, repository whitespace checks, and strict OpenSpec
  validation pass.
- Scope review: the monitoring chart owns only its collector/exporter, services,
  config, RBAC, and dedicated IAM role/policy. Disabling it renders no resources;
  no AMP/AMG workspace or storage resource is owned or destroyed by this chart.
  Infrastructure adds only one dashboard and its folder. No code-dot-org changes,
  application overrides, alerts, recording rules, or CI changes were made.

Builds/provider validation used a temporary copy to keep generated files,
dependencies, platform checksums, and credentials out of the infrastructure diff.
The three final infrastructure source files match that validated copy.

## Deferred rollout verification

The following is a future runbook, not missing input for the current file changes.

| Tasks | Future work |
| --- | --- |
| 1.1 | Verify AMG query/provisioning access and deployed-plugin compatibility; review live OpenTofu plans and the generated handoff. Manual ARN/ID collection is not required. |
| 1.2 | Inventory existing collectors/exporters/AMP scrapers and every node, including frontend nodes; select exporter reuse or installation; verify IAM and kubelet TLS; refine capacity/cost scenarios |
| 1.3 | Agree an incremental monthly spending limit before ingestion; scenario estimates are in `apps/monitoring/README.md` |
| 4.2–4.4 | Reviewed apply, Git/Argo rollout, dashboard verification, controlled restart, measured resources/volume/cost |

Local validation does not claim a measured node count, metric coverage, actual
cost, restart recovery, or live dashboard compatibility. Those checks remain
unperformed and do not block review of the completed local implementation.

The rollout/rollback commands, expected dashboard URL (explicitly unverified),
ownership, resource/WAL limitations, and separate follow-ups are documented in
[`apps/monitoring/README.md`](../../../apps/monitoring/README.md).
