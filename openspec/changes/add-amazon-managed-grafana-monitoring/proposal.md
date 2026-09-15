## Why

The checked Kubernetes manifests do not provide a shared monitoring pipeline for `codeai-k8s`. The adjacent `infrastructure/observability` repository already defines Amazon Managed Grafana (AMG), Amazon Managed Service for Prometheus (AMP), data sources, dashboards, and alerts; `code-dot-org` supplies Rails instrumentation and CloudWatch worker metrics. Extend that existing system to Kubernetes. Grafana Cloud is outside the budget and is excluded from this change.

AMG provides dashboards and alerting; AMP stores and queries Prometheus metrics collected from the cluster and applications.

## What Changes

- Add an ArgoCD-managed monitoring application using Grafana Alloy for Prometheus-compatible Kubernetes metrics collection and export to AMP. Choose Alloy for its Kubernetes chart integration and built-in distribution of scrape targets across replicas; the design records the tradeoff against upstream OpenTelemetry Collector Contrib and the validation required before consolidating Rails telemetry on Alloy.
- Reuse the AMG and AMP workspaces managed by `infrastructure/observability/opentofu/environments/prod`, including existing data-source identifiers. Confirm deployed state and incremental ingestion budget before rollout; reconcile the configured AMG 12.4 version with the declared Prometheus plugin before reapplying shared resources.
- Adapt the existing Rails OpenTelemetry and request-metrics pipeline for Kubernetes, preserving metric generation before trace sampling and the existing Sentry integration.
- Collect selected Kubernetes pod logs and events into CloudWatch Logs with explicit scope and retention, and expose them through AMG.
- Extend the existing TypeScript dashboard/alert builders and OpenTofu resources in `infrastructure/observability`; retain one provisioning owner for shared Grafana configuration. Reuse Rack/Auth and CloudWatch ActiveJob views with explicit Kubernetes source selection and preserve existing alert behavior.
- Manage collectors and application deployment settings in GitOps. Validate node coverage, telemetry freshness, delivery failure behavior, and incremental cost during a staging pilot.
- Keep monitoring outside the infrastructure bootstrap gate so an unavailable monitoring backend cannot prevent application deployment.

## Capabilities

### New Capabilities

- `kubernetes-metrics-collection`: Discover and collect cluster, node, and workload metrics; send them to AMP with scoped IAM access and bounded buffering; deploy independently of application startup.
- `managed-grafana-observability`: Connect the existing AMG workspace to AWS telemetry stores and provision reproducible dashboards, rules, and alert routing.
- `application-telemetry`: Receive Kubernetes application OTLP, preserve source identity, derive accurate request metrics, and expose background-worker health.
- `kubernetes-log-collection`: Forward selected pod logs and Kubernetes events to CloudWatch with filtering, retention, and correlation metadata.

### Modified Capabilities

None. No existing OpenSpec capability specifications are present.

## Impact

- `k8s-gitops`: new `apps/monitoring/` application and chart, cluster-local service-account IAM integration using existing patterns, and environment-specific configuration under `apps/codeai/`.
- `infrastructure`: extend `observability/dashboards/grafana` builders and `observability/opentofu` resources for dashboards, rules, notification routing, and owned AWS telemetry stores. Reuse existing outputs and provider authentication. Observability is commented out of the current CI workspace matrices; document a reproducible manual deployment or enable the build/plan/apply path before relying on CI.
- `code-dot-org`: reuse `dashboard/engines/observability/`; extend application configuration or instrumentation where needed and maintain relevant Helm/Kustomize parity. The Chef collector remains the reference for existing request metrics.
- AWS: the existing AMG/AMP resources declared in the infrastructure repository, CloudWatch metrics/log groups, and scoped writer/query IAM permissions. Existing shared workspaces and stored telemetry survive collector removal.
- Dependencies: pinned Grafana Alloy and Kubernetes exporters; a supported CloudWatch log/event collection path. No Grafana Cloud subscription, self-hosted Grafana, Loki, or Tempo is required.
- Operations: additional metric ingestion, storage, queries, logs, networking, and collector compute must fit a documented budget. Confirm live workspace outputs, retention, log scope, and alert ownership. OpenTofu owns notification routing; contact points are currently created manually by the AMG administrator.
