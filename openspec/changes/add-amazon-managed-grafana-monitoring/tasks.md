## 1. Inventory and deployment inputs

- [ ] 1.1 [Agent] Verify the infrastructure-managed Amazon Managed Grafana (AMG) workspace against live state, including version, data-source UIDs/types, dashboards, alerts, query role, and OpenTofu service-account access; resolve the configured AMG 12.4/core-Prometheus SigV4 compatibility check without exposing secrets.
- [ ] 1.2 [Agent] Read the named nonsecret outputs for Amazon Managed Service for Prometheus (AMP) from `infrastructure/observability/opentofu/environments/prod`, compare them to Chef's destination, and verify live ingestion/capacity and rule ownership. Record AMP ARN, remote-write URL, and region for GitOps; resolve discrepancies without automatically creating another workspace.
- [ ] 1.3 [Agent] Inventory EKS nodes, taints, exporters, collectors, log shipping, IAM patterns, network access, storage classes, and available control-plane metrics; identify collection gaps and duplicates.
- [ ] 1.4 [Agent] Estimate incremental AMP, CloudWatch, collector, and network costs for the proposed collection scope; compare Alloy with an AMP managed scraper and record the collector choice.
- [ ] 1.5 [User] Supply missing AWS/AMG/OpenTofu access; resolve incremental budget, retention, pilot log scope, and alert owners using the inventory and estimate. Confirm the manual infrastructure deployment operator or supply credentials for a deliberately enabled CI workflow. Confirm the test recipient and authorize test notifications; create any missing AMG contact point before routing references it.
- [ ] 1.6 [Agent] Record the resolved deployment inputs and choose the compatible CloudWatch pod-log and event collection mechanisms before implementing live ingestion.

## 2. Shared metrics collection

- [ ] 2.1 [Agent] Add `apps/monitoring/application.yaml` and a wrapper chart with pinned dependencies, outside the `infra` bootstrap group and discoverable by the existing root ApplicationSet.
- [ ] 2.2 [Agent] Add scoped service-account writer permissions using the existing cluster OIDC/IAM pattern and the infrastructure-managed AMP ARN. Record one owner per IAM resource, keep shared stores in infrastructure OpenTofu, and keep Grafana administrative credentials out of the cluster.
- [ ] 2.3 [Agent] Configure Kubernetes metric collection and required exporters, with coordinated target ownership, cluster labels, a 60-second starting interval, and an allowlist covering selected dashboard/rule inputs.
- [ ] 2.4 [Agent] Configure node selectors/tolerations, collector resources and placement, buffer storage/capacity/retention, and restricted receiver access; document restart and node-replacement loss boundaries.
- [ ] 2.5 [Agent] Verify the pinned chart's CRDs, Alloy Operator resources, Helm hooks, and ArgoCD installation/removal behavior in an isolated test environment; resolve any stuck-finalizer or ordering issues.
- [ ] 2.6 [Agent] Render and validate enabled/disabled configurations, missing destination errors, IAM scope, metric destinations, and absence of Grafana Cloud dependencies; bump chart versions for changed packages.

## 3. Application telemetry

- [ ] 3.1 [Agent] Add an internal OTLP receiver and staging application/worker endpoint values, reusing the existing Rails OpenTelemetry instrumentation and separate worker environment settings.
- [ ] 3.2 [Agent] Implement source-resource enrichment and the OpenTelemetry-to-query-label mapping; verify attribution from two pods in different namespaces.
- [ ] 3.3 [Agent] Adapt Rack span metrics before trace sampling, preserve Sentry export, and validate `rack_calls_total` / `rack_duration_milliseconds_bucket` names, millisecond units, buckets, and bounded labels against existing Rack/Auth queries. Define explicit Kubernetes versus legacy source selection before ingestion.
- [ ] 3.4 [Agent] Configure distinct aggregation writers and verify known request/error counts with two collectors, sampled trace export, and a collector restart.
- [ ] 3.5 [Agent] Reuse `ActiveJobMetrics` and `code-dot-org/ActiveJob` CloudWatch signals: verify worker metric-write IAM, queue backend, dimensions, and scheduled reporting. Distinguish shared queues from independent deployments, avoid duplicate reporters, replace local-process worker totals with Kubernetes-safe signals, and add only missing coverage; preserve relevant Helm/Kustomize parity.
- [ ] 3.6 [Agent] Verify that unavailable telemetry collectors do not block requests, job execution, or readiness, and that controlled staging Sentry events still follow the configured integration.
- [ ] 3.7 [Agent] Verify mixed EC2/Kubernetes request queries and alert scope, including `host`/`process_pid` selectors and source-preserving drilldown links; verify worker totals across two pods and explicitly shared versus separate queue dimensions. Coordinate query changes in infrastructure before enabling application ingestion.

## 4. Selected CloudWatch logs and events

