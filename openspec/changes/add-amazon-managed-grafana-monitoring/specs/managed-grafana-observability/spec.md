## ADDED Requirements

### Requirement: Reuse the existing workspace and provisioning owner

The dashboard SHALL use the existing Amazon Managed Grafana (AMG) workspace and its Amazon Managed Service for Prometheus (AMP) data source. Source SHALL live in the existing `infrastructure/observability/dashboards/grafana` package and be provisioned through its OpenTofu owner after type checking and generation. V1 SHALL use the manual deployment workflow, preserve data-source identifiers and existing consumers, and require neither Grafana Cloud nor new backend services.

#### Scenario: Provision the v1 dashboard

- **WHEN** the generated dashboard is applied through the reviewed infrastructure plan
- **THEN** it appears in the existing workspace with a stable identifier and working AMP queries
- **AND** the plan introduces no unintended changes to existing dashboards, alerts, or shared resources
- **AND** a subsequent plan does not propose a duplicate or unintended dashboard change

#### Scenario: Resolve a data-source compatibility issue

- **WHEN** the deployed plugin differs from the managed configuration in a way that blocks correct provisioning or queries
- **THEN** the minimal compatibility change preserves the data-source identifier and existing query behavior
- **AND** it requires no application observability changes

### Requirement: Provide one useful Kubernetes overview

The dashboard SHALL show node readiness/allocatable capacity, workload availability, pod state/restarts, container CPU/memory, and collection health. Queries SHALL use raw collected metrics with the configured cluster label and applicable namespace/pod filters. Missing or stale data SHALL be distinguishable from healthy values. V1 SHALL NOT require recording rules, log panels, application metrics, alert rules, contact points, or notification routing changes.

#### Scenario: Inspect a namespace

- **WHEN** an operator selects an in-scope namespace and pod
- **THEN** applicable panels show that selection's resource use and state without mixing unrelated namespaces
- **AND** node capacity and container usage are labeled according to their actual scope

#### Scenario: Collection becomes unavailable

- **WHEN** new samples stop arriving
- **THEN** the dashboard exposes their age or absence rather than presenting historical or missing data as current health
- **AND** operators have a documented manual diagnosis path; automated notification is deferred

### Requirement: Complete a bounded first rollout

Acceptance SHALL verify expected node/workload coverage, working dashboard queries, freshness across several scrape intervals, and recovery after one controlled collector restart/update. The handoff SHALL include initial collector resource/ingestion usage, estimated incremental cost with assumptions, the dashboard URL, ownership, known limitations, and rollback instructions. A mandatory 24-hour soak, backend fault-injection suite, or production-promotion workflow SHALL NOT be required for v1.

#### Scenario: Finish v1

- **WHEN** the required checks pass and the initial usage report is within the agreed spending limit
- **THEN** v1 is ready for use with its single-collector, ephemeral-buffer, and no-new-alerting limitations documented
- **AND** logs/events, alerting, high availability, persistent buffering, and CI automation remain separate follow-ups
