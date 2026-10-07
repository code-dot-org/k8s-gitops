# Production readiness: P0 tasks as Jira tickets

Every P0 item from [PRODUCTION-READINESS-TASKS.md](PRODUCTION-READINESS-TASKS.md),
written so each one can be pasted into Jira as is. The heading of each item is
the ticket summary; everything under it up to the next heading is the ticket
description. Descriptions are self-contained: the reasoning from
[PRODUCTION-READINESS.md](PRODUCTION-READINESS.md) is folded in, and a `Source`
line at the end points back to the task ID and overview section.

File paths are prefixed with the repository they live in: `k8s-gitops` (this
repo), `code-dot-org` (the application), or `infrastructure` (observability).

## Ticket index

| ID | Summary                                                                         | Depends on             | Unblocks       |
| -- | ------------------------------------------------------------------------------- | ---------------------- | -------------- |
| V1 | Inventory the production database secrets in Secrets Manager                    |                        | B2             |
| V2 | Find out what fails in a staging worker that has no AWS credentials             |                        | B1             |
| V3 | Check whether metrics-server is installed and the dashboard HPAs get metrics    |                        | C1 (P1)        |
| V4 | Confirm the cdo-rails image architecture and which node architectures launch    |                        | C2, C3 (P1)    |
| V5 | Verify that NetworkPolicy is enforced on EKS Auto Mode nodes                    |                        | B6 (P1)        |
| V6 | Confirm Kubernetes Secrets are KMS-encrypted on the cluster                     |                        |                |
| V7 | Confirm the monitoring pipeline is healthy and AMP is receiving cluster samples |                        | E1, E12 (P1)   |
| V8 | Confirm production memcached and Redis are configured and reachable             |                        | G4 (P1)        |
| V9 | Determine what override_dashboard and stack_name do for a worker process        |                        | A10 (P1)       |
| A1 | Let the worker finish long jobs on shutdown (terminationGracePeriodSeconds)     |                        | F2             |
| A2 | Stop the chart from blanking Honeybadger, Sentry, PagerDuty, and Slack keys     |                        | E2, F2         |
| A3 | Decide whether legacy workers keep consuming priority >= 10 after launch        |                        | F2             |
| A4 | Guard against the production worker running as root                            |                        | F2             |
| B1 | Give the worker its own ServiceAccount and IAM role                             | V2                     | E1, F2         |
| B2 | Wire production database secrets through the autoscale-prod stack name          | V1                     | F2             |
| D1 | Turn on EKS control-plane audit logging with CloudWatch retention               |                        | F2, D10 (P2)   |
| E1 | Add a canary job and alert that proves production is draining low-priority work | B1, V7                 | F2             |
| E2 | Confirm a worker exception reaches Honeybadger                                  | A2                     | F2             |
| F1 | Write the production promotion checklist                                        |                        | F2             |
| F2 | Launch gate: enable the production deployment                                   | all of the above, F6   |                |

Note: F2 also lists F6 (production Application safety settings, a P1 task) as a
precondition. Create that ticket too if you want the dependency graph complete.

---

## Live checks

These were inferred from reading code and need a live answer before the fixes
that depend on them are designed. They are read-only. Record the answer next to
the matching item in `PRODUCTION-READINESS-TASKS.md`.

### V1: Inventory the production database secrets in Secrets Manager

The production ExternalSecret reads `production/cdo/*` and
`CfnStack/production/*`, but the legacy production CloudFormation stack is named
`autoscale-prod`, so the `CfnStack/production/*` lookup finds nothing. The
worker will only get `db_writer` and `db_reader` if they exist under
`production/cdo/`. The app's `!StackSecret` keys (`db_endpoint_proxy_reporting`,
`db_credential_reader`, `db_endpoint_writer`, and the rest used by
`code-dot-org: dashboard/config/database.yml`) resolve through the IMDS-less
fallback to `production/cdo/<key>` because pods set
`AWS_EC2_METADATA_DISABLED=true`. We do not know which of those keys exist or
are current.

What to do:

