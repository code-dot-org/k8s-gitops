## ADDED Requirements

### Requirement: Collect Kubernetes infrastructure metrics

The system SHALL collect the node, pod, container, and workload metrics required by its provisioned dashboards and recording rules from `codeai-k8s`, including kube-state-metrics and available kubelet/cAdvisor and node-exporter signals. The rollout SHALL document coverage and any unavailable managed-control-plane signals.

#### Scenario: Cover frontend and system nodes

- **WHEN** monitoring is enabled on a cluster containing frontend-tainted and system nodes
- **THEN** the required collectors run on or reach every in-scope node
- **AND** Amazon Managed Service for Prometheus (AMP) queries identify the expected nodes and workloads using the configured cluster label

### Requirement: Export to a confirmed AMP workspace with scoped identity

The system SHALL send metrics to the configured AMP workspace using SigV4 and workload IAM credentials. Runtime writers SHALL have write access scoped to that workspace and SHALL NOT require static AWS keys or Grafana Cloud credentials. Live ingestion SHALL require a confirmed workspace and documented collection budget.

The destination SHALL be verified against the infrastructure-managed AMP outputs and current application ingestion. GitOps SHALL consume only required nonsecret identifiers and endpoints; the infrastructure repository SHALL retain ownership of the shared AMP workspace and its rule namespaces.

#### Scenario: Reject incomplete destination configuration

- **WHEN** the enabled deployment lacks a confirmed AMP destination or region
- **THEN** configuration validation fails with the missing input identified
- **AND** deployment does not create a replacement workspace or select an implicit destination

#### Scenario: Restrict collector permissions

- **WHEN** collector IAM policies are evaluated
- **THEN** metric writes are permitted for the configured AMP workspace
- **AND** the collector is not granted workspace administration or write access to unrelated workspaces

### Requirement: Maintain one intended scrape owner per target

The system SHALL coordinate scrape ownership across metric collectors and avoid a second collection path for targets already covered by the selected pipeline. Enabled dashboard and rule inputs SHALL survive metric filtering.

#### Scenario: Scale metric collection

- **WHEN** a second metric collector joins the configured collector group
- **THEN** targets are distributed according to the collection policy
- **AND** the backend does not receive duplicate collection streams for the same target and labels after ownership stabilizes

### Requirement: Bound and observe delivery buffering

The system SHALL define finite memory and disk budgets, a metric-buffer retention window, and an explicit persistence policy. It SHALL expose export errors, dropped samples, buffer pressure, and ingestion freshness. The documented policy SHALL distinguish process restart from pod rescheduling and node deletion.

#### Scenario: Recover within the supported outage window

- **WHEN** the AMP connection is interrupted in the pilot for less than the configured buffer capacity and retention allow
- **THEN** collected metrics remain buffered and are exported after connectivity returns
- **AND** measured recovery and any data loss are recorded against the declared persistence policy

#### Scenario: Exceed buffer capacity

- **WHEN** an outage exceeds the configured buffering limits
- **THEN** resource use remains bounded
- **AND** sample loss or stale ingestion is observable to monitoring operators

### Requirement: Deploy independently of application startup

The monitoring application SHALL be managed by ArgoCD outside the `infra` bootstrap group, with pinned chart dependencies. An unavailable monitoring backend SHALL NOT prevent codeai application startup. Collector removal SHALL preserve existing shared telemetry stores.

#### Scenario: Backend unavailable during deployment

- **WHEN** the AMP endpoint is unavailable during application deployment
- **THEN** monitoring reports its delivery failure
- **AND** codeai application deployment is not gated on monitoring health

#### Scenario: Remove monitoring collectors

- **WHEN** the monitoring application is removed through its documented lifecycle
- **THEN** its collectors and owned Kubernetes resources are removed without stuck operator finalizers
- **AND** shared Amazon Managed Grafana (AMG) and AMP workspaces and previously stored telemetry remain intact
