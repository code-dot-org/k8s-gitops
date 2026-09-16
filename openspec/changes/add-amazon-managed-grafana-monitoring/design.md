## Context

`codeai-k8s` is an EKS Auto Mode cluster managed through ArgoCD. Root discovery already includes `apps/*/application.yaml`; the `infra` bootstrap group gates application startup. The new monitoring application must be outside that group.

`infrastructure/observability/opentofu/environments/prod` defines Amazon Managed Grafana (AMG), Amazon Managed Service for Prometheus (AMP), and their data-source connection. Its TypeScript dashboard package generates JSON consumed by OpenTofu. These definitions have been inspected in code; live access, configuration, and existing collection still need verification. Application observability in `code-dot-org` is a separate project.

## Goals / Non-Goals

**Current task:** write and validate the local implementation files using repository
definitions and OpenTofu references. Live AWS discovery, real infrastructure plans,
publication, deployment, and rollout verification are outside this task. They are
documented below for a later, separately authorized rollout and do not block the
local implementation.

**V1 goal:** Open one AMG dashboard and see current Kubernetes infrastructure health without changing the application or introducing another telemetry backend.

**Included:** node readiness and allocatable capacity, workload availability, pod state/restarts, container CPU/memory, and basic collection health.

**Deferred:** logs/events, new alerts/notification routes, recording rules, detailed host/control-plane diagnostics, application telemetry, high availability, persistent buffering, CI automation, and a formal production-promotion process. No Grafana Cloud, local Prometheus database, or additional AMG/AMP workspace.

## Decisions

### 1. Use one collector and a small chart composition

Add `apps/monitoring/application.yaml` and a local wrapper chart with pinned `grafana/alloy` and `prometheus-community/kube-state-metrics` dependencies. Reuse compatible existing exporters where discovered. Use the standalone Alloy chart rather than the broader `grafana/k8s-monitoring` bundle: this scope needs a few explicit scrape jobs and no operator, custom resources, or multi-signal deployment machinery.

Run Alloy as a single-replica Deployment with a `Recreate` update strategy and clustering/autoscaling disabled. This intentionally trades brief update gaps for a simple, single scrape owner. kube-state-metrics also runs as one instance with Recreate updates if this project installs it, avoiding overlapping exporter instances. Keep both components' services internal. Validate the selected chart versions and rendered configuration before deployment; bump the wrapper chart version for changes.

