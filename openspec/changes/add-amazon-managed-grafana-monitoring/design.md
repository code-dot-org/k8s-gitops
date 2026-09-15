## Context

`codeai-k8s` is an EKS Auto Mode cluster in `us-east-1`. ArgoCD reads infrastructure and application configuration from this repository. The root ApplicationSet discovers `apps/*/application.yaml` and waits for the `infra` bootstrap group before starting other applications. Frontend nodes carry a scheduling taint.

The user has confirmed an existing Amazon Managed Grafana (AMG) workspace and excluded Grafana Cloud on budget grounds. The adjacent `infrastructure/observability/opentofu/environments/prod/main.tf` composes existing AMG and Amazon Managed Service for Prometheus (AMP) modules. The Grafana module owns SAML, workspace IAM/query policies, its OpenTofu service account/token, data sources, folders, dashboards, alerts, and the root notification policy. These are code-confirmed definitions; deployed state, ingestion, effective permissions, and incremental capacity/budget have not been verified live.

`infrastructure/observability/dashboards/grafana` builds dashboards and alert groups from TypeScript using the Grafana Foundation SDK. `yarn build` writes `dist/`; the production OpenTofu environment's `dashboards` symlink points there. Stable data-source UIDs are shared between HCL and `src/lib/config.ts`. Existing views include Rack/API, authentication, and CloudWatch ActiveJob metrics. Observability is currently commented out of both OpenTofu CI workspace matrices, and those workflows do not build the TypeScript package. Comments describing a CI build do not establish a working deployment pipeline.

In the adjacent `code-dot-org` repository, Dashboard exports OpenTelemetry traces. The Chef collector converts Rack spans into request metrics before sampling traces and sends those metrics to AMP using SigV4. That collector is a host service; no Kubernetes equivalent was found in the checked manifests. Its host-oriented labels need adaptation when a collector receives telemetry from multiple pods.

`dashboard/app/jobs/concerns/active_job_metrics.rb` already emits queue, failure, wait, and execution metrics to the `code-dot-org/ActiveJob` CloudWatch namespace. `bin/cron/report_activejob_metrics` refreshes overall queue metrics through Chef cron. The worker-count implementation inspects local processes, and the existing Grafana dashboard includes EC2 daemon CPU/memory panels. These need Kubernetes-specific validation and adaptation; the existing dashboard alone does not prove Kubernetes coverage.

The platform team owns collection and AWS access. Application owners define useful request and worker signals. The AMG administrator supplies workspace access, and the budget owner sets acceptable incremental spend.

## Goals / Non-Goals

**Goals:**

- Provide cluster, node, workload, application, and selected log visibility in the existing AMG workspace.
- Use Prometheus-compatible metrics and OpenTelemetry application telemetry with a reproducible GitOps deployment.
- Reuse AMP and existing application instrumentation where confirmed; preserve Sentry behavior.
- Keep application startup independent of collector or backend availability.
- Measure coverage, delivery reliability, alert usefulness, and incremental cost before production expansion.

**Non-Goals:**

- Grafana Cloud subscriptions or features that require its Kubernetes Monitoring application.
- A new AMG workspace, migration of existing shared workspaces, or teardown of existing telemetry stores.
- Operating a full local Prometheus database, Loki, Tempo, or a Grafana server.
- Changing authentication for existing AMG users or replacing Sentry.
- Initial deployment of eBPF instrumentation, profiling, energy metrics, or comprehensive AWS cost accounting.

## Decisions

### 1. Use AMG with AMP and CloudWatch

AMG queries metrics in AMP and selected logs in CloudWatch. Use the AMP data-source plugin appropriate to the installed AMG version, with the workspace IAM role providing query access. Collectors receive separate, resource-scoped writer roles. Prefer existing OIDC service-account IAM patterns; do not introduce static AWS keys.

