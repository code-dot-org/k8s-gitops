# Scope and conventions

Three repositories, checked out side by side:

- `code-dot-org`: tasks 1 to 3. One PR to `staging`.
- `infrastructure`: task 4.
- `k8s-gitops`: the runbook edit in task 5.

Tasks marked **(user)** need an action only the user takes: git commit and push, PR merge, a tofu apply, a Kargo promotion, or anything that enqueues work on a live environment. Everything else is file editing plus local, read-only verification. Nothing in this list runs `kubectl` mutations or `tofu`. Read-only AWS calls use `AWS_PROFILE=cdo`.

Before the first edit in `code-dot-org` and in `infrastructure`, ask the user which branch to work on. Do not switch branches or stash on your own.

## 1. code-dot-org: outcome counter

- [x] 1.1 Add `compute_platform: ec2` to `config.yml.erb`, next to the other ActiveJob keys, with a comment: which platform this process runs on, `ec2` by default, set to `k8s` by the Helm chart, used as the `Platform` metric dimension
- [x] 1.2 In `dashboard/app/jobs/concerns/active_job_metrics.rb`, register `around_perform :report_outcome` in the `included` block and add the method:
  - set a local `succeeded = false`, `yield`, set it `true`, and call the push helper from `ensure`
  - no `rescue` around the `yield`, and nothing else in the method, so the original exception propagates untouched
  - a comment saying `success` means the attempt finished without raising, which includes attempts a job's own callbacks abort or skip
- [x] 1.3 Add the push helper used by 1.2, one guarded method holding everything that could raise:
  - return early unless `CDO.running_active_job_worker?`
  - one `Cdo::Metrics.push(METRICS_NAMESPACE, [...])` with `metric_name: 'PerformCount'`, `value: 1`, `unit: 'Count'`, `timestamp: Time.now`
  - dimensions built here, not from `common_dimensions`: `Environment` (`CDO.rack_env`), `JobName` (`self.class.name`), `Outcome`, `Platform` (`CDO.compute_platform`)
  - `rescue => exception` calling `Observability::Errors.report(exception, error_message: 'Error reporting ActiveJob metrics')`, with that call itself wrapped in a `rescue` that swallows, since this runs from an `ensure`
  - a comment saying why `Platform` is not in `common_dimensions`: CloudWatch matches dimension sets exactly, so adding it would rename every existing series
- [x] 1.4 Extend `dashboard/test/jobs/application_job_test.rb`, using the file's existing `includes_metrics` and `includes_dimensions` matchers. Stub `CDO.running_active_job_worker?` to true except where noted:
  - success: `perform_now` pushes `PerformCount` with `Outcome: 'success'` and `Platform: 'ec2'`
  - failure: a testable job whose `perform` raises pushes `Outcome: 'failure'`, and `perform_now` still raises the same exception
  - swallowed failure: a testable job with `rescue_from` pushes `Outcome: 'failure'`
  - aborted: a testable job whose `before_perform` does `throw :abort` pushes `Outcome: 'success'`, and its `perform` did not run
  - skipped: a testable job whose `around_perform` does not call its block pushes `Outcome: 'success'`, and its `perform` did not run
  - platform override: with `CDO.stubs(:compute_platform).returns('k8s')`, the datum carries `Platform: 'k8s'`
  - not a worker: without the stub, no `PerformCount` is pushed and the job runs normally
  - push failure after success: the `PerformCount` push raises, the job does not, and the error is reported once
  - push failure after failure: the exception seen is the job's own
  - report failure: the push raises and `Observability::Errors.report` raises; a successful job still completes, and a failing job still raises its own exception
  - `common_dimensions` still returns exactly `Environment` and `JobName`