The [standalone Alloy chart](https://grafana.com/docs/alloy/latest/configure/kubernetes/) accepts explicit collector configuration, and its [values](https://github.com/grafana/alloy/blob/main/operations/helm/charts/alloy/values.yaml) support choosing the controller and replica count.

### 2. Retain Alloy with a narrower rationale

Alloy is an open-source OpenTelemetry Collector distribution with native Prometheus components. Choose it for the direct discovery, scraping, relabeling, and remote-write path to AMP. The upstream OpenTelemetry Collector Contrib remains a viable alternative and offers a configuration model already used by the application team. AMG does not require either distribution. [Alloy overview](https://grafana.com/docs/alloy/latest/introduction/)

The tradeoff is maintaining a small Alloy configuration for Kubernetes alongside independently owned application Collector configuration. Clustering and the broad monitoring bundle are not v1 benefits because this design does not use them. Both distributions can provide AWS request signing and buffered remote write; we are not claiming a cost or performance advantage. No Rails migration or collector comparison project is required for v1.

### 3. Collect only the dashboard's inputs

| Source | V1 signals |
| --- | --- |
| kube-state-metrics | Node readiness/allocatable capacity, workload desired/ready counts, pod phase, container restarts, and resource requests/limits |
| Kubelet/cAdvisor | Container CPU usage and memory working set, attributed to node/namespace/pod/container |
| Scrape results and Alloy self-metrics | Target health, sample freshness, and delivery errors/backlog |

Start at a 60-second scrape interval. Define the metric allowlist and dashboard queries together. Attach a stable cluster label and preserve applicable source labels; avoid copying arbitrary application labels. Discover and authenticate to kubelets through a verified path that reaches all expected nodes, including frontend-tainted nodes. Central scraping does not require a collector on every node. No node-exporter DaemonSet or privileged host mounts in v1.

Inventory existing targets first to avoid duplicate scraping. Missing kubelet access is a concrete prerequisite to resolve, not a reason to quietly show missing CPU/memory as healthy. Do not scrape application endpoints or generate request/span metrics.

### 4. Reuse backends and existing identity patterns

Use OpenTofu to resolve the AMP destination; do not manually configure workspace ARNs or IDs. `cluster-infra/monitoring-config.tf` reads `prometheus_workspace_arn` and `prometheus_remote_write_url` from the existing infrastructure observability state and derives the region from the ARN. The existing cluster-config publisher includes these as `amp` in `apps/infra/codeai-cluster-config.values.yaml`, which the monitoring Argo app already consumes. Cluster account and OIDC values also remain OpenTofu-generated. Only enablement and collection settings belong in the hand-maintained monitoring values file.

This follows the repository's existing remote-state-to-GitOps pattern. Generating cluster configuration now requires read access to the observability state snapshot; only selected non-secret outputs are published, and neither Argo nor Alloy gets state access. The existing GitHub publisher commits directly to `main` on apply. Publication is a deployment-related operation and remains on hold; do not edit the generated file by hand or apply merely to discover an ARN.

Grant the collector `aps:RemoteWrite` for that workspace through the existing cluster workload IAM pattern. Use scoped Kubernetes read permissions, authenticated TLS, and no static AWS keys. Keep Grafana administrative credentials out of the cluster.

Reuse the existing AMG data source and query role. Check the live plugin before provisioning: the repo targets AMG 12.4 but declares the core Prometheus plugin with SigV4, while AWS documents a migration to the AMP plugin starting with AMG 12. Make only a necessary compatibility adjustment, preserving identifiers and existing consumers; a wider workspace migration is separate work. [AWS plugin migration](https://docs.aws.amazon.com/grafana/latest/userguide/prometheus-manually-adding.html)

### 5. Use bounded ephemeral storage and accept gaps

Set CPU/memory and ephemeral-storage requests/limits. Mount Alloy's write-ahead log (WAL), its disk buffer for unsent metrics, on a size-limited `emptyDir` and configure finite retention. Do not provision persistent volumes. The WAL may retain data across a container restart within the same pod, but pod replacement loses unsent data. Outages or exhausted storage can cause missing samples; v1 offers no lossless-delivery or availability guarantee. [Alloy buffering](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.remote_write/)

Expose freshness and delivery health in the dashboard and document how to inspect collector logs. Collector readiness alone is not proof that AMP is receiving data. No new paging or external monitoring-loss check is part of v1.

### 6. Add one dashboard through the existing owner

Add one Kubernetes overview builder/registry entry in `infrastructure/observability/dashboards/grafana` and its resource in the Grafana OpenTofu module, with a stable dashboard identifier and an appropriate managed folder. Query raw metrics directly; no new AMP recording-rule namespaces, alert groups, or notification policies.

Provide node readiness/capacity, workload availability, pod status/restarts, container CPU/memory, and collection-health sections. Use the cluster label throughout and namespace/pod filters where applicable. Show missing/stale data explicitly. Container usage and node allocatable capacity must be labeled distinctly; v1 does not promise detailed host CPU, disk, or network diagnostics.

Use the existing manual process: install dependencies from the lockfile, run `yarn typecheck` and `yarn build`, review the shared OpenTofu plan, then apply. Observability is currently excluded from the CI workspace matrices; enabling CI and redesigning token rotation are separate improvements. Reuse existing authentication and verify it works.

### 7. Keep application observability independent

Only `k8s-gitops` and the existing infrastructure dashboard owner need implementation changes. No edits, release dependency, instrumentation injection, or application telemetry overrides in `code-dot-org` or `apps/codeai/`. Preserve existing Rails/worker collectors, Sentry routing, dashboards, and alerts. Missing request/queue signals are outside v1; worker pods are visible through ordinary Kubernetes resource and availability metrics.

## Deferred Deployment Inputs

Resolve during a separately authorized rollout, before live ingestion. These are
not inputs the user must provide to write or validate the local files:

1. Existing AMP/AMG identity, working query/provisioning access, and the collector's workload IAM path.
2. Existing collection and authenticated kubelet access on all expected nodes.
3. A rough ingestion/compute cost estimate and the user's acceptable incremental spending limit.

Log retention, alert recipients, queue topology, CI credentials, and high-availability targets are not v1 questions. Existing AMP retention remains unchanged.

## Future Rollout and Acceptance

This section describes operational acceptance after a separately authorized
deployment. Local implementation completion is based on code review and offline
validation; it does not claim these live checks have run.

1. Render/validate the chart and Alloy configuration; build the dashboard and inspect the shared OpenTofu plan. Confirm the application boundary and absence of deferred components.
2. Apply the reviewed `cluster-infra` plan to publish the generated AMP values to `main` before merging the monitoring application. Provision the dashboard through the separate infrastructure OpenTofu workflow. The monitoring app values enable Alloy and the bundled kube-state-metrics exporter, so merging the approved PR to `main` lets app-of-apps discover monitoring and ArgoCD sync it automatically. No second enablement change is required. A dashboard apply can also follow collector deployment; it is not required for ingestion.
3. Compare dashboard nodes/workloads against Kubernetes inventory, including frontend nodes. Confirm changing CPU/memory data, correctly scoped queries, and current sample timestamps across several scrape intervals.
4. Perform one controlled collector restart/update. Verify fresh collection resumes and document any gap. Check resource usage, sample rate/series volume, and existing dashboard compatibility; report an initial cost estimate with its assumptions.
5. Document the dashboard URL, ownership, known limitations, and rollback. V1 is complete after these checks; no mandatory 24-hour soak, notification test, backend fault-injection suite, or staged application promotion is required.

Rollback disables or reverts only the monitoring application and its owned dashboard as needed. Application operation, shared stores, and existing observability must remain intact. Validate that boundary without destroying app-of-apps; any separately requested bootstrap/destroy exercise follows the repository's logging procedure.

## Risks and Follow-ups

- A single collector and ephemeral storage allow gaps. Add redundancy or persistence only when the required reliability justifies them.
- Direct dashboard queries may become expensive at larger scale. Add recording rules based on measured query needs.
- V1 is for inspection, not automatic incident notification. Alerting, contact points, and monitoring-loss detection are a separate iteration.
- Metric volume can exceed the estimate. Keep the allowlist and interval explicit, review initial usage, and reduce scope or disable collection if the agreed budget is exceeded.
- Auto Mode access or shared data-source compatibility may block required panels. Resolve these targeted prerequisites; do not expand into application changes or a platform migration.

## Repository Evidence

- `infrastructure/observability/opentofu/environments/prod/{main,variables,outputs}.tf`: existing workspace definitions and outputs.
- `infrastructure/observability/opentofu/modules/grafana/{main,dashboards}.tf`: data source and dashboard provisioning.
- `infrastructure/observability/dashboards/grafana/src/index.ts`: dashboard build registry.
- `infrastructure/.github/workflows/opentofu-{plan,apply}.yml`: observability excluded from current CI.