- List every `production/cdo/db_*`, `production/cdo/db_endpoint_*`, and
  `production/cdo/db_credential_*` secret in Secrets Manager and note whether
  each is current or a frozen legacy value.
- List `CfnStack/autoscale-prod/*` and note whether it holds the RDS Proxy
  endpoints (reader, writer, reporting, host and port).
- Read-only. Do not modify any `production/cdo/*` secret.
- Record the inventory in the task list next to V1.

Done when: the key inventory is written down and B2 can be designed from it.

Unblocks: B2.

Source: PRODUCTION-READINESS-TASKS.md V1; PRODUCTION-READINESS.md 4.3.

### V2: Find out what fails in a staging worker that has no AWS credentials

The chart creates no ServiceAccount and sets no IRSA annotation, and pods
disable IMDS, so the worker currently has no AWS credentials at all. The jobs
and the Rails runtime touch CloudWatch (`PutMetricData` from every job), DCDO
and Gatekeeper tables in DynamoDB, Secrets Manager (fallthrough for any
secret-marked key not in the Kubernetes Secret), and S3. The metrics pusher
batches asynchronously and may fail silently, so the breakage may be invisible
today.

What to do:

- Observe a running `cdo-active-job-worker` pod in the `staging` namespace while
  low-priority jobs run.
- Confirm whether CloudWatch metric pushes from `ActiveJobMetrics` succeed
  (look for pod-origin samples in the `code-dot-org/ActiveJob` namespace, or
  credential errors in the worker log).
- Confirm whether DCDO (DynamoDB) reads succeed or silently fall back to
  defaults.
- Note anything else that fails for lack of credentials (Secrets Manager
  fallthrough, S3).
- Record the findings in the task list next to V2.

Done when: there is a written list of what breaks without credentials, which
sets the minimum IAM policy for B1.

Unblocks: B1.

Source: PRODUCTION-READINESS-TASKS.md V2; PRODUCTION-READINESS.md 4.2.

### V3: Check whether metrics-server is installed and the dashboard HPAs get metrics

The chart's HPA targets `cdo-dashboard` on CPU and memory utilization and needs
metrics-server. It is not in the EKS add-ons in tofu (Auto Mode does not bundle
it) and there is no `apps/*` app that installs it. The staging and test HPAs may
be inert.

What to do:

- Run `kubectl get apiservice v1beta1.metrics.k8s.io` and `kubectl top pods -n staging`.
- Run `kubectl describe hpa -n staging` and `-n test` and check whether current
  utilization is reported or shows `<unknown>`.
- Record the findings in the task list next to V3.

Done when: it is known whether metrics-server exists, so C1 (P1) can be scoped
as either an install or removal of the HPAs.

Unblocks: C1 (P1).

Source: PRODUCTION-READINESS-TASKS.md V3; PRODUCTION-READINESS.md 5.1.

### V4: Confirm the cdo-rails image architecture and which node architectures launch

The `frontend` NodePool has no `kubernetes.io/arch` requirement, so EKS Auto
Mode may choose Graviton (arm64) capacity. If `ghcr.io/code-dot-org/cdo-rails`
is amd64 only, this becomes a CrashLoopBackOff with an exec format error the
first time a worker lands on an arm64 node.

What to do:

- Inspect the manifest list for `ghcr.io/code-dot-org/cdo-rails` (for example
  `docker manifest inspect` or `crane manifest`) and list the platforms it
  provides.
- List the nodes the `frontend` NodePool has launched and their
  `kubernetes.io/arch` label.
- Record the findings in the task list next to V4.

Done when: both answers are written down so C2 and C3 (P1) know whether an
`amd64` requirement is needed.

Unblocks: C2, C3 (P1).

Source: PRODUCTION-READINESS-TASKS.md V4; PRODUCTION-READINESS.md 4.6.

### V5: Verify that NetworkPolicy is enforced on EKS Auto Mode nodes

There is no NetworkPolicy anywhere in the cluster today, and the plan for the
production namespace (B6, P1) is default-deny ingress and egress with explicit
allows. EKS Auto Mode enforces NetworkPolicy through the built-in VPC CNI
agent, but that has not been verified on this cluster.