Reuse the workspaces already owned by the infrastructure repository. The production environment exports AMG ID/endpoint and AMP ID/ARN/remote-write URL. Publish only the needed nonsecret destination identifiers and region into cluster configuration; keep Grafana provider tokens and OpenTofu state out of Kubernetes. Verify that the Chef destination and these AMP outputs agree before enabling ingestion. An unexpected missing or unsuitable workspace is an inventory discrepancy to resolve with its owner, not a trigger to create a replacement automatically.

The configured AMG version is `12.4`, while the HCL and TypeScript still specify the core `prometheus` data-source type with SigV4 (UID `effqou9gjnlkwa`). AWS documents that AMG 12 removes core-plugin SigV4 and migrates those data sources to the AMP plugin. Inspect the live version, plugin type, and migration state; reconcile HCL and SDK references together before a shared apply, preserving the UID and existing consumers. The CloudWatch source already exists as `managed-cloudwatch`. This is a compatibility preflight, not evidence of a live outage.

This follows the data-store separation in AWS's EKS monitoring reference solution. That solution is a reference for compatible metrics, rules, and dashboards, not a deployment template to apply wholesale to this Auto Mode cluster.

Alternative: a local Prometheus server queried by AMG. This adds storage, availability, and private connectivity work. Revisit it only if AMP cost is unacceptable or local query/rule evaluation during a backend outage becomes a requirement.

### 2. Use Alloy for Kubernetes collection and validate application consolidation

**Decision:** Use Grafana Alloy as the default collector for new Kubernetes infrastructure metrics. The expected benefit is less configuration to assemble and maintain through the `grafana/k8s-monitoring` chart, together with built-in coordination of Prometheus scraping across replicas. Consolidating the Rails telemetry pipeline on Alloy remains subject to the application validation below.

