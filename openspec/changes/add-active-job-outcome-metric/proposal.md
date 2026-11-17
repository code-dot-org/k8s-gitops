## Why

Nothing tells us whether a k8s ActiveJob worker is finishing jobs:

- **No job outcome is counted.** `ActiveJobMetrics` emits `ExecutionTime` from `after_perform`, which runs only on success. Failures show only as the `FailedJobCount` gauge, which the hourly archive cron resets.
- **k8s and EC2 are indistinguishable.** Workers on both push the same `Environment` value and drain the same `delayed_jobs` table. No series attributes a completed job to a k8s pod.

Shipping container logs to CloudWatch Logs is the other way to get visibility into the worker. It is the wrong first step:

- Logs answer "why did this job fail", not "are jobs succeeding". The second question comes first.
- It needs new infrastructure. The cluster's collector, Grafana Alloy, has no CloudWatch Logs exporter, so shipping means a new DaemonSet, a new Crossplane provider or an EKS add-on.
  - Upgrading Alloy does not change this. The exporter is missing from the pinned v1.19.2 and from the latest release at the time of writing, v1.22.0. The upstream request for it has been open since April 2024 ([grafana/alloy#627](https://github.com/grafana/alloy/issues/627)).

This change takes the smallest step that gives a real signal: a job outcome counter with a platform label, and one dashboard panel in Grafana. Log shipping and alert rules are left for later changes.

What the signal is: evidence that worker processes on a platform recently ran jobs, and how those runs ended. It is not proof that a worker is healthy right now. An idle worker and a broken one both produce no data.

## What Changes

- **Outcome counter (code-dot-org).** Every job run by an ActiveJob worker process emits one new CloudWatch metric, `PerformCount`, in the existing `code-dot-org/ActiveJob` namespace, with dimensions `Environment`, `JobName`, `Outcome` (`success` or `failure`) and `Platform` (`ec2` or `k8s`). Workers on both platforms emit it, so the two can be compared side by side.
  - `failure` means the run raised. `success` means it finished without raising, which includes a run the job's own callbacks chose to skip.
  - Jobs run outside a worker process (a console, a rake task) are not counted.
- **Platform identity (code-dot-org).** A new CDO config key, `compute_platform`, defaults to `ec2`. The codeai Helm chart sets it to `k8s` for every pod it renders.
- **Smoke-test job (code-dot-org).** `SampleJob` gains a `fail:` argument that makes it raise on request, so a harmless success and a controlled failure can each be enqueued with one line.
- **One dashboard panel (infrastructure).** `activejob-overview` gains "Jobs performed by platform": `PerformCount` per minute, split by `Platform` and `Outcome`.
- **Staging smoke test.** One succeeding and one failing `SampleJob` on the staging k8s worker confirm the metric end to end. The same run checks that ActiveJob's `Performing`, `Performed` and `Error performing` lines reach `kubectl logs`. No logging code changes; the chart comment on `tty: true` is extended to say that those lines depend on it.
- **Unchanged on purpose.**
  - Existing ActiveJob metrics keep their names and dimension sets. `Platform` is not added to them. CloudWatch matches dimension sets exactly, so adding it would rename every existing series and break `activejob-overview`, the GenAI latency panels and the KEDA trigger on `PendingJobCount`.
  - No alert rule, no contact-point routing, no log shipper, no `delayed_job` logger change, no change to `apps/monitoring`.

## Accepted risks

- **No data means unknown.** A missing or flat `Platform=k8s` series has three possible causes: no work was queued for that worker, the worker is broken, or the pod cannot call `PutMetricData`. The staging smoke test rules out the third before production relies on the metric. Telling the first two apart needs a canary job with a deadline, which is the follow-up. `locked_by` on running `delayed_jobs` rows names the pod that holds a job, with no metric involved.
- **Nobody is alerted.** The signal is a panel a person looks at.
- **Some failures are not counted.**
  - A pod that is OOM-killed or SIGKILLed mid-job records nothing anywhere: no datum, no Honeybadger notice, and no `FailedJobCount` change. The row stays locked until `Delayed::Worker.max_run_time` (4 hours) and is then run again. The evidence is the pod's restart count and last termination reason, and `delayed_jobs` rows with an old `locked_at`.
  - A failure before the perform callbacks run (argument deserialization, unknown job class) records no datum. `FailedJobCount` and Honeybadger do see these.
- **`success` includes skips.** `ProjectStorage::AnonymousGeoBackfillingJob` aborts when a DCDO flag is set and skips when it cannot take its advisory lock. Both count as `success`.
- **Counts are per attempt.** A job retried by `retry_on` counts one failure per failed attempt.
- **Worker logs die with the pod.** Every rollout replaces the worker pod and its log. Until logs are shipped, Honeybadger is the durable record of a failure.
- **Legacy production is touched.** Every EC2 job gains one buffered metric datum and one callback. An error in the metric path is contained; it cannot fail a job.
- **Cost.** At most 72 new series per environment (about 18 job classes, two outcomes, two platforms), about $22 a month per environment if every one is active. Fewer in practice: a failure series exists only for a class that has failed, and the k8s worker takes low-priority jobs only.

## Capabilities

### New Capabilities

- `active-job-outcome-metric`: every job run by an ActiveJob worker is counted once in CloudWatch, labelled with its outcome and the platform that ran it, without changing existing metrics or job behaviour.
- `active-job-platform-panel`: the ActiveJob overview dashboard shows jobs performed per minute by platform and outcome.

### Modified Capabilities

None. `openspec/specs/` holds no existing capabilities.

## Impact

- **code-dot-org**, one PR to `staging`:
  - `dashboard/app/jobs/concerns/active_job_metrics.rb` and its tests
  - `dashboard/app/jobs/sample_job.rb`
  - `config.yml.erb` (new key `compute_platform`)
  - `k8s/helm/templates/locals.yml.yaml`, a comment in `k8s/helm/templates/dashboard/_dashboard.yaml`, and `k8s/helm/Chart.yaml` (version bump)
- **infrastructure**: `observability/dashboards/grafana/src/dashboards/backend/rails/active-job/overview/index.ts`, then a build and a tofu apply.
- **k8s-gitops**: a few lines in `docs/production-promotion.md`. No chart under `apps/` changes, so no `Chart.yaml` bump here. No `apps/app-of-apps` structure change, so no mimic-tree edit.
- **Runtime**: one more datum per job in the existing buffered `PutMetricData` path, on EC2 and k8s workers.
- **Dependencies**: app pods must be able to call `cloudwatch:PutMetricData`. The staging worker has an IRSA role whose policy allows it; the smoke test verifies the push end to end.
- **Sequencing**:
  - The code-dot-org PR reaches staging k8s through Argo (chart) and Kargo (image), and legacy production through the normal DTP.
  - It reaches production k8s by a Kargo promotion after that DTP.
  - The panel can land at any time; it is empty until data exists.

## Terms

- **Legacy, EC2**: the EC2 fleet deployed by DTP, as opposed to the k8s (`codeai`) deployment.
- **DTP**: the legacy "deploy to production" process.
- **Per attempt**: one run of a job's `perform`. A retried job has several.
- **Worker process**: a process started by `bin/delayed_job` or the EC2 ActiveJob backend, for which `CDO.running_active_job_worker?` is true.
