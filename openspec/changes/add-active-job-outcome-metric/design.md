## Context

ActiveJob runs on `delayed_job_active_record`. Every worker, EC2 or k8s, drains one `delayed_jobs` table per environment. `Delayed::Worker.max_attempts` is 1 and failed rows are kept.

Metrics come from the `ActiveJobMetrics` concern, included by `ApplicationJob` and `MailDeliveryJob`:

- It pushes to the `code-dot-org/ActiveJob` namespace through `Cdo::Metrics.push`, a buffered, asynchronous `PutMetricData` (flushes at most 60 seconds apart, and for up to 10 seconds at exit).
- Per-job series carry exactly two dimensions, `Environment` and `JobName`, from `common_dimensions`.
- `after_perform :report_performance` emits `ExecutionTime` and `TotalTime`. It does not run when a job raises.
- Queue gauges (`PendingJobCount`, `FailedJobCount`, ...) are computed from the shared table, by enqueuers and by a once-a-minute cron on the EC2 daemon. They already include work done by k8s.

The k8s worker is one Deployment per environment, rendered by the codeai chart in `code-dot-org/k8s/helm`. In staging and production it runs `bin/delayed_job --min-priority 10 run`, so it takes low-priority work only, alongside the EC2 workers.

Observed on the staging worker, read-only:

- The pod runs as service account `cdo-app` with an IRSA role, and the app IAM policy allows `cloudwatch:PutMetricData`.
- `Rails.logger` is `Syslog::Logger` in production and staging. In a pod its lines reach `kubectl logs` prefixed `dashboard[1]:`. With no syslog daemon in the container, the syslog client falls back to the console, which exists because the chart sets `tty: true`.
- An ActiveJob lifecycle line from a real job has not been observed; the pod had only polled.

Constraints:

- The user commits, pushes, merges, runs tofu and promotes in Kargo. `kubectl` is read-only.
- The change must not rename or disturb any existing series. The staging KEDA ScaledObject reads `PendingJobCount` by exact dimension set.
- The code ships to legacy EC2 production too, so it must be safe in the job hot path there.

## Goals / Non-Goals

**Goals:**

- One CloudWatch series that shows whether k8s workers have recently run jobs, how those runs ended, and how that compares with EC2.
- Failures counted as events, not inferred from a gauge.
- A panel on the dashboard people already open for ActiveJob.
- A smoke test that can be repeated with two one-line enqueues.

**Non-Goals:**

- Proving a worker is healthy at this moment. That needs a canary job with a deadline.
- Shipping container logs anywhere.
- Alert rules on the new metric, and alert routing.
- Moving `delayed_job`'s own logger, which writes to a file in the container, to stdout.
- Adding `Platform` to existing metrics.
- Any change to `apps/monitoring` or the Alloy collector.

## Decisions

### 1. A counter first, logs later

The first question about a new worker is "is it working". A counter gives evidence for that in one panel and can later drive an alert. Logs answer "why did it fail", which Honeybadger already covers for exceptions.

Log shipping also costs more than it looks. Alloy has no `otelcol.exporter.awscloudwatchlogs`, and an upgrade would not add one:

| Alloy | Helm chart | CloudWatch Logs exporter |
|---|---|---|
| v1.19.2 (pinned) | 1.12.1 | no |
| v1.22.0 (latest at the time of writing) | 1.16.0 | no |