Alloy is an open-source distribution of the OpenTelemetry Collector with additional Prometheus components. The alternative considered here is the upstream OpenTelemetry Collector Contrib distribution. Both support our telemetry architecture; AMG does not require Alloy, and existing dashboards depend on metric names, labels, and units rather than the collector distribution. [Alloy overview](https://grafana.com/docs/alloy/latest/introduction/)

#### Rationale and tradeoffs

| Concern | Alloy | Upstream OpenTelemetry Collector Contrib |
| --- | --- | --- |
| Kubernetes setup | The selected monitoring chart generates collection configuration and can deploy supporting exporters such as kube-state-metrics and node exporter. | We would assemble the Collector configuration and supporting exporter deployments for the same coverage. |
| Scraping across replicas | Opt-in clustering assigns scrape targets between peers. | Requires explicit target sharding or a component such as the OpenTelemetry Operator's Target Allocator. |
| Existing Rails pipeline | The chosen Alloy component configuration requires adapting and revalidating the current pipeline. | Can reuse more of the existing Collector YAML, with Kubernetes-specific identity and deployment changes. |
| AMP delivery | Supports AWS request signing, retries, and disk buffering. | Supports equivalent delivery capabilities; these are requirements for either choice. |

The chart integration and scrape coordination are the main reasons to select Alloy. The [Kubernetes monitoring chart](https://github.com/grafana/k8s-monitoring-helm) packages exporters and collection configuration, while [Alloy clustering](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.scrape/#clustering) distributes scrape ownership. The upstream Collector also supports distributed scraping through [sharding or a Target Allocator](https://opentelemetry.io/docs/collector/scaling/). Neither approach removes the need to validate coverage and duplicate collection during scaling.

The accepted cost is learning and maintaining Alloy's component configuration and the monitoring chart's generated resources alongside our existing Collector YAML. Reduced Kubernetes configuration work is an expected operational benefit to verify during the pilot, not a measured cost or performance advantage. Both [Alloy remote write](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.remote_write/) and the upstream Collector's [remote-write exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/prometheusremotewriteexporter/README.md) and [AWS signing extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/sigv4authextension/README.md) provide the relevant AMP delivery capabilities. The distribution choice does not by itself reduce AMP ingestion charges or settle CloudWatch log collection.

#### Application pipeline validation

The existing `code-dot-org/cookbooks/cdo-otel-collector/templates/otel-config.yaml.erb` already receives application telemetry, generates Rack metrics before trace sampling, writes to AMP, and exports sampled traces to Sentry. Reuse that behavior as the reference. Before enabling an Alloy application pipeline, compare known request/error counts, histogram units and buckets, source labels, sampling order, Sentry delivery, and resource use with the existing pipeline. Confirm that consolidation reduces maintenance enough to justify adapting its configuration.

If the selected Alloy release cannot preserve those behaviors or introduces disproportionate migration work, retain upstream Collector Contrib for Kubernetes application telemetry and keep Alloy responsible for infrastructure scraping. That fallback adds a second collector configuration to operate and must have explicit ownership without duplicate ingestion. Revisit the infrastructure collector choice if the pinned chart and clustering provide insufficient benefit over a Contrib deployment. This decision does not migrate the existing Chef-managed host collectors.

#### Deployment constraints

Use a pinned `grafana/k8s-monitoring` chart through a local wrapper, configured explicitly for AMP and with Grafana Cloud integrations disabled. Verify the selected release's values schema, dependencies, operator CRDs, Helm hooks, and ArgoCD behavior before deployment. No chart upgrade is automatic.

Enable Kubernetes metrics and the backing services needed by the selected dashboards: kube-state-metrics, node metrics, and kubelet/cAdvisor collection. Reuse compatible exporters discovered during inventory to avoid duplicate scraping. Confirm which EKS control-plane metrics are exposed and document unavailable signals.

Metric collectors coordinate scrape ownership. Node-level exporters receive the tolerations needed to cover frontend and system nodes. Application OTLP receivers have an internal Service and explicit resource limits; production placement and replica count follow the observed traffic and availability target. Stateful span aggregation needs distinct collector-series identity when multiple replicas export to AMP.

Alternative: AMP managed scrapers. They reduce collector maintenance but add service charges and do not replace the application OTLP pipeline. Compare costs during inventory and retain Alloy as the default unless measured requirements favor managed scraping.

### 3. Keep monitoring outside the bootstrap gate

Add `apps/monitoring/application.yaml`, without the `code.org/bootstrap-group: infra` label. Use `apps/monitoring/chart/` for Kubernetes resources. Existing root discovery handles the application; changing the root ApplicationSet is not expected.

Keep the three repositories' responsibilities explicit:

| Repository | Ownership |
| --- | --- |
| `k8s-gitops` | Argo application, namespace, collectors/exporters, service accounts, cluster IAM integration, and deployment values |
| `infrastructure/observability` | Shared AMG/AMP stores, workspace query IAM, CloudWatch log-group lifecycle, AMP rule namespaces, dashboard/alert source and provisioning, and Grafana notification routing |
| `code-dot-org` | Rails/worker instrumentation and any required Helm/Kustomize application templates |

Use the existing cluster OIDC/service-account IAM pattern for scoped collector writers, referencing the AMP ARN from infrastructure outputs. Record one owner for each IAM resource; do not manage the same resource in both OpenTofu and Crossplane. Owned log groups and AMP rule namespaces belong alongside the existing infrastructure modules and survive Argo application removal.

Extend `observability/dashboards/grafana/src/` and its `src/index.ts` registry, then consume the generated JSON through the existing Grafana module. New dashboard resources go in `dashboards.tf`; new alert groups use the existing `alerts.tf` loader and feature-to-folder mapping. Keep new data transformations in `locals.tf` per infrastructure repository guidance. Reuse the module's provider authentication and token rotation; do not introduce an additional Grafana API reconciler or provisioner in `apps/monitoring/`. Review the whole shared OpenTofu plan for unrelated changes before applying it.

Run dependency installation from the lockfile, `yarn typecheck`, and `yarn build` before OpenTofu validation/plan so the symlink resolves complete artifacts. Use a documented manual build/plan/apply initially, unless CI is deliberately enabled with dashboard-source path triggers, generated artifacts available at plan and apply, required credentials, and separate plan/apply environments. Never assume merge-to-main already deploys observability. Grafana provisioning remains independent of application boot.

Application telemetry settings belong in `apps/codeai/envTypes/` and deployment values. The adjacent chart already supports `extraEnv`; worker settings use `activeJobWorker.extraEnv`. Any required application template changes must maintain the relevant Helm/Kustomize parity.

### 4. Preserve application metric accuracy and source identity

Adapt the existing Rack span-metrics pipeline for Kubernetes, using Alloy after the application validation in decision 2 or the documented upstream Collector fallback. Attribute telemetry to the originating service, environment, cluster, namespace, pod, and service instance, with a documented mapping from OpenTelemetry attributes to query labels. Do not substitute the gateway pod's identity for application identity. Use Kubernetes metadata enrichment and explicit resource attributes where needed.

Generate request metrics from the full received Rack span stream before trace sampling. Existing consumers query `rack_calls_total` and `rack_duration_milliseconds_bucket`; preserve names, millisecond units, buckets, and bounded dimensions unless a coordinated migration is documented. Rack/Auth queries currently select `process_pid="", host!=""`, and production alerts also match `environment="production"`. Kubernetes series could be excluded or unintentionally included by those selectors. Define an explicit cluster/runtime scope, adapt source selectors and drilldown links, and validate legacy and Kubernetes traffic together before enabling application ingestion. Preserve legacy alert scope, using an explicit legacy selector where necessary; do not fabricate a gateway host label to satisfy old queries. Verify that a request is counted once and collector scaling does not merge independent counters. Preserve the configured Sentry trace path and validate compatibility with the pinned collector.

Reuse CloudWatch ActiveJob signals and the existing dashboard before adding metrics. Check Kubernetes worker `PutMetricData` access, backend compatibility, scheduled queue reporting, and dimensions. Environment-only dimensions can merge independent deployments, while a queue shared with EC2 intentionally represents both runtimes. Document queue versus worker scope and avoid duplicate scheduled reporters for the same queue. Replace local-process-derived worker totals and EC2-only resource panels with correctly scoped Kubernetes signals. Add only missing backlog, age, failure, or processing-duration coverage; there is no requirement to duplicate suitable CloudWatch signals into AMP. Keep database-backed measurements bounded in query cost and permissions. Telemetry failures must not prevent requests or jobs from completing.

### 5. Send selected logs and events to CloudWatch

Inventory current log shipping before adding agents. Use a pinned, AWS-supported CloudWatch log shipper compatible with Auto Mode for selected pod stdout/stderr logs, and a single active Kubernetes event collection path. Verify the concrete shipper and event-export mechanism during implementation; the metrics chart's log destination must not be assumed to support CloudWatch automatically.

Start with explicit infrastructure and staging namespace allowlists. Apply agreed redaction before export, preserve source metadata, and set finite retention on owned log groups. Keep event collection distinct from EKS audit/control-plane log settings. Do not enable broad Container Insights collection or change existing audit logging as a side effect.

Alternative: self-hosted Loki. CloudWatch integrates with the existing AWS workspace and avoids a new log storage service to operate.

### 6. Bound collection and verify delivery

Start infrastructure scraping at 60 seconds, with a metric allowlist derived from the dashboards and rules actually provisioned. Record the collection scope, estimated series/sample volume, log volume, retention, collector resources, and query assumptions in the rollout plan. The chosen allowlist must retain required recording-rule inputs.

Use remote-write buffering with an explicit storage path, capacity, and retry/retention window. Select persistent storage for critical buffers when restart survival is required. For each signal, document which restarts or node replacements can lose data; local node storage is not durable across node deletion. Monitor queue pressure, export errors, dropped data, and ingestion freshness.

Configure finite memory and disk use. Application exporters remain asynchronous and fail independently of application readiness. Restrict OTLP receiver access to intended workloads and use TLS for external delivery.

### 7. Provision useful dashboards and alerts

Add Kubernetes dashboard/alert builders to the existing TypeScript package and matching folders/resources to the Grafana module. Reuse Rack/Auth and ActiveJob components where their signal semantics fit; retain established UIDs and explicit source filters. Start Kubernetes views from versioned assets compatible with the collected metric names. Add required AMP recording-rule namespaces through the existing Prometheus OpenTofu module. Use AMG-managed alerts with one evaluation owner per alert, preserving unrelated rules.

Dashboards cover node resources, workload availability and restarts, request rate/errors/duration, worker queue health, collection health, and scoped log queries. Alerts include an owner, severity, runbook, and notification destination. Configure missing-data behavior and delays deliberately. `notifications.tf` owns the single root routing policy; extend it with a scoped Kubernetes child route. Contact points are manually created in AMG, with webhook URLs kept outside state. Confirm the designated test contact point and authorization to send test notifications; its current name `test` alone does not grant authorization. An administrator supplies any missing contact point before a plan referencing it is applied. Preserve other child routes and SAML settings. Add an external availability check or reuse an existing one so total loss of cluster telemetry is detectable.

## Risks / Trade-offs

- Declared resources differ from deployed state -> Verify infrastructure outputs, Chef destination, and live AMG/AMP configuration; confirm incremental budget before ingestion starts.
- AMG 12 plugin migration differs from HCL/SDK references -> Reconcile the existing data source and all managed consumer types without changing its UID before shared provisioning.
- Generated dashboards or provider credentials are unavailable at apply -> Build before planning, verify the service-account token lifecycle, and document the manual deployment path while observability CI remains disabled.
- Legacy selectors or host-based worker metrics misrepresent Kubernetes -> Validate mixed-runtime queries, scheduled reporters, worker totals, and alert scope before application rollout.
- Auto Mode host access and taints leave gaps -> Verify actual nodes and exporter targets, including frontend nodes, before declaring coverage complete.
- Chart operator hooks interfere with Argo deletion -> Render and inspect the selected chart and exercise install/removal in an isolated test environment.
- Shared collectors misattribute or duplicate application metrics -> Test with multiple pods and collectors; preserve producer identity and distinct aggregation writers.
- Full-span receipt consumes resources -> Measure app and collector overhead; generate request metrics before sampling and revisit direct metrics if full-span processing becomes too expensive.
- Buffer exhaustion or node replacement loses telemetry -> Define finite outage tolerance, use appropriate persistent storage, and alert on loss and stale data.
- Excessive labels or log volume increase charges -> Use bounded dimensions, namespace allowlists, finite retention, and a pilot usage report.
- AMG provisioning support varies by version -> Inventory the workspace and verify data-source and alert APIs before selecting provisioning assets.
- A collector outage hides the cluster -> Use missing-data alerts evaluated outside the cluster and an external availability check.

## Migration Plan

1. Verify the infrastructure repository's AMG/AMP outputs against live state, existing Chef ingestion, query plugins, notification contact points, token lifecycle, and current rules. Inventory EKS collection and IAM, resolve deployment inputs, and estimate incremental cost.
2. Prepare the monitoring chart and writer roles in GitOps; extend dashboard builders and OpenTofu in infrastructure, and application instrumentation only where needed. Resolve the AMG plugin compatibility check, build/typecheck dashboards, render manifests, and inspect the shared OpenTofu plan and deletion behavior.
3. Apply required AWS access/recording rules and AMG views using the documented infrastructure workflow, then deploy cluster metrics through ArgoCD. Verify freshness and node/workload coverage. Reconcile application selectors before Kubernetes application metrics start reaching shared stores.
4. Enable staging application telemetry and selected logs/events. Validate request counts, worker metrics, source attribution, filtering, and Sentry behavior.
5. Exercise collector restart and a bounded export interruption in the pilot environment. Test notifications using the designated test destination. Observe at least 24 hours of pilot usage and report extrapolated costs with traffic assumptions.
6. Expand to agreed production namespaces after reviewing the pilot against the budget and coverage criteria. Publish operations, upgrade, rotation, and removal instructions.

After pushing Argo-managed changes, refresh affected Applications and sync if they have not moved to the intended revision. If an app-of-apps bootstrap/destroy test is needed, use the repository's event and argo-trace logging lifecycle.

Rollback restores the previous Git configuration, disables new application telemetry settings, and stops new collection. Remove only dashboards, rules, and routing owned by this change when needed. Collector removal must preserve shared AMG/AMP workspaces, CloudWatch history, and unrelated Sentry configuration. Stored telemetry expires according to its configured retention.

## Open Questions

- Do the deployed AMG/AMP resources match the infrastructure outputs and configured AMG 12.4 version? Has the AMP plugin migration occurred, and can the existing provider token authenticate?
- Does the Chef AMP destination match the infrastructure-managed workspace, and does it have capacity/budget for cluster ingestion?
- Who runs the current manual observability build/plan/apply, or should its disabled CI path be enabled as part of rollout?
- What monthly incremental budget and metrics/log retention are acceptable? Which infrastructure and staging namespaces are in the initial log scope?
- Who receives alerts, which route is suitable for testing, and which existing external checks can be reused?
- What collection already runs in EKS, and what host-access, network, and storage constraints apply to its Auto Mode nodes?
- Which CloudWatch pod-log and event collectors satisfy the pinned-version and Auto Mode checks without duplicating existing shipping?
- Which queues are shared between EC2 and Kubernetes, which existing CloudWatch dimensions distinguish deployments, and what Kubernetes-safe worker-count and scheduled reporting paths are needed?

## Repository Evidence

Paths below are relative to the common parent of the three repositories; definitions were inspected without reading live state or secrets.

- `infrastructure/observability/opentofu/environments/prod/{main,variables,outputs}.tf`: composed AMG/AMP resources, configured version, and destination outputs.
- `infrastructure/observability/opentofu/modules/grafana/{main,dashboards,alerts,notifications}.tf`: provider identity, stable data sources, JSON loaders, and routing/contact-point ownership.
- `infrastructure/observability/opentofu/modules/prometheus/{main,outputs}.tf`: existing workspace and remote-write URL.
- `infrastructure/observability/dashboards/grafana/src/{index.ts,lib/config.ts,lib/datasources.ts}`: generated artifact registry and shared data-source references.
- `infrastructure/observability/dashboards/grafana/src/dashboards/backend/rails/`: Rack/Auth metric selectors and ActiveJob CloudWatch/EC2 panels.
- `infrastructure/.github/workflows/opentofu-{plan,apply}.yml`: observability excluded from the current workspace matrices; no dashboard build step.
- `code-dot-org/dashboard/app/jobs/concerns/active_job_metrics.rb` and `code-dot-org/bin/cron/report_activejob_metrics`: existing worker signals, environment dimensions, and host-process counting.

## References

- [AWS EKS monitoring architecture and costs](https://docs.aws.amazon.com/grafana/latest/userguide/solution-eks.html)
- [AMG 12 Prometheus SigV4 plugin migration](https://docs.aws.amazon.com/grafana/latest/userguide/prometheus-manually-adding.html)
- [Grafana Alloy and compatible backends](https://grafana.com/docs/alloy/latest/introduction/)
- [Alloy remote write, SigV4, and buffering](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.remote_write/)
- [Alloy span metrics and collector identity](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.connector.spanmetrics/)
- [OpenTelemetry collector scaling](https://opentelemetry.io/docs/collector/scaling/)
- [Prometheus alerting practices](https://prometheus.io/docs/practices/alerting/)
