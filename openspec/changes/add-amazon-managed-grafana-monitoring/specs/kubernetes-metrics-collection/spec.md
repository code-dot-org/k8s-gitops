## ADDED Requirements

### Requirement: Collect the v1 infrastructure metric set

The system SHALL collect node readiness/allocatable capacity, workload desired/ready counts, pod state/restarts, container CPU/memory, and basic collection-health metrics for `codeai-k8s`. Sources SHALL be kube-state-metrics, kubelet/cAdvisor, and scrape/collector self-metrics. Collection SHALL start at 60-second intervals with an explicit metric allowlist and cluster/source labels. V1 SHALL NOT require node-exporter, application endpoints, logs, or traces.

#### Scenario: Verify cluster coverage

- **WHEN** monitoring is enabled on a cluster containing frontend-tainted and system nodes
- **THEN** Amazon Managed Service for Prometheus (AMP) queries contain the expected nodes and workloads with the configured cluster identity
- **AND** required container CPU/memory and workload signals are available without treating missing collection as healthy

### Requirement: Reuse AMP with scoped identity

The collector SHALL use the confirmed infrastructure-managed AMP destination, authenticated TLS, and workload IAM credentials with remote-write access scoped to that workspace. Kubernetes access SHALL be limited to required discovery and metric reads. Grafana administrative credentials and static AWS keys SHALL NOT be required in the cluster. The rollout SHALL document its cost estimate and agreed incremental spending limit before ingestion.

Workspace ARNs and endpoints SHALL be resolved from the infrastructure owner's OpenTofu outputs and passed through generated GitOps values. Hand-maintained monitoring configuration SHALL NOT require literal workspace ARNs or IDs. Account and OIDC identity SHALL continue to use the existing OpenTofu-generated cluster values.

#### Scenario: Regenerate the workspace configuration

- **WHEN** cluster configuration is regenerated from the existing observability state
- **THEN** the AMP ARN, remote-write endpoint, and derived region follow that state's outputs
- **AND** no operator must copy resource identifiers into monitoring configuration
- **AND** the generated values do not enable monitoring or publish credentials

#### Scenario: Validate destination and permissions

- **WHEN** the enabled collector configuration is validated
- **THEN** a missing workspace destination or region is reported as an error
- **AND** the writer identity grants no workspace administration or writes to unrelated workspaces
- **AND** no replacement workspace is created

### Requirement: Use one collector with bounded ephemeral buffering

V1 SHALL use one Alloy Deployment replica, a Recreate update strategy, and no clustering/autoscaling or operator. It SHALL avoid scraping targets already owned by another collection path. The collector SHALL have explicit resource limits, an ephemeral write-ahead log (WAL) with finite retention and storage limits, and observable delivery errors/freshness. Persistent storage and uninterrupted delivery SHALL NOT be v1 requirements; pod replacement may lose unsent samples.

#### Scenario: Replace the collector pod

- **WHEN** a controlled collector update or restart occurs
- **THEN** fresh collection resumes after the collector becomes operational
- **AND** the observed gap and possible loss of buffered samples are documented
- **AND** the deployment does not deliberately overlap two scrape owners during an update

### Requirement: Preserve independent application observability

The deployment SHALL require no edits or release in `code-dot-org`, no application telemetry overrides in GitOps, and no instrumentation injection. Existing Rails/worker collectors, request/span metrics, scheduled reporters, and Sentry routing SHALL remain independently managed. Missing application-level signals SHALL NOT block v1 acceptance.

#### Scenario: Add cluster monitoring

- **WHEN** the monitoring application is deployed
- **THEN** cluster metrics arrive without an application release or telemetry reconfiguration
- **AND** existing application inputs, destinations, and behavior are preserved

### Requirement: Keep the monitoring lifecycle independent

The application SHALL be managed by ArgoCD outside the infra bootstrap group with pinned chart dependencies. Monitoring availability SHALL NOT gate application startup. Rollback/removal SHALL preserve existing shared telemetry stores and application observability.

#### Scenario: Disable monitoring

- **WHEN** the monitoring application is disabled or removed
- **THEN** its new collection stops without preventing application operation
- **AND** existing Amazon Managed Grafana (AMG)/AMP resources and stored metrics remain under their current owners