What to do:

- Create a throwaway namespace with two pods. Confirm they can reach each other
  and resolve DNS.
- Apply a deny-all ingress and egress NetworkPolicy. Confirm pod-to-pod traffic
  and DNS are blocked. Note whether egress is enforced, not only ingress.
- Remove the policy, confirm traffic flows again, delete the namespace.
- Record the findings in the task list next to V5.

Done when: it is known whether (and how completely) NetworkPolicy is enforced.

Unblocks: B6 (P1).

Source: PRODUCTION-READINESS-TASKS.md V5; PRODUCTION-READINESS.md 4.4.

### V6: Confirm Kubernetes Secrets are KMS-encrypted on the cluster

`cdo-external-secrets` holds 50 or more keys in one Kubernetes Secret. The
terraform-aws-eks module v21 envelope-encrypts Secrets with a KMS key by
default, but nobody has confirmed the key exists and `encryption_config` is set
on this cluster.

What to do:

- Run `aws eks describe-cluster --name codeai-k8s` and check `encryptionConfig`
  for a KMS key ARN with the `secrets` resource.
- Confirm the KMS key exists and its key policy allows the cluster role.
- Check `k8s-gitops: bootstrap/codeai-k8s/cluster/eks-cluster.tf` for the module
  setting that controls it.
- Record the findings in the task list next to V6.

Done when: encryption at rest for Secrets is confirmed, or a follow-up ticket
is opened to enable it.

Source: PRODUCTION-READINESS-TASKS.md V6; PRODUCTION-READINESS.md 4.3.

### V7: Confirm the monitoring pipeline is healthy and AMP is receiving cluster samples

Alloy in `k8s-gitops: apps/monitoring` scrapes kubelet, cAdvisor, and
kube-state-metrics and remote-writes to the shared Amazon Managed Prometheus
workspace with `cluster="codeai-k8s"`. The canary alert (E1) and the open
monitoring rollout tasks depend on this pipeline actually working, and it has
not been confirmed end to end.

What to do:

- In Argo CD, confirm the `monitoring` Application is Healthy and Synced.
- In Grafana Explore on the Prometheus datasource, query
  `up{cluster="codeai-k8s"}` and confirm there are recent samples.
- Record the findings in the task list next to V7.

Done when: both checks pass, or a follow-up ticket describes what is broken.

Unblocks: E1, E12 (P1).

Source: PRODUCTION-READINESS-TASKS.md V7; PRODUCTION-READINESS.md 7.1.

### V8: Confirm production memcached and Redis are configured and reachable

The geo backfill job keeps its progress cursor in `shared_cache`, which lives
in memcached when `memcached_endpoint` is set and falls back to a per-pod
FileStore otherwise. On the file fallback the backfill restarts from zero every
time a pod is replaced. Jobs also need Redis. Both endpoints must be set for
production and reachable from the cluster's private subnets with the security
groups the pods carry.

What to do:

- Confirm the production configuration (secrets and locals) sets
  `memcached_endpoint` and `redis_url`.
- From a pod on the `frontend` NodePool (which carries the same security
  groups production will use), test TCP reachability to the production
  ElastiCache endpoints on 11211 and 6379. Connectivity only; issue no cache
  commands.
- Record the findings in the task list next to V8.

Done when: both endpoints are confirmed set and reachable, or G4 (P1) is scoped
to fix what is missing.

Unblocks: G4 (P1).

Source: PRODUCTION-READINESS-TASKS.md V8; PRODUCTION-READINESS.md 9.

### V9: Determine what override_dashboard and stack_name do for a worker process

The production values were written for a web tier. `locals.yml.override_dashboard`
still lands in the ConfigMap and may affect URL generation in mail or logs sent
by jobs; the worker may need to carry the legacy `studio.code.org` value instead.
`locals.yml.stack_name: autoscale-prod` interacts with `!StackSecret`
resolution in `code-dot-org: lib/cdo/secrets_config.rb`, which normally finds
the stack through EC2 instance metadata (disabled in pods) and falls back to
`<env>/cdo/<key>`.

What to do:

