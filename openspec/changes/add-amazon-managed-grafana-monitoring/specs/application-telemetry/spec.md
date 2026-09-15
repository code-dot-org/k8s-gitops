## ADDED Requirements

### Requirement: Reuse application OpenTelemetry instrumentation

The system SHALL configure in-scope Kubernetes applications to send telemetry from the existing OpenTelemetry instrumentation to an internal collector endpoint. Environment settings SHALL be managed in Git, including worker-specific settings where the chart requires them. No externally exposed OTLP receiver SHALL be required.

#### Scenario: Enable staging telemetry

- **WHEN** staging application telemetry is enabled through its deployment values
- **THEN** the application exports OTLP to the designated in-cluster receiver
- **AND** the configuration does not depend on a Chef-installed host collector

### Requirement: Preserve originating application identity

The system SHALL retain the originating service, environment, cluster, namespace, pod, and service-instance identity with a documented mapping to metric labels. A shared collector SHALL NOT replace producer identity with its own pod identity.

#### Scenario: Receive from multiple applications

- **WHEN** two pods in different namespaces send telemetry to the same collector
- **THEN** queries can distinguish their source namespaces, pods, services, and instances
- **AND** metrics are not attributed to the collector as the application

### Requirement: Generate request metrics before trace sampling

The system SHALL derive request-rate, error, and duration metrics from the full received Rack request span stream before applying trace sampling. It SHALL document metric names, units, histogram buckets, and bounded dimensions, including compatibility changes from the Chef pipeline.

Existing Rack/Auth consumers of `rack_calls_total` and `rack_duration_milliseconds_bucket` SHALL be accounted for before application ingestion begins. Any change to units, buckets, or legacy `host`/`process_pid` selection SHALL include coordinated query changes in the infrastructure dashboard package and verification that existing alert scope remains intentional.

#### Scenario: Count requests with sampled trace export

- **WHEN** a known pilot request sequence reaches the collector and trace export retains only a subset of its spans
- **THEN** request and error metric counts represent the complete received request sequence
- **AND** duration observations use the documented units and buckets

### Requirement: Keep aggregation writers distinct

The system SHALL prevent conflicting cumulative metric writes when multiple application collectors export to the same Amazon Managed Service for Prometheus (AMP) workspace. Aggregation identity SHALL support correct combined request-rate and error queries across collectors and restarts.

#### Scenario: Receive traffic through two collectors

- **WHEN** a known request sequence is distributed across two collector instances
- **THEN** their metric streams remain distinct at ingestion
- **AND** the combined query counts the received requests once without writer collisions

### Requirement: Expose background-worker health

The system SHALL expose backlog, oldest pending-job age, failures, and processing duration for in-scope background workers. It SHALL reuse existing signals when suitable and bound the cost and permissions of any new queue measurement.

The rollout SHALL assess and reuse the existing `ActiveJobMetrics` CloudWatch signals and ActiveJob dashboard before adding instrumentation. It SHALL document metric-write IAM, scheduled reporter ownership, queue backend compatibility, and shared-queue versus deployment-specific dimensions. Suitable CloudWatch signals SHALL NOT require duplication into AMP. Host-local process counts SHALL NOT be presented as fleet-wide Kubernetes worker counts.

#### Scenario: Detect a stalled queue

- **WHEN** pending jobs remain unprocessed during the pilot
- **THEN** backlog and oldest pending-job age reflect the condition
- **AND** operators can distinguish the affected worker environment from web request traffic

#### Scenario: Observe workers across multiple pods

- **WHEN** workers for an in-scope queue run in two Kubernetes pods
- **THEN** worker capacity views reflect their intended combined scope rather than one pod's local process list
- **AND** queue-wide views identify any intentional sharing with legacy workers and avoid duplicate scheduled reporting
- **AND** Kubernetes resource panels do not depend on resolving an EC2 daemon instance

### Requirement: Preserve application operation and Sentry routing

Application telemetry SHALL operate asynchronously and SHALL NOT make application readiness depend on collector or backend health. The rollout SHALL preserve the existing configured Sentry behavior and verify it during the pilot.

#### Scenario: Collector unavailable

- **WHEN** the application cannot reach the collector
- **THEN** normal requests and background jobs continue without a monitoring-specific readiness failure
- **AND** telemetry loss or export failure is observable through the documented monitoring path

#### Scenario: Verify existing Sentry integration

- **WHEN** a controlled staging error and trace are generated with the existing Sentry integration enabled
- **THEN** the configured Sentry behavior continues to work after the telemetry rollout
