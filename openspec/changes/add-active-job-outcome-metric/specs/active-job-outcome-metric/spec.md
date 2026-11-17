## ADDED Requirements

### Requirement: Every job run by an ActiveJob worker is counted once with its outcome

Each job class that includes `ActiveJobMetrics` SHALL emit exactly one `PerformCount` datum per perform attempt run in an ActiveJob worker process (`CDO.running_active_job_worker?`), to the `code-dot-org/ActiveJob` CloudWatch namespace, through `Cdo::Metrics.push`. The datum SHALL have unit `Count`, value 1, and exactly these dimensions:

- `Environment`: `CDO.rack_env`
- `JobName`: the job class name
- `Outcome`: `failure` when the attempt exits by raising, `success` when it finishes without raising
- `Platform`: `CDO.compute_platform`

The outcome SHALL be measured inside the perform callbacks, so that an exception later handled by `rescue_from`, `retry_on` or `discard_on` still counts as a failure.

`success` SHALL mean only that the attempt finished without raising. An attempt that the job's own callbacks abort or skip, so that `perform` never runs, counts as `success`.

An attempt run outside a worker process SHALL NOT emit the datum.

#### Scenario: A job succeeds

- **WHEN** a worker runs a job and its `perform` returns without raising
- **THEN** one `PerformCount` datum is pushed with `Outcome=success`, and none with `Outcome=failure`

#### Scenario: A job raises

- **WHEN** a worker runs a job and its `perform` raises
- **THEN** one `PerformCount` datum is pushed with `Outcome=failure`, and the same exception propagates to the caller unchanged

#### Scenario: A job swallows its own failure

- **WHEN** a job class handles an exception with `rescue_from` and its `perform` raises that exception
- **THEN** one `PerformCount` datum is pushed with `Outcome=failure`

#### Scenario: A job is retried

- **WHEN** a job fails once and is retried by `retry_on`, then succeeds
- **THEN** two data are pushed: one `Outcome=failure` and one `Outcome=success`

#### Scenario: A before_perform callback aborts the job

- **WHEN** a job's own `before_perform` halts the callback chain with `throw :abort`
- **THEN** one `PerformCount` datum is pushed with `Outcome=success`

#### Scenario: An around_perform callback skips the job

- **WHEN** a job's own `around_perform` returns without calling its block
- **THEN** one `PerformCount` datum is pushed with `Outcome=success`

#### Scenario: A job is run outside a worker process

- **WHEN** a job is run with `perform_now` in a process where `CDO.running_active_job_worker?` is false
- **THEN** no `PerformCount` datum is pushed, and the job runs as it did before this change

### Requirement: Counting the outcome never changes a job's result

No error in the `PerformCount` path SHALL propagate out of it. This covers the worker check, building the datum, the push, and reporting a failure of any of those through `Observability::Errors.report`. Such an error SHALL NOT turn a successful job into a failed one, and SHALL NOT replace the exception of a failed one.

#### Scenario: The push fails after a successful job

- **WHEN** `perform` returns and `Cdo::Metrics.push` raises for the `PerformCount` datum
- **THEN** the job completes without raising, and the error is reported once

#### Scenario: The push fails after a failed job

- **WHEN** `perform` raises and `Cdo::Metrics.push` also raises for the `PerformCount` datum
- **THEN** the exception the caller sees is the one `perform` raised

#### Scenario: Reporting the error fails too

- **WHEN** `Cdo::Metrics.push` raises for the `PerformCount` datum and `Observability::Errors.report` also raises
- **THEN** a successful job still completes without raising, and a failed job still raises its own exception

### Requirement: Existing ActiveJob metrics are unchanged

This change SHALL NOT alter the name, unit or dimension set of any metric `ActiveJobMetrics` already emits. `common_dimensions` SHALL continue to return exactly `Environment` and `JobName`.

#### Scenario: Existing per-job series