- Read `code-dot-org: lib/cdo/secrets_config.rb` and the URL helpers that
  consume `override_dashboard` and determine how each behaves in a worker
  process with IMDS disabled.
- Decide whether production workers should carry `studio.code.org` as
  `override_dashboard`.
- Determine whether `stack_name` changes StackSecret lookups when IMDS is
  disabled, and whether that matters for B2.
- Record the findings in the task list next to V9.

Done when: the behaviour of both keys for a worker is written down and A10 (P1)
can act on it.

Unblocks: A10 (P1).

Source: PRODUCTION-READINESS-TASKS.md V9; PRODUCTION-READINESS.md 3.6, 3.7.

---

## Fixes

### A1: Let the worker finish long jobs on shutdown (terminationGracePeriodSeconds)

The worker pod template sets no `terminationGracePeriodSeconds` (Kubernetes
default is 30 seconds) and no `preStop` hook. delayed_job handles SIGTERM by
finishing the current job and then exiting, so a SIGKILL at 30 seconds kills
the job mid-run and leaves its `delayed_jobs` row locked until `max_run_time`
expires. Nothing in the repo overrides that, so it is the gem default of 4
hours. A replacement pod has a different `locked_by` name and never reclaims the
row. The two low-priority jobs are the long ones: `AnonymousGeoBackfillingJob`
self-limits at 30 minutes and holds a MySQL advisory lock, and
`AiLessonSummariesJob` loops over every lesson id calling OpenAI. Today any
routine deploy or node replacement can lose work for four hours.

What to do:

- In `code-dot-org: k8s/helm/templates/dashboard/_dashboard.yaml`, add
  `terminationGracePeriodSeconds` to the shared pod template, exposed as the
  value `activeJobWorker.terminationGracePeriodSeconds`.
- In `k8s-gitops: apps/codeai/envTypes/production.values.yaml`, set it to 2100
  (the 1800 second geo backfill cap plus margin). Because delayed_job exits as
  soon as the current job ends, the real wait is the remaining job time, not
  the full period. Rolling updates surge a new pod first, so capacity is not
  lost while the old pod drains.
- Bump the chart `version` in `code-dot-org: k8s/helm/Chart.yaml`.
- Do not lower `Delayed::Worker.max_run_time` as the fix. It is the lock-expiry
  guard for legitimately long jobs and lowering it causes double execution.
- Note for C2 (P1): node-level drains must respect the same window through the
  NodePool `terminationGracePeriod`.

Done when: the rendered production worker carries the value, and a rolling
restart in staging during a running low-priority job lets that job finish.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md A1; PRODUCTION-READINESS.md 3.1.

### A2: Stop the chart from blanking Honeybadger, Sentry, PagerDuty, and Slack keys

`code-dot-org: k8s/helm/templates/cdo-local-secrets.yaml` always renders a
Secret whose `stringData` sets `dashboard_honeybadger_api_key`, `sentry_dsn`,
`sentry_api_key`, `pagerduty_token`, the `slack_*` keys, and friends to empty
strings. It is the last `envFrom` source on the pod, so it overrides the real
values synced from Secrets Manager. The template comment says "TODO: override
keys to DISABLE monitoring services while we get operational". Honeybadger is
the worker's only error path (Sentry and OpenTelemetry activate for web
processes), so until this is fixed a production worker exception reaches
nobody.

What to do:

- Gate the blank overrides behind a values flag that is off by default and
  turned on only in the local development values file
  (`code-dot-org: k8s/helm/development.values.yaml`), or move them into a
  local-dev-only values file entirely.
- Confirm that staging and production render no blank monitoring keys.
- Bump the chart `version` in `code-dot-org: k8s/helm/Chart.yaml`.
- Force a test exception from a staging worker and confirm it appears in
  Honeybadger.

Done when: a staging worker exception appears in Honeybadger.

Unblocks: E2, F2.

Source: PRODUCTION-READINESS-TASKS.md A2; PRODUCTION-READINESS.md 3.6, 7.5.

### A3: Decide whether legacy workers keep consuming priority >= 10 after launch

