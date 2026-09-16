## Why

`codeai-k8s` needs a basic view of cluster and workload health. The adjacent `infrastructure/observability` repository already defines Amazon Managed Grafana (AMG) for dashboards and Amazon Managed Service for Prometheus (AMP) for storing and querying metrics. Reuse these services for a small, metrics-only first iteration.

The v1 outcome is one Kubernetes overview dashboard showing node readiness/capacity, workload availability, pod restarts, container CPU/memory, and collection health. It must deploy independently of the application observability project.

The current task is to write and validate local implementation files. Live AWS
discovery, plans against real state, publication, deployment, and operational
verification are deferred to a separately authorized rollout. They are not
prerequisites for completing these code changes.

## What Changes

- Add one ArgoCD-managed monitoring application outside the infrastructure bootstrap gate, with pinned standalone Alloy and kube-state-metrics charts. Reuse a compatible existing kube-state-metrics deployment if one is present.
- Run one Alloy collector that scrapes the required Kubernetes metrics every 60 seconds and writes an explicit metric allowlist to the existing AMP workspace using scoped workload IAM credentials.
- Resolve the AMP ARN/endpoint from infrastructure's existing OpenTofu outputs and publish them through the existing generated cluster-values handoff; do not manually configure workspace ARNs or IDs.
- Add one versioned dashboard through the existing TypeScript/OpenTofu workflow in `infrastructure`, using direct Prometheus queries and the existing AMG data source.
- Validate collection coverage, dashboard queries, a collector restart, basic resource/ingestion usage, and the removal procedure. Accept collection gaps and loss of unsent metrics when the collector pod is replaced.

## Scope Boundary and Deferred Work

No changes or required release in `../code-dot-org`. Rails/worker instrumentation, existing collectors, application metrics, and Sentry routing remain independently managed. No application telemetry redirects through GitOps overrides.

Defer log/event shipping, new alerts and notification routes, recording rules, node-exporter and detailed host diagnostics, application telemetry, collector clustering/high availability, persistent buffering, and observability CI automation. These are separate follow-ups, not v1 acceptance dependencies. Grafana Cloud is excluded.

## Capabilities

### New Capabilities

- `kubernetes-metrics-collection`: Collect a bounded set of Kubernetes infrastructure metrics with one collector and send them to the existing AMP workspace independently of application deployments.
- `managed-grafana-observability`: Provision one Kubernetes overview dashboard in the existing AMG workspace through its current infrastructure owner.

### Modified Capabilities

None. No existing OpenSpec capability specifications are present.

## Impact

- `k8s-gitops`: monitoring application/chart, collector configuration, scoped workload IAM integration, and the OpenTofu-generated AMP configuration handoff.
- `infrastructure`: one dashboard builder/registration and OpenTofu dashboard resource; minimal data-source compatibility adjustments only if required for the existing workspace to work correctly.
- `code-dot-org`: no changes or release dependency.
- Operations: incremental AMP ingestion/query and collector costs; a single collector with ephemeral storage and no new alerting. Existing workspace retention, CloudWatch configuration, dashboards, and notification routing remain under their current owners.