- [x] 1.5 Run `dashboard/test/jobs/` and the other test files that set expectations on `Cdo::Metrics.push` (`grep -rl "Cdo::Metrics.expects(:push)" dashboard/test`). They run outside a worker context and should see no new push; if one fails, find out why before changing it
- [x] 1.6 In `dashboard/app/jobs/autoscaling_test_job.rb`, add a `fail: false` keyword argument to `perform`. When it is true, raise `'AutoscalingTestJob failure requested'` after the sleep, in place of logging `completed`. Leave the argument validation and the `started` event as they are. In `k8s/README.md`, under "Generate test work", document `fail: true` and add the two smoke-test enqueue lines:
  - `AutoscalingTestJob.perform_later(run_id: 'smoke-success', duration_seconds: 0)`
  - `AutoscalingTestJob.perform_later(run_id: 'smoke-failure', duration_seconds: 0, fail: true)`
- [x] 1.7 Extend `dashboard/test/jobs/autoscaling_test_job_test.rb`: with `fail: true` the job sleeps, raises, and logs `started` only. The existing cases cover the default and must still pass unchanged
- [x] 1.8 Run rubocop on the changed Ruby files and fix what it reports

## 2. code-dot-org: chart

- [x] 2.1 In `k8s/helm/templates/locals.yml.yaml`, add `compute_platform: k8s` to the ConfigMap's shared data, with a comment naming the `Platform` metric dimension as its reader
- [x] 2.2 In `k8s/helm/templates/dashboard/_dashboard.yaml`, extend the comment on `tty: true`: application log lines reach `kubectl logs` only through the syslog console fallback this enables, so it stays until the app logs to stdout directly
- [x] 2.3 Bump `version:` in `k8s/helm/Chart.yaml` from whatever `staging` has at the time
- [x] 2.4 Render the chart with `helm template` using the staging and the production value layering from `k8s-gitops/apps/codeai`, and confirm:
  - the `locals.yml` ConfigMap carries `compute_platform: k8s`
  - the worker Deployment takes that ConfigMap through `envFrom` with prefix `CDO_`
  - the diff against a render of the unchanged chart is the ConfigMap key, the comment and the chart version label, nothing else
- [x] 2.5 Confirm no file under `k8s-gitops/apps/codeai/` sets `compute_platform` or replaces the `locals.yml` ConfigMap, so no k8s-gitops values change is needed

## 3. code-dot-org: land and smoke-test on staging

- [ ] 3.1 **(user)** Open the PR to `staging`, get review, merge
- [ ] 3.2 After Kargo has promoted an image containing the merge commit to staging, confirm read-only that the staging worker pod runs that image and has `CDO_compute_platform=k8s` in its resolved environment (`kubectl get pod -o yaml` plus the ConfigMap; no `exec`)
- [ ] 3.3 **(user)** On staging, enqueue the two smoke jobs from task 1.6, one succeeding and one with `fail: true`. Record each job's ActiveJob ID and enqueue time
- [ ] 3.4 For each job, record which worker ran it and the evidence: the job's `started` event in the worker pod's log (`kubectl logs`, filter on `namespace=autoscaling_test_job` and the run ID), which carries the job ID and hostname, or the `locked_by` value while it ran. If an EC2 worker took it, ask the user to enqueue it again, at most five times per case. If the k8s worker has taken none after that, stop and report
- [ ] 3.5 Verify the metric with `AWS_PROFILE=cdo aws cloudwatch get-metric-statistics` on namespace `code-dot-org/ActiveJob`, metric `PerformCount`, statistic `Sum`, period 60, over a window around the job, with all four dimensions:
  - `Environment=staging`, `JobName=AutoscalingTestJob`, `Platform=k8s`, `Outcome=success` returns a datapoint
  - the same with `Outcome=failure` returns a datapoint
  - do not use `list-metrics` as the pass condition; a new metric can take up to 15 minutes to be listed
  - if a datapoint is missing after five minutes, stop and investigate in this order before reporting: which worker ran the job, `compute_platform` in the pod, the query's dimensions, the buffer flush (up to 60 seconds), then `PutMetricData` errors in the pod log and the pod's IAM policy
- [ ] 3.6 Verify nothing was renamed:
  - `WaitTime` and `ExecutionTime` for `Environment=staging` still have datapoints after the deploy, with dimensions `Environment` and `JobName` only
  - the staging KEDA ScaledObject for the worker is `Ready` and its `PendingJobCount` trigger is not erroring (`kubectl get scaledobject -n staging -o yaml`, read-only)