The Kubernetes worker runs `bin/delayed_job --min-priority 10`, but the legacy
`production-daemon` host's 140 workers still consume priority >= 10 jobs too:
`Cdo::ActiveJobBackend::Command` exposes no min or max priority option, so the
split is one-sided. During a soft launch this is arguably what we want: the
cluster adds capacity and a cluster outage is invisible to users. It also means
a cluster outage is invisible to operators, because legacy quietly picks up the
slack. This is a product and operations decision, not a technical one, and it
needs to be made and written down before launch.

What to do:

- Decide between a soft launch (legacy keeps consuming priority >= 10 alongside
  the cluster) and a hard cutover (low-priority jobs run only on the cluster).
- Write the decision and its date into `PRODUCTION-READINESS-TASKS.md` next to
  A3.
- If the decision is "cluster only", add `--max-priority 9` support to the
  legacy launcher in `code-dot-org: lib/cdo/active_job_backend.rb` and plan to
  flip it in the same change window as the production enable (F2).

Done when: the decision is written down with its date, and any launcher change
it requires is merged.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md A3; PRODUCTION-READINESS.md 3.8.

### A4: Guard against the production worker running as root

Pod `runAsUser`, `runAsGroup`, and `fsGroup` come from the chart-wide
`user.uid` and `user.gid` values (default 1000). The staging and test
deployment values set `uid: 0` and `gid: 0`, so those workers run as root. The
production values correctly do not, but nothing prevents a copy-paste from
landing uid 0 in production. The container security context today is only
`allowPrivilegeEscalation: false`, so running as root would be a real exposure.

What to do:

- Confirm `k8s-gitops: apps/codeai/deployments/production/values.yaml` and
  `apps/codeai/envTypes/production.values.yaml` do not set `user.uid: 0` or
  `user.gid: 0`.
- Add a CI invariant that renders the production deployment with
  `helm template` and fails if the worker's `runAsUser` is 0. Put it in the
  repo CI described by F3 (P1); if F3 has not landed yet, add it as a
  standalone GitHub Actions check so it exists before launch.

Done when: CI fails on a uid 0 in production values.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md A4; PRODUCTION-READINESS.md 3.5.

### B1: Give the worker its own ServiceAccount and IAM role

The chart creates no ServiceAccount and sets no `serviceAccountName`; pods run
as `default` with no IRSA annotation and IMDS disabled, so the worker has no
AWS credentials. Per the legacy `CDOPolicy` and the job code, the runtime needs
`cloudwatch:PutMetricData` (every job emits metrics), `secretsmanager:GetSecretValue`
on `production/cdo/*` (runtime fallthrough for secret-marked keys), DynamoDB
`GetItem`, `PutItem`, and `Scan` on the DCDO and Gatekeeper tables, S3 on the
user-content bucket and `cdo-ai`, `logs:*` on `production-*` log groups once
logs ship to CloudWatch, and for AI jobs SageMaker `gen-ai-*`, Bedrock, and
Comprehend. The two low-priority jobs need at least CloudWatch, DCDO, Secrets
Manager, and Redis. The repo convention for pod identity is IRSA through
Crossplane, the same way the ESO roles are created.

What to do:

- Chart (`code-dot-org: k8s/helm`): add `serviceAccount.create`,
  `serviceAccount.name`, and `serviceAccount.annotations` values, wire
  `serviceAccountName` into the pod spec, and default
  `automountServiceAccountToken: false`. Bump the chart `version`.
- IAM (`k8s-gitops: apps/infra/standard-envtypes/chart/templates/aws/`): add a
  Crossplane `Role` plus `RolePolicy` per envType named `codeai-k8s-app-<env>`,
  with trust on `system:serviceaccount:<env>:cdo-app`, following the pattern in
  `single-namespace-envtypes-iam.yaml`. Build the policy from `CDOPolicy`
  (`code-dot-org: aws/cloudformation/cloud_formation_stack.yml.erb`, lines 77
  to 274) minus what a worker never does, and scope S3 to the production
  buckets only. Bump the chart `version`.