- **WHEN** a job is enqueued and performed after this change
- **THEN** `WaitTime`, `ExecutionTime`, `TotalTime` and the per-job gauges are pushed with dimensions `Environment` and `JobName` only

#### Scenario: The KEDA trigger

- **WHEN** the staging ScaledObject queries `PendingJobCount` with dimensions `Environment` and `Priority`
- **THEN** it reads the same series it read before this change

### Requirement: The platform is a CDO config value that defaults to ec2

`config.yml.erb` SHALL define `compute_platform` with the value `ec2`. The value SHALL be overridable in the same ways as any other CDO config key, including the `CDO_COMPUTE_PLATFORM` environment variable.

#### Scenario: A legacy EC2 worker

- **WHEN** a worker on an EC2 instance runs a job with no override
- **THEN** its `PerformCount` datum carries `Platform=ec2`

#### Scenario: An override is present

- **WHEN** a worker process starts with `CDO_COMPUTE_PLATFORM=k8s`
- **THEN** `CDO.compute_platform` is `k8s`, and its `PerformCount` data carry `Platform=k8s`

### Requirement: Every pod rendered by the codeai chart reports the k8s platform

The chart's `locals.yml` ConfigMap SHALL set `compute_platform` to `k8s`, so that every container built from the shared dashboard pod template receives it. The chart's `Chart.yaml` `version` SHALL be bumped in the same change.

#### Scenario: The worker in production

- **WHEN** the chart is rendered with the production value layering
- **THEN** the ActiveJob worker container's environment resolves `CDO_compute_platform` to `k8s`

#### Scenario: An older image under the new chart

- **WHEN** a pod runs an image built before `compute_platform` existed, with the new ConfigMap
- **THEN** the pod boots normally and ignores the unknown key

### Requirement: A harmless job can be made to succeed or fail on request

`SampleJob` SHALL accept a `fail:` keyword argument, false by default. When it is true, `perform` SHALL raise before doing anything else. With it false or absent, `SampleJob` SHALL behave as it did before this change.

#### Scenario: A controlled failure

- **WHEN** `SampleJob` is enqueued with `fail: true` and a worker runs it
- **THEN** it raises inside `perform`, and one `PerformCount` datum is pushed with `JobName=SampleJob` and `Outcome=failure`

#### Scenario: A harmless success

- **WHEN** `SampleJob` is enqueued without `fail:` and a worker runs it
- **THEN** it completes, and one `PerformCount` datum is pushed with `JobName=SampleJob` and `Outcome=success`

### Requirement: The metric is verified on staging before production relies on it

Before the change is promoted to production k8s, one succeeding and one failing `SampleJob` SHALL be run by the staging k8s worker. For each, the record SHALL include the ActiveJob ID, the enqueue time, and the evidence that a k8s pod ran it (`locked_by`, or the pod's log lines for that job ID).

CloudWatch SHALL then return a datapoint for each when `PerformCount` statistics are requested with all four dimensions: `Environment=staging`, `JobName=SampleJob`, `Platform=k8s`, and the outcome. Metric discovery (`list-metrics`) SHALL NOT be the pass condition, because CloudWatch can take up to 15 minutes to list a new metric.

#### Scenario: The smoke test passes

- **WHEN** the staging k8s worker has run one succeeding and one failing `SampleJob`
- **THEN** within five minutes a statistics query with all four dimensions returns a datapoint for `Outcome=success` and one for `Outcome=failure`

#### Scenario: An EC2 worker takes the job

- **WHEN** a smoke job is taken by an EC2 worker
- **THEN** it is enqueued again, at most five times per case, and if the k8s worker has taken none the test stops and that is reported

#### Scenario: No datapoint appears

- **WHEN** a k8s pod ran the job and the statistics query returns nothing after five minutes
- **THEN** the change is not promoted to production, and the cause is investigated in this order: which worker ran the job, the pod's `compute_platform`, the query's dimensions, the buffer flush, and the pod's credentials and IAM policy