- The upstream request, [grafana/alloy#627](https://github.com/grafana/alloy/issues/627), has been open since April 2024.
- Alloy's CloudWatch components all read from AWS: `otelcol.receiver.awscloudwatch` pulls logs out of CloudWatch, and `prometheus.exporter.cloudwatch` pulls metrics.

The workable routes each bring new infrastructure:

- A Fluent Bit DaemonSet in a new app.
- Alloy `loki.source.kubernetes` to `otelcol.exporter.otlphttp` with `otelcol.auth.sigv4`, against the CloudWatch Logs OTLP endpoint. Every component is already in v1.19.2, so this needs no upgrade either, and users on the upstream issue report it working with IRSA. It needs log groups and streams created ahead of time, and `provider-aws-cloudwatchlogs`, which is not installed.
- The CloudWatch Observability EKS add-on, through tofu.

Choosing between them is easier once we have seen what production worker logs look like and how often we reach for them.

### 2. A new metric with its own dimension set

`PerformCount`, unit `Count`, value 1, dimensions `Environment`, `JobName`, `Outcome`, `Platform`.

CloudWatch treats each distinct dimension set as a separate metric. Adding `Platform` to `common_dimensions` would move `WaitTime`, `ExecutionTime` and the per-job gauges to new series. Every existing panel and the KEDA trigger would then read empty series. So the new metric builds its own dimension list, and `common_dimensions` is not touched.

*Alternative considered:* add `Outcome` to `ExecutionTime` and count its samples. Rejected: same renaming problem, and `after_perform` does not run on failure.

### 3. `around_perform`, with the outcome decided in `ensure`

```ruby
around_perform :report_outcome

protected def report_outcome
  succeeded = false
  yield
  succeeded = true
ensure
  push_perform_count(succeeded ? 'success' : 'failure')
end

protected def push_perform_count(outcome)
  return unless CDO.running_active_job_worker?

  Cdo::Metrics.push(METRICS_NAMESPACE, [...])
rescue => exception
  begin
    Observability::Errors.report(exception, error_message: 'Error reporting ActiveJob metrics')
  rescue
    # Reporting failed too. Nothing here may change the job's result.
  end
end
```

- **Where it sits.** In ActiveJob 7.1, `perform_now` wraps `run_callbacks :perform` in its own `rescue`, which is where `rescue_from`, `retry_on` and `discard_on` are applied. An `around_perform` therefore sees the exception first. Jobs that swallow their failures through `rescue_from` (for example `ProjectStorage::AnonymousGeoBackfillingJob`) are counted as failures.
- **Why `ensure` and not `rescue`.** `ensure` records non-`StandardError` exits too, without rescuing `Exception`, and it cannot change what propagates.
- **Everything else lives in the helper.** The worker check, the push and the error report all sit inside one guarded method, so none of them can raise into the `ensure`.
- **Why the report is guarded too.** `Observability::Errors.report` has no guard of its own. Raising from an `ensure` would fail a successful job or replace a failed job's real exception. The other reporters in this file share that exposure; this change does not touch them.

*Alternative considered:* a `Delayed::Plugin` lifecycle hook. Rejected: the dimensions and helpers already live in the concern.

### 4. Counted in worker processes only

The datum is pushed only when `CDO.running_active_job_worker?` is true. Both worker launchers set that context: `dashboard/bin/delayed_job`, which the k8s pod runs, and `lib/cdo/active_job_backend.rb`, which the EC2 daemon uses.

The question is whether queue workers are completing jobs. A job run inline from a console or a rake task says nothing about that, and on a k8s pod it would be labelled `k8s` and could make a broken worker look alive. No application code calls `perform_now` today, so this changes no numbers; it makes the metric's meaning hold by construction.

Two consequences:

- A future launcher that does not set the context would emit nothing. The smoke test catches that for the launchers that exist.
- Unit tests run outside a worker context, so existing tests that set strict expectations on `Cdo::Metrics.push` see no new push. Tests of the counter stub the worker check.

### 5. `success` means "finished without raising"

The callback sees whether the chain raised. It cannot see whether `perform` itself ran. `ProjectStorage::AnonymousGeoBackfillingJob` shows both ways a run ends early without raising: its `before_perform` aborts when a DCDO flag is set, and its own `around_perform` skips when it cannot take an advisory lock. Both count as `success`.

That is the right reading for this metric: the worker took the job off the queue and finished it without error. The spec, the panel description and the tests say so in those words.

*Alternative considered:* a third outcome, `skipped`. Rejected for now: detecting it generically means intercepting `perform` on every job subclass.

### 6. Platform comes from CDO config, set by the chart for every pod

- `config.yml.erb` gains `compute_platform: ec2`.
- `k8s/helm/templates/locals.yml.yaml` gains `compute_platform: k8s`.
- The metric reads `CDO.compute_platform`.

This uses machinery that exists. The config loader turns every `CDO_*` environment variable into a CDO config override, and the chart injects its `locals.yml` ConfigMap into every pod with that prefix. The platform is a property of where the chart runs, not of the worker, so it is set once for the chart, and other metrics can use it later.

Consequences worth knowing:

- An older image under a newer chart is safe. Pods set `PERMIT_UNKNOWN_PROPERTIES_IN_CDO`, so the unknown key is ignored.
- A newer image under an older chart reports `ec2` from a pod. This cannot happen on the normal path, because the chart and the image come from the same commit lineage and the chart is never behind the image.
- The pod template has no checksum for this ConfigMap, so pods pick the value up at their next rollout. The image change that carries the metric code causes one.
- `ec2` is also the value on a developer laptop or in CI. Nothing is emitted there unless a worker is started, and those have other `Environment` values.

*Alternatives considered:*

- An environment variable in `activeJobWorker.extraEnv`. Works, but ties a chart-wide fact to one component.
- Detecting `KUBERNETES_SERVICE_HOST`. No chart change at all, but implicit, harder to test, and it cannot express a third platform.

### 7. One datum per perform, keyed by job

`JobName` stays in the dimension set, although the panel sums across it.

- A dimension cannot be added later without starting new series, which is the renaming problem of decision 2. Summing over `JobName` loses nothing; leaving it out loses the per-class view for good.
- "Which job class is failing on k8s" is the next question after "something is failing".
- A canary job will read its own `JobName` directly.

The panel sums across jobs with a hidden `SEARCH` and a visible `SUM`, the same pattern "Jobs Started per Minute" uses.

No second, pre-aggregated series without `JobName`. If an environment-wide failure alert is wanted later, a `{Environment, Outcome, Platform}` aggregate datum is a small follow-up.

### 8. Panel only

"Jobs performed by platform" in `activejob-overview`, on the CloudWatch datasource:

- Four hidden `SEARCH` expressions over `{code-dot-org/ActiveJob,Environment,JobName,Outcome,Platform}`, one per `Platform` and `Outcome` pair, statistic `Sum`, period 60, filtered by `$environment`.
- Four visible `SUM(...)` series named for the pair, for example `k8s success`.
- Failure series coloured red, so a failure on either platform stands out.
- A description that says what `success` means, what is not counted, and that no data means unknown, not healthy.

No alert rule. Grafana's alert routing is not in code (the only contact point was created by hand), so a rule added here would have nowhere dependable to go.

The follow-up is a scheduled canary job with an alert on a missed deadline. It must run on a queue only the k8s worker reads: on the shared queue an EC2 worker can take it, and its completion would say nothing about k8s.

### 9. The smoke test uses `SampleJob`

`SampleJob` exists for exercising the queue by hand. It has no side effects beyond `puts` and a short sleep. It gains one keyword argument:

```ruby
def perform(*message, fail: false)
  raise 'SampleJob failure requested' if fail
  ...
end
```

- Success: `SampleJob.set(queue: CDO.active_job_queues[:low_priority]).perform_later('smoke')`
- Failure: the same with `fail: true`

The queue gives the job priority 10, which the k8s worker accepts. The raise happens inside `perform`, so it is inside the instrumentation. A failed `SampleJob` leaves one failed row and one Honeybadger notice, both expected.

EC2 workers read the same queue, so a smoke job may be taken by EC2. The test repeats a bounded number of times and records which worker took each job.

*Alternative considered:* any existing job given arguments that make it fail. Rejected: the failure point is not controlled, and a real job can have side effects.

### 10. Logs: verify, do not change

`Rails.logger` output already reaches `kubectl logs` on the worker. ActiveJob's log subscriber writes `Performing`, `Performed` and `Error performing` through `Rails.logger` at info level, and production logs at info. So job lifecycle lines should already be visible. The smoke test proves it with the same two jobs; it is a check, not a requirement of its own.

Two limits are stated so they are not rediscovered:

- This depends on `tty: true`. The chart comment on that line is extended to say so, since the flag otherwise looks like something to tidy away.
- `delayed_job`'s own lines still go to `log/delayed_job.log` inside the container. Moving them is separate work.

If the check fails, that is a finding to report, not something this change fixes.

## Risks / Trade-offs

- **[No data is ambiguous: idle, broken, or unable to push]** → The smoke test rules out "unable to push" before production relies on the metric. The panel and the runbook say that no data means unknown. `locked_by` on running `delayed_jobs` rows names the pod, with no metric involved. A canary closes the gap.
- **[A hard-killed job leaves no trace in any metric or error tracker]** → The row stays locked for up to 4 hours and then reruns. Evidence is the pod's restart count and last termination reason, and rows with an old `locked_at`. The runbook names both.
- **[Failures before the perform callbacks are not counted]** → `FailedJobCount` and Honeybadger see them.
- **[Datapoints lost when a process dies before the buffer flushes]** → Up to 60 seconds of counts, with a 10-second flush at exit. Acceptable for a trend panel. An alert built on this metric must tolerate a missing minute.
- **[A new callback in the hot path of every legacy job]** → One in-memory buffer append in worker processes, and one boolean check elsewhere. The whole metric path is guarded. Tests cover success, failure, a failing push and a failing error report.
- **[Nobody watches the panel]** → Accepted. The production promotion runbook names it as a post-promotion check.
- **[Logs lost on rollout]** → Accepted until logs are shipped.

## Migration Plan

1. Merge the code-dot-org PR to `staging`. Argo applies the chart; Kargo promotes the image; the staging worker rolls.
2. Run the smoke test on staging: `PerformCount` samples for both outcomes with `Platform=k8s`, existing series intact, KEDA still reading, job lifecycle lines in `kubectl logs`.
3. Build and apply the panel.
4. The normal DTP carries the change to legacy production. `Platform=ec2` series appear there.
5. The first Kargo promotion to production k8s that includes the change makes `Platform=k8s` appear for `Environment=production`.

Rollback is a revert of the code-dot-org PR. The series stop receiving data and expire from CloudWatch on their own. Nothing else depends on them.

## Open Questions

- **Do ActiveJob lifecycle lines reach `kubectl logs`?** Expected yes; the smoke test answers it.
- **Does a staging pod's `PutMetricData` succeed end to end?** IAM and IRSA look right; the smoke test answers it.
- **Is `ec2` the right name for "not the chart"?** It is accurate for every environment whose series anyone reads. `legacy` is the alternative if the name bothers anyone in review.