- Tofu (`k8s-gitops: bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`):
  the Crossplane role may only create roles named `codeai-k8s-eso-*`,
  `codeai-k8s-external-dns`, and `codeai-k8s-monitoring-alloy` (lines 249 to
  301). Add `codeai-k8s-app-*` to `iam_role_names`.
- Stay on IRSA rather than EKS Pod Identity unless you are ready to migrate
  every role at once.

Depends on: V2 (sets the minimum policy).

Done when: a staging pod running with the new ServiceAccount pushes a
CloudWatch metric and reads DCDO successfully.

Unblocks: E1, F2.

Source: PRODUCTION-READINESS-TASKS.md B1; PRODUCTION-READINESS.md 4.2.

### B2: Wire production database secrets through the autoscale-prod stack name

`k8s-gitops: apps/infra/standard-envtypes/chart/values.yaml` deliberately
leaves `production` out of `compose_db_url_environment_types` because the
legacy production stack is named `autoscale-prod`, so `CfnStack/production/*`
does not exist in Secrets Manager. The production ExternalSecret still renders a
`find` on `CfnStack/production/db_.*`, which returns nothing, and the IAM policy
grants read on `CfnStack/production/*` only. As a result the worker would get
`db_writer` and `db_reader` only if they exist under `production/cdo/`, and the
other DB keys resolve through a fallback that may point at stale values.
Staging and test compose their MySQL URLs from the live CloudFormation
endpoints; production should work the same way.

What to do:

- Add a per-envType `stack_name` override to the standard-envtypes chart values
  (default equal to the environment name, `production` set to `autoscale-prod`).
- Use `stack_name` in both the IAM resource ARN (`CfnStack/<stack>/*`) in
  `templates/aws/single-namespace-envtypes-iam.yaml` and the ExternalSecret
  `find` path in `templates/_envtype.tpl`.
- Add `production` to `compose_db_url_environment_types` so the MySQL URLs are
  composed from the live CloudFormation endpoints.
- If V1 shows the legacy stack exposes RDS Proxy endpoints, point the worker at
  those so cluster pods do not add raw connections to Aurora.
- Bump the chart `version` in `apps/infra/standard-envtypes/chart/Chart.yaml`.

Depends on: V1.

Done when: `cdo-external-secrets` in the `production` namespace contains
composed `db_writer` and `db_reader` values and the ESO sync status is Ready.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md B2; PRODUCTION-READINESS.md 4.3.

### D1: Turn on EKS control-plane audit logging with CloudWatch retention

`k8s-gitops: bootstrap/codeai-k8s/cluster/eks-cluster.tf` sets
`enabled_log_types = ["api", "authenticator"]` with a note to re-enable `audit`
later. Audit logging was switched off for cost while the cluster was being
rebuilt frequently. For a cluster carrying production work it is a small,
expected line item, and it is the only record of who did what through the API.
GuardDuty EKS Protection (D10, P2) also needs the audit stream.

What to do:

- Add `audit`, `controllerManager`, and `scheduler` to `enabled_log_types`.
- Set an explicit CloudWatch log-group retention for the control-plane log
  group (90 days as a baseline).
- Note the expected monthly cost in the PR so the acceptance is recorded.

Done when: audit events appear in the cluster's CloudWatch log group.

Unblocks: F2, D10 (P2).

Source: PRODUCTION-READINESS-TASKS.md D1; PRODUCTION-READINESS.md 6.1.

### E1: Add a canary job and alert that proves production is draining low-priority work

There are zero alerts for this cluster. Grafana rule groups exist only for
auth, ScriptLevels#show, and GenAI, the root notification policy's contact
point is literally named `test`, and contact points are created by hand in the
UI. Pods being Running does not prove jobs are being processed. One end-to-end
signal is the minimum for launch: a trivial job that runs on the cluster at the
low-priority band and an alert when it stops completing.

What to do:

- In `code-dot-org`, add a trivial canary job at priority 10 that records its
  completion as a CloudWatch metric (or a database row), and enqueue it every
  10 to 15 minutes. A cron on the legacy daemon is fine to start; a Kubernetes
  CronJob can replace it later.