- [ ] 3.7 Check the logs for the same two jobs with `kubectl logs` on the staging worker pod:
  - the succeeding job shows `Performing` and `Performed` lines with its job ID
  - the failing job shows an `Error performing` line with the exception
  - if either is missing, record what was seen under Open Questions in `design.md` and report it; do not change any logger
- [ ] 3.8 **(user)** In the Dashboard Sentry project, find the failing job's event by its ActiveJob ID (the `job_id` tag). This check does not block the rollout: if the event is missing, record what was seen under Open Questions in `design.md` and report it; do not change any Sentry configuration
- [ ] 3.9 Note the expected leftovers from the failing smoke job for the user: one failed `delayed_jobs` row, one Honeybadger notice and one Sentry event on staging

## 4. infrastructure: dashboard panel

- [x] 4.1 In `observability/dashboards/grafana/src/dashboards/backend/rails/active-job/overview/index.ts`, add a `jobsPerformedByPlatformPanel` function modelled on `jobsStartedPerMinutePanel`:
  - title "Jobs performed by platform", CloudWatch datasource, `min(0)`, the default legend, an unused panel ID
  - four hidden targets, one per pair of `Platform` (`ec2`, `k8s`) and `Outcome` (`success`, `failure`): `SEARCH('{code-dot-org/ActiveJob,Environment,JobName,Outcome,Platform} Environment="$environment" MetricName="PerformCount" Platform="<p>" Outcome="<o>"', 'Sum', 60)`
  - four visible `SUM(<id>)` targets labelled `ec2 success`, `ec2 failure`, `k8s success`, `k8s failure`
  - overrides colouring the two failure series red
  - a description covering the four points in the panel spec: one count per attempt run by a worker, retries count again; `success` means finished without raising and includes attempts a job chose to skip; jobs killed mid-run and failures before `perform` starts are not counted; no data means unknown, not healthy
- [x] 4.2 Place the panel in the dashboard layout next to "Jobs Started per Minute", shifting later panels down. Do not edit any other panel's queries
- [x] 4.3 Run `yarn typecheck` and `yarn build` in `observability/dashboards/grafana`. Confirm the emitted `activejob-overview` JSON in `dist/` contains the new panel and that every other panel's targets are unchanged from a build of the previous commit
- [ ] 4.4 **(user)** Commit, push, and run the tofu apply for `observability/opentofu/environments/prod`
- [ ] 4.5 Open `activejob-overview` in Grafana with `$environment` set to `staging` and confirm the panel shows the `k8s success` and `k8s failure` samples from task 3, and that the panel renders without error when a pair has no data

## 5. Production rollout

- [ ] 5.1 After the DTP that carries the code-dot-org merge commit, confirm with `AWS_PROFILE=cdo` that `PerformCount` has `Environment=production`, `Platform=ec2` datapoints, and that the production panels that existed before still have data
- [x] 5.2 In `k8s-gitops/docs/production-promotion.md`, add the "Jobs performed by platform" panel to the post-promotion checks, saying:
  - `k8s success` datapoints after the promotion are evidence the worker is taking and finishing jobs; `k8s failure` datapoints need a look
  - no `k8s` data means no recent evidence of completion, not a healthy worker: it may be idle, broken, or unable to push metrics
  - what to check then: `locked_by` on running `delayed_jobs` rows, the pod's restart count and last termination reason, and rows with an old `locked_at` (a job killed mid-run stays locked for up to 4 hours and leaves no metric or Honeybadger notice)
  - the two smoke-test enqueue lines, as a way to produce evidence on demand
- [ ] 5.3 **(user)** Commit and push the runbook edit. It is a document only: no Argo Application is affected, so there is nothing to refresh
- [ ] 5.4 **(user)** Promote a Freight that contains the merge commit to production k8s, following `docs/production-promotion.md`
- [ ] 5.5 After the promotion, confirm `Environment=production`, `Platform=k8s` datapoints appear once the worker has taken a job, and that the panel shows them. If low-priority work has been queued and no datapoint appears, follow the checks from 5.2 before concluding anything