- [ ] 4.1 [Agent] Provision or reference selected CloudWatch groups with finite retention through `infrastructure/observability/opentofu`, referencing them from GitOps with separate ingestion/query permissions and lifecycle independent of collector removal.
- [ ] 4.2 [Agent] Deploy the selected pod-log shipper with namespace/workload selection, Auto Mode scheduling, source metadata, redaction, resource limits, and bounded buffering.
- [ ] 4.3 [Agent] Configure one active event-collection owner per scope and CloudWatch delivery with involved-object identity; preserve existing EKS audit/control-plane logging settings.
- [ ] 4.4 [Agent] Verify inclusion/exclusion and redaction with distinguishable test records, confirm no duplicate shipping path, and check that disabling collection preserves stored history.

## 5. AMG dashboards, recording rules, and alerts

- [ ] 5.1 [Agent] Extend the existing Foundation SDK builders and `src/index.ts` registry in `infrastructure/observability/dashboards/grafana`, plus Grafana folders/`dashboards.tf`/`alerts.tf` in OpenTofu. Reuse stable identifiers and the current provider/token lifecycle; keep new transforms in `locals.tf` and avoid a second provisioning owner in GitOps.
- [ ] 5.2 [Agent] Reconcile the existing AMP plugin and SDK data-source references with the live AMG version while preserving UID `effqou9gjnlkwa`; reuse CloudWatch UID `managed-cloudwatch`, verify query access, and test existing consumers as well as new Kubernetes views.
- [ ] 5.3 [Agent] Add required AMP recording-rule namespaces through the existing Prometheus OpenTofu module and validate rule input metrics against the collection allowlist.
- [ ] 5.4 [Agent] Add cluster/node, workload, collection-health, and log views; adapt existing Rack/Auth and ActiveJob views with source filters and visible missing-data states. Replace EC2-only worker resource panels for Kubernetes selections and preserve legacy dashboard identifiers and behavior.
- [ ] 5.5 [Agent] Extend the existing alert-group loader and single root notification policy with scoped Kubernetes alerts/routes, explicit missing-data behavior, severity, runbook, team, and confirmed contact points. Preserve existing routes and SAML; reuse or add an external availability check.
- [ ] 5.6 [Agent] Run lockfile-based dependency installation, `yarn typecheck`, and `yarn build` before OpenTofu validation/plan. Document a reproducible manual build/plan/apply, or deliberately enable observability CI with dashboard path triggers, complete generated artifacts, credentials, and separate plan/apply environments; verify the shared plan before rollout.
- [ ] 5.7 [Agent] Apply the reviewed provisioning plan and verify that a subsequent build/plan has no unintended dashboard/rule changes or duplicates; account for scheduled provider-token rotation and preserve unrelated AMG/AMP configuration.

## 6. Pilot rollout and acceptance

- [ ] 6.1 [Agent] Deploy the metrics baseline through the normal Git/ArgoCD workflow; after pushing, refresh affected Applications and sync if they have not moved to the intended revision.
- [ ] 6.2 [Agent] Verify expected node/workload coverage and ingestion freshness, including frontend nodes, and exercise dashboard queries before enabling staging application telemetry and selected logs/events.
- [ ] 6.3 [Agent] In the pilot environment, test bounded backend interruption and collector restart, compare recovery to the declared buffering policy, and verify failure/drop metrics and application independence.
- [ ] 6.4 [Agent] After test notifications are authorized in task 1.5, trigger and resolve a controlled alert through the designated route; verify an externally evaluated missing-telemetry condition and source/runbook details without invoking unrelated notification routes.
- [ ] 6.5 [Agent] Start a pilot observation window of at least 24 hours and record its collection settings, traffic assumptions, and metrics needed for the usage report.
- [ ] 6.6 [Agent] After the observation window, report coverage, errors/drops, collector overhead, series/sample volume, log volume, and projected incremental spend against the agreed budget.
- [ ] 6.7 [User] Resolve any remaining production log-scope, alert-routing, or budget decisions using the pilot results.
- [ ] 6.8 [Agent] Expand to the agreed production scope through GitOps and verify the same coverage, identity, ingestion, and alert acceptance criteria.

## 7. Operations and completion

- [ ] 7.1 [Agent] Document ownership across all three repositories, destination-output handoff, dashboard build/OpenTofu deployment, contact-point administration, upgrades, provider-token rotation, budget review, telemetry-loss diagnosis, and rollback/removal while preserving shared AWS stores.
- [ ] 7.2 [Agent] Verify application startup with monitoring unavailable and isolated monitoring removal; if app-of-apps lifecycle testing is required, follow the prescribed event/argo-trace logger start, raw-output reporting, and stop procedure.
- [ ] 7.3 [Agent] Complete relevant repository validation and Helm/Kustomize parity checks for changed files; mirror any necessary root app-tree structural changes in the mimic tree and record remaining limitations.
