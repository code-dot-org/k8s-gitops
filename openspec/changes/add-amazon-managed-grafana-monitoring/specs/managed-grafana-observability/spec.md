## ADDED Requirements

### Requirement: Use the existing Amazon Managed Grafana workspace

The system SHALL provide dashboards and alerts in the user-designated existing Amazon Managed Grafana (AMG) workspace. It SHALL NOT require Grafana Cloud accounts, endpoints, access tokens, or Cloud-only applications. Workspace identity, version, permissions, and existing data sources SHALL be inventoried before provisioning.

The deployment SHALL reuse the AMG and Amazon Managed Service for Prometheus (AMP) resources owned by `infrastructure/observability/opentofu` and retain existing data-source UIDs. HCL and generated dashboard/alert references SHALL use the plugin appropriate to the live AMG version, including checking the AMG 12 SigV4 migration before applying shared configuration.

#### Scenario: Provision into the confirmed workspace

- **WHEN** monitoring provisioning runs with the confirmed AMG workspace configuration
- **THEN** resources are created or reconciled in that workspace using supported APIs and data sources
- **AND** no new Grafana workspace or Grafana Cloud service is created

#### Scenario: Reconcile a migrated AMP data source

- **WHEN** live AMG uses the AMP plugin but managed HCL or dashboard references still declare the core Prometheus plugin
- **THEN** the deployment reconciles the managed references before shared provisioning
- **AND** it preserves the existing data-source UID and verifies both legacy and Kubernetes consumers

### Requirement: Extend the existing provisioning owner

Dashboard and AMG alert source SHALL live in `infrastructure/observability/dashboards/grafana`, using its existing TypeScript build and registry. Shared workspace resources, dashboard/alert provisioning, notification routing, and AMP rule namespaces SHALL use the infrastructure repository's OpenTofu workflow and provider authentication. ArgoCD SHALL manage cluster collectors independently and SHALL NOT introduce a competing owner for those Grafana resources.

#### Scenario: Prepare a reproducible infrastructure deployment

- **WHEN** an operator prepares monitoring changes for deployment
- **THEN** dashboard type checking and generation complete before OpenTofu validates and plans the generated resources
- **AND** the documented manual or explicitly enabled CI path makes those artifacts available at plan and apply
- **AND** the shared plan is reviewed for unrelated changes and Grafana administrative credentials are not copied into the cluster

### Requirement: Query AWS telemetry using appropriate permissions

The system SHALL configure AMG to query the confirmed AMP workspace and selected CloudWatch log groups. Query permissions SHALL be separate from collector write permissions. Missing provisioning or query access SHALL be reported explicitly.

#### Scenario: Validate data-source access

- **WHEN** an authorized operator tests the AMP and CloudWatch data sources
- **THEN** the tests succeed and queries return the pilot cluster's metrics and selected logs
- **AND** runtime collector identities are not used as Grafana provisioning credentials

### Requirement: Reconcile owned dashboards and rules reproducibly

The system SHALL version custom dashboard, recording-rule, and alert definitions in Git with stable identifiers. Repeated provisioning SHALL reconcile only resources owned by this change. Recording rules SHALL be available before dependent dashboard and alert validation is declared complete.

#### Scenario: Repeat provisioning

- **WHEN** the same monitoring revision is provisioned twice
- **THEN** owned dashboards and rules have the same identifiers and definitions
- **AND** no duplicate dashboards or alerts are created
- **AND** unrelated workspace configuration remains unchanged

### Requirement: Provide operational dashboards with source filters

The system SHALL provide views for cluster/node resource use, workload availability and restarts, application request metrics, worker health, collection health, and scoped logs. Views SHALL support applicable cluster, namespace, environment, and service filters. Missing telemetry SHALL remain distinguishable from healthy zero values.

#### Scenario: Investigate one environment

- **WHEN** an operator selects the staging namespace and Dashboard service
- **THEN** the relevant views show that selection's workloads and telemetry without mixing unrelated environments
- **AND** absent data is visible as missing rather than silently displayed as healthy

#### Scenario: Preserve existing application alert scope

- **WHEN** Kubernetes and legacy host request metrics coexist in AMP
- **THEN** Kubernetes views select their intended cluster and namespace without relying on legacy host-only selectors
- **AND** existing production alerts retain their intended population without unintentionally adding Kubernetes traffic
- **AND** source filters survive dashboard drilldown navigation

### Requirement: Route actionable alerts and detect monitoring loss

Each enabled alert SHALL have one evaluation owner, severity, responsible team, runbook, notification route, and explicit missing-data behavior. The deployment SHALL test notification delivery and provide an external availability or telemetry-loss check that remains effective when cluster collection stops.

New routes SHALL extend the existing OpenTofu-owned root notification policy without replacing unrelated routes. Contact points SHALL follow the current AMG administrator-managed process, and test notification recipients and sending SHALL be explicitly authorized before a controlled alert is triggered.

#### Scenario: Route to a new contact point

- **WHEN** the selected Kubernetes route references a contact point that does not exist
- **THEN** its creation is assigned to the AMG administrator before applying the route
- **AND** the deployment preserves existing root and child routes and keeps webhook credentials out of source code

#### Scenario: Test alert delivery

- **WHEN** a controlled pilot condition triggers an alert through the designated test route
- **THEN** the recipient receives the expected severity, source context, and runbook
- **AND** the alert resolves after the condition clears

#### Scenario: Lose cluster telemetry

- **WHEN** cluster ingestion stops for the configured detection interval
- **THEN** an evaluation outside the affected cluster reports the missing signal
- **AND** the absence of telemetry is not treated as evidence that the cluster is healthy

### Requirement: Measure incremental cost before expansion

The rollout SHALL document the selected budget and collection/retention settings, measure at least 24 hours of pilot usage, and report estimated incremental AMP, CloudWatch, collector, and networking costs with assumptions before production expansion.

#### Scenario: Review pilot usage

- **WHEN** the pilot observation period completes
- **THEN** operators receive coverage, collector-resource, metric-volume, log-volume, and projected-cost results
- **AND** production expansion is held until unresolved budget or coverage decisions are settled