- In `infrastructure: observability`, add a Grafana alert rule that fires when
  no canary completed in the last 45 minutes.
- Route it to a real contact point: a Slack channel the infrastructure group
  reads, with PagerDuty for the critical version once someone is on call for
  this workload.

Depends on: B1 (the worker needs CloudWatch credentials to record completion),
V7 (the alerting pipeline must be healthy).

Done when: stopping the staging worker fires the alert in the Slack channel.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md E1; PRODUCTION-READINESS.md 7.2.

### E2: Confirm a worker exception reaches Honeybadger

Honeybadger is the worker's only error-reporting path, and until A2 ships the
chart blanks its API key. This is the verification step that closes A2: a
deliberately raised exception from a worker running the fixed chart must be
visible in the Honeybadger project for dashboard before the first production
job runs.

What to do:

- After A2 is merged and deployed, force a test exception from a staging
  worker running the production-style configuration and confirm it appears in
  Honeybadger with the expected environment tag.
- Immediately after F2 enables production, repeat the test from a production
  worker and confirm it appears. This step is also on the promotion checklist
  (F1).

Depends on: A2.

Done when: the test exception is visible in Honeybadger from a worker on the
cluster.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md E2; PRODUCTION-READINESS.md 7.5.

### F1: Write the production promotion checklist

Kargo promotes whatever image digest passed `test`, with a manual gate before
`production`. The `cdo-rails` image has no migrations and there is no migrate
Job; schema changes arrive only through the legacy production deploy. A
cluster worker running a commit newer than legacy production can hit a schema
it does not have and fail jobs in confusing ways, while running behind is
generally safe. Until promotion verification is automated (F9, P2), a written
checklist is the control that a human follows at the gate.

What to do:

- Write a `docs/` page in `k8s-gitops` and link it from the Kargo project
  (`apps/kargo/projects/codeai`).
- Record the rule: production freight must be built from a commit at or behind
  the commit legacy production is currently running.
- Checklist items for every production promotion: the image digest equals what
  `test` is running; the image's source commit is at or behind legacy
  production; a Honeybadger test exception from the cluster is visible; the
  canary alert (E1) is green after promotion.
- Note the drain wait implied by A1 when describing rollout and rollback
  timing.

Done when: the checklist is linked from the Kargo project and was used for the
first production promotion.

Unblocks: F2.

Source: PRODUCTION-READINESS-TASKS.md F1; PRODUCTION-READINESS.md 3.9, 8.2.

### F2: Launch gate: enable the production deployment

`k8s-gitops: apps/codeai/deployments/production/deployment.yaml.disabled` is
the gate. Renaming it creates the `codeai-production` Argo CD Application and
starts the first production worker. The file currently carries
`branch: staging` with a FIXME; for production the chart must come from the
`production` branch, otherwise the promoted image digest and the chart (staging
HEAD) diverge. The `image` value in the production values file is also stale
(an old `ghcr.io/code-dot-org/code-dot-org:git-...` tag); the first Kargo
promotion rewrites it to a `cdo-rails@sha256:` digest. Do not do this before
every precondition below is done.

What to do:

- Confirm every precondition is complete: A1, A2, A3, A4, B1, B2, D1, E1, E2,
  F1, and F6 (production Application safety settings, P1).
- Rename `deployment.yaml.disabled` to `deployment.yaml`.
- Set `branch: production` in it.
- Pin `image` in `apps/codeai/deployments/production/values.yaml` to the digest
  `test` is running, or let the first Kargo promotion rewrite it before Argo
  syncs.
- Add a `production` entry to
  `bootstrap/codeai-k8s/cluster-infra-argocd/bin/check-phase-deployment-status`,
  which today checks only `staging-cdo-dashboard` and `test-cdo-dashboard`.
- Follow the promotion checklist (F1) for the first promotion.

Depends on: A1, A2, A3, A4, B1, B2, D1, E1, E2, F1, F6.

Done when: the `codeai-production` Application is Healthy and the canary job
completes on the cluster.

Source: PRODUCTION-READINESS-TASKS.md F2; PRODUCTION-READINESS.md 4.1.
