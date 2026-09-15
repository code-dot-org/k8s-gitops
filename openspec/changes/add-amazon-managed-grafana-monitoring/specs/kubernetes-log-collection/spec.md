## ADDED Requirements

### Requirement: Collect only selected pod logs

The system SHALL forward pod stdout/stderr logs from an explicit namespace/workload selection to CloudWatch Logs. Existing shipping SHALL be inventoried, and the deployment SHALL avoid a second log-shipping path for the same source and destination. The shipper SHALL be validated against the cluster's Auto Mode nodes and taints.

#### Scenario: Enforce the pilot selection

- **WHEN** pods in an included staging namespace and an excluded namespace emit distinguishable test records
- **THEN** the included records arrive in the configured log group
- **AND** excluded records are not forwarded by this monitoring deployment

### Requirement: Preserve correlation metadata and apply filtering

Forwarded records SHALL retain applicable cluster, namespace, workload, pod, and container identity. Configured sensitive-field redaction and drop rules SHALL run before external export. Arbitrary request identifiers SHALL NOT be promoted to metric labels.

#### Scenario: Redact a configured sensitive field

- **WHEN** an included pod emits a test record containing a field covered by the redaction policy
- **THEN** the exported record follows that policy
- **AND** operators can still identify the record's originating pod and namespace

### Requirement: Persist Kubernetes events without duplicate watchers

The system SHALL collect Kubernetes events through one active collection owner for each selected scope and store them in CloudWatch with source-object identity. Event ingestion SHALL NOT implicitly enable EKS audit logging or change control-plane log configuration.

#### Scenario: Observe a workload event

- **WHEN** a controlled workload change produces a Kubernetes event
- **THEN** the event can be queried in CloudWatch with the cluster, namespace, and involved object
- **AND** multiple active event watchers do not produce duplicate collection streams

### Requirement: Configure finite retention and scoped access

Owned CloudWatch log groups SHALL have explicit finite retention and documented owners. Shippers SHALL receive only the AWS permissions required for their configured destination groups. Amazon Managed Grafana (AMG) query access SHALL be configured separately.

Owned log-group lifecycle SHALL reside in the infrastructure OpenTofu configuration, independently of the Argo monitoring application. AMG SHALL reuse its existing CloudWatch data source when confirmed compatible.

#### Scenario: Inspect a new log group

- **WHEN** a log group for the pilot is provisioned
- **THEN** its retention matches the agreed value
- **AND** ingestion permissions are scoped to the intended groups
- **AND** creation does not change retention for unrelated existing log groups

### Requirement: Bound delivery resources and preserve stored logs

Log and event collection SHALL have explicit resource and buffering limits with observable delivery failures. Its removal SHALL stop new ingestion while preserving shared log groups and stored history according to retention.

#### Scenario: CloudWatch temporarily unavailable

- **WHEN** a pilot export interruption exceeds the configured buffering capacity
- **THEN** the shipper remains within its declared resource limits
- **AND** delivery failure or record loss is observable

#### Scenario: Disable collection

- **WHEN** an operator disables the monitoring log/event collection through Git
- **THEN** new ingestion from those collectors stops
- **AND** previously stored records remain queryable until their retention expires
