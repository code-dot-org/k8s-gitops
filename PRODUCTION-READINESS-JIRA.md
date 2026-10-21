# Production readiness: P0 tasks as Jira tickets

Every P0 item from [PRODUCTION-READINESS-TASKS.md](PRODUCTION-READINESS-TASKS.md),
plus follow-up tickets filed from live-check findings (marked P1 in the index),
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
| C6 | Stop every worker promotion from waiting on a node launch (P1)                  | V4                     | C2, C3 (P1)    |
| D1 | Turn on EKS control-plane audit logging with CloudWatch retention               | D14                    | F2, D10 (P2)   |
| D14 | Stop Crossplane providers fighting over the shared crossplane-aws SA (P1)      |                        | D1, D10 (P2)   |
| E1 | Add a canary job and alert that proves production is draining low-priority work | B1, V7                 | F2             |
| E2 | Confirm a worker exception reaches Honeybadger                                  | A2                     | F2             |
| F1 | Write the production promotion checklist                                        |                        | F2             |
| F2 | Launch gate: enable the production deployment                                   | all of the above, F6   |                |
| G4 | Publish memcached_endpoint and redis_url from the CloudFormation stack (P1)     | V8                     |                |

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

**Resolution (2026-10-15, read-only checks, nothing modified)**

**metrics-server:** absent. `kubectl get apiservice v1beta1.metrics.k8s.io` is
NotFound, `kubectl top pods -n staging` returns `Metrics API not available`,
and no metrics-server pod runs in any namespace. The only metrics APIService
on the cluster is `v1.metrics.eks.amazonaws.com` (the EKS extension metrics
API), which is not the resource metrics API. Auto Mode confirmed not to bundle
it.

**HPAs:** none. `kubectl get hpa -A` returns no resources, so there was nothing
to `describe`. The chart gates `templates/dashboard/autoscaler.yaml` on
`dashboard.enabled && autoscaling.enabled`, and `dashboard.enabled` keeps the
chart default `false` in every envType and deployment in this repo. `staging`
and `test` each run exactly one Deployment, `<env>-cdo-active-job-worker`.
The HPAs are not inert; they were never rendered.

**Conclusion:** nothing deployed today depends on metrics-server. The
`autoscaling.enabled`, `minReplicas`, and `maxReplicas` values in the `test`
and `production` envTypes and in the `staging`, `test`, and `production`
deployment values are dead config. The worker's replica count comes from
`activeJobWorker.replicas` (chart default 1), falling back to
`autoscaling.replicasWhenAutoscaleDisabled`.

**Scope handed to C1:** the HPA half is moot, the worker was never autoscaled.
Remove the dead `autoscaling` values and set `activeJobWorker.replicas`
explicitly per PRODUCTION-READINESS.md 5.2 Phase 1. metrics-server itself is
only needed for `kubectl top` and any future CPU or memory scaler (a KEDA
queue-depth trigger does not need it). Install it as an `apps/infra` app or as
the managed EKS add-on (`metrics-server` v0.9.0-eksbuild.11 is the default for
this 1.35 cluster) when wanted; it is not on the launch path.

Done when: it is known whether metrics-server exists, so C1 (P1) can be scoped
as either an install or removal of the HPAs. (Done: recorded next to V3 in
PRODUCTION-READINESS-TASKS.md on 2026-10-15.)

Unblocks: C1 (P1).

Source: PRODUCTION-READINESS-TASKS.md V3; PRODUCTION-READINESS.md 5.1.

### V4: Confirm the cdo-rails image architecture and which node architectures launch

The `frontend` NodePool has no `kubernetes.io/arch` requirement, so EKS Auto
Mode may choose Graviton (arm64) capacity. If `ghcr.io/code-dot-org/cdo-rails`
were amd64 only, this would become a CrashLoopBackOff with an exec format error
the first time a worker landed on an arm64 node.

**Resolution (2026-10-15, read-only checks, nothing modified)**

**Image:** `ghcr.io/code-dot-org/cdo-rails` is multi-arch. The digest pinned by
the staging worker Deployment has a manifest list with `linux/amd64` and
`linux/arm64` (`docker manifest inspect`).

**Nodes:** the `frontend` NodePool has launched only arm64 so far: both current
nodes are `t4g.large`. The `general-purpose` pool is all amd64. The pool has no
arch or instance-type requirement, so Karpenter picks the cheapest node that
fits one worker (`kubectl get nodes,nodeclaims` with the arch and instance-type
labels).

**Conclusion:** no exec-format risk. An `amd64` requirement in C2/C3 is a cost
and performance choice, not a correctness need.

**Side finding:** a `t4g.large` holds exactly one worker (allocatable ~1.8 vCPU
and ~7 GiB against a 1 vCPU, 4 GiB request). Every Kargo promotion surges a
second pod, which sits Pending for the two to four minutes Karpenter needs to
launch a node. The old worker keeps running, so this is a routine scale-up
transient, not a capacity failure. Not a launch blocker.

**Folded into C2/C3:** pick a node size that holds two workers or accept one
node per worker, and set `limits` on the pool so a values typo cannot launch
dozens of nodes.

Done when: both answers are written down so C2 and C3 (P1) know whether an
`amd64` requirement is needed. (Done: recorded next to V4 in
PRODUCTION-READINESS-TASKS.md on 2026-10-15.)

Unblocks: C2, C3 (P1).

Source: PRODUCTION-READINESS-TASKS.md V4; PRODUCTION-READINESS.md 4.6.

### V5: Verify that NetworkPolicy is enforced on EKS Auto Mode nodes

There is no NetworkPolicy anywhere in the cluster today, and the plan for the
production namespace (B6, P1) is default-deny ingress and egress with explicit
allows. The readiness plan assumed EKS Auto Mode enforces NetworkPolicy through
the built-in VPC CNI agent; that had not been verified on this cluster.

What was found (2026-10-15, read-only checks against `codeai-k8s` plus the AWS
Auto Mode documentation):

- NetworkPolicy is not enforced today. On Auto Mode the Network Policy
  Controller is off until a ConfigMap `amazon-vpc-cni` in `kube-system` sets
  `enable-network-policy-controller: "true"`. That ConfigMap does not exist on
  this cluster. The policy CRDs are installed and there are zero PolicyEndpoint
  objects, so a policy applied now is accepted and ignored.
- Once enabled, enforcement runs on the node agent already present on every
  Auto Mode node, including the custom `frontend` NodeClass, for both ingress
  and egress.
- DNS is node-local: pods resolve against `172.20.0.10` (the `.10` of the
  service CIDR) and there is no `kube-dns` Service. B6's DNS allow must be an
  `ipBlock` for `172.20.0.10/32`, not a selector.
- Both NodeClasses use `networkPolicy: DefaultAllow`, so a new pod is allow-all
  until its policy reaches the node. B6 should set `DefaultDeny` on the
  production NodeClass.

(Decided 2026-10-15: the throwaway-namespace probe was skipped. The question it
would answer is settled by the missing ConfigMap, and the meaningful test is
B6's real policy rolled to `staging` first. B6 now owns enabling the
controller.)

Done when: the findings above are recorded next to V5 and folded into B6.

Unblocks: B6 (P1).

Source: PRODUCTION-READINESS-TASKS.md V5; PRODUCTION-READINESS.md 4.4.

### V6: Confirm Kubernetes Secrets are KMS-encrypted on the cluster

`cdo-external-secrets` holds 50 or more keys in one Kubernetes Secret. The
terraform-aws-eks module v21 envelope-encrypts Secrets with a KMS key by
default, but nobody has confirmed the key exists and `encryption_config` is set
on this cluster.

**Resolution (2026-10-15, read-only checks, nothing modified)**

**Cluster:** `aws eks describe-cluster --name codeai-k8s` reports
`encryptionConfig` with `resources: ["secrets"]` and a customer-managed KMS
key, `alias/eks/codeai-k8s`
(`arn:aws:kms:us-east-1:475661607190:key/818d51d1-b43d-460d-8beb-502fb8884606`).

**Key:** Enabled, `SYMMETRIC_DEFAULT`, `KeyManager: CUSTOMER`, no deletion
scheduled, created 2026-04-14 alongside the cluster. Automatic rotation is on
with a 365 day period; next rotation 2027-04-14.

**Key policy:** three statements. The account root has `kms:*`. The two roles
in `cluster_admin_role_arns` (`GoogleSignInAdmin`, `Engineering_FullAccess`)
have key administration. The cluster role
`codeai-k8s-cluster-20260415034802182900000002`, which is the `roleArn` that
`describe-cluster` reports, has `Encrypt`, `Decrypt`, `GenerateDataKey*`,
`ReEncrypt*`, and `DescribeKey`. Nothing else can use the key.

**Tofu:** `bootstrap/codeai-k8s/cluster/eks-cluster.tf` sets only
`kms_key_administrators = var.cluster_admin_role_arns`. The key, the
`encryption_config` scoped to `secrets`, the encryption policy attachment,
rotation, and the default key policy all come from terraform-aws-eks v21
defaults (`create_kms_key`, `attach_encryption_policy`,
`enable_kms_key_rotation`, `kms_key_enable_default_policy`). Nothing is
pinned explicitly, so re-check after any major module bump.

**Conclusion:** Secrets are envelope-encrypted at rest with a customer-managed,
rotating KMS key that only the cluster role can use. No follow-up ticket.
Side note: `cdo-external-secrets` in `staging` holds 167 keys, not 50.

Done when: encryption at rest for Secrets is confirmed, or a follow-up ticket
is opened to enable it. (Done: confirmed and recorded next to V6 in
PRODUCTION-READINESS-TASKS.md on 2026-10-15.)

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

**Resolution (2026-10-15, code reading plus read-only cluster checks, nothing modified)**

**How the keys reach the worker:** the locals ConfigMap is injected with the
`CDO_` prefix, and `lib/cdo.rb` loads ENV before `locals.yml`,
`config/<env>.yml.erb`, and `config.yml.erb` with a reverse-merge that keeps
the first value. The gitops values therefore win over every config file.
Confirmed on the live staging worker: `CDO_stack_name=staging`,
`CDO_override_dashboard=studio.staging.k8s.code.org`,
`AWS_EC2_METADATA_DISABLED=true`.

**override_dashboard:** one consumer, `Cdo::Impl#canonical_hostname`
(`lib/cdo.rb:88`), which returns it whenever the domain is `studio.code.org`.
That feeds `dashboard_hostname`, `dashboard_site_host`, `CDO.studio_url`, Rails
`routes.default_url_options[:host]`, and
`action_mailer.default_url_options[:host]` (`dashboard/config/application.rb`),
so it rewrites every absolute studio URL a job or mailer builds. It does not
touch logs. In the production env with no override, `canonical_hostname`
returns `studio.code.org` outright, and the legacy `autoscale-prod` stack sets
no override: the chef bootstrap sets one only for adhoc stacks. The current
value `studio.production.k8s.code.org` has no DNS record and no Ingress
(`dashboard.enabled` is false), so any link a k8s job emitted would be dead.

Exposure today is latent. The worker runs `--min-priority 10`; only the
`low_priority` queue maps to priority 10 (`active_job_queue_priorities` in
`config.yml.erb`), and its two jobs, `AiLessonSummariesJob` and
`AnonymousGeoBackfillingJob`, build no URLs. `mailers`, `mailjet`, and
`default` are priority 0 and never run on k8s. It becomes live the moment A3
widens the priority range or a low-priority job grows a link.

**Decision:** production workers should not carry
`studio.production.k8s.code.org`. Remove `locals.yml.override_dashboard` from
the production values rather than set it to `studio.code.org`; the env already
yields that. The same reasoning applies to staging, test, and levelbuilder
(`studio.staging.k8s.code.org` does not resolve; the legacy
`staging-studio.code.org` does). In the chart the key doubles as the Ingress
host (`templates/dashboard/ingress.yaml`), so it should come back only
together with `dashboard.enabled: true`.

**stack_name and StackSecret:** no interaction.
`StackSecret.current_stack_name` reads only EC2 metadata
(`AWS::EC2.instance_id`, then `ec2:DescribeTags` for
`aws:cloudformation:stack-name`) and never `CDO.stack_name`. With IMDS
disabled it returns nil, so no `CfnStack/<stack>/` path is attempted. More to
the point, `!StackSecret` appears only in `config/adhoc.yml.erb`; a
production, staging, test, or levelbuilder worker never evaluates one.
Stack-specific DB secrets on k8s are resolved outside Ruby by the
standard-envtypes ExternalSecret, whose `cfn_stack_name_overrides` maps
production to `autoscale-prod`. That is B2's mechanism, and
`locals.yml.stack_name` plays no part in it.

**stack_name elsewhere:** the only runtime readers in a worker are
`codeprojects_hostname` and `codeaiprojects_hostname`, and only outside
production (production returns the fixed apex domains). Everything else is
deploy tooling (`rake stack`, `rake adhoc`, CloudFormation, EC2 autoscaling)
or the web-only `browser_events_controller`. The gitops values (`staging`,
`test`, `levelbuilder`, `autoscale-prod`) equal the code defaults
(`config.yml.erb` `stack_name: <%=env%>`, `config/production.yml.erb`
`stack_name: autoscale-prod`) in every environment, so the key is redundant.
Harmless; drop it or comment it as a no-op in A10.

**Side finding (code reading only, not executed):** the "fall back to
`<env>/cdo/<key>`" comment in `secrets_config.rb` does not hold when no stack
is found. `StackSecret#lookup` calls `super`, and `Secret#lookup` calls `key`,
which dispatches back to `StackSecret#key` and returns nil, so the fallback
appears to call `get!(nil)` and re-raise. Unreachable for non-adhoc workers,
and for adhoc the ConfigMap or ESO env overrides the affected keys before the
Secret object exists. Not a launch item.

Done when: the behaviour of both keys for a worker is written down and A10 (P1)
can act on it. (Done: recorded next to V9 and A10 in
PRODUCTION-READINESS-TASKS.md on 2026-10-15.)

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
- Guard it in the chart: make
  `code-dot-org: k8s/helm/templates/dashboard/_dashboard.yaml` fail the render
  when `RAILS_ENV` is `production` and `user.uid` or `user.gid` is 0, and bump
  the chart version. Argo CD then refuses the change on every render, whether
  it arrived by PR, direct push, or bot commit, and keeps the last good
  manifests running. (Decided 2026-10-14: this repo has no CI and F3 is P1, so
  the CI form of this invariant moves to F3.)

Done when: `helm template` of the production deployment fails with
`--set user.uid=0`, and the chart change is merged to the `code-dot-org`
branch that production pins.

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

### C6: Stop every worker promotion from waiting on a node launch

The `frontend` NodePool has no instance-size requirement, so Karpenter picks
the cheapest node that fits one worker: today an arm64 `t4g.large` (2 vCPU,
8 GiB). Allocatable is about 1780m CPU and 7 GiB; the worker requests 1000m and
4 GiB, so exactly one worker fits per node. The worker Deployment runs one
replica with RollingUpdate (`maxUnavailable: 25%` rounds to 0), so every Kargo
promotion surges a second pod. That pod reports `FailedScheduling`
(`Insufficient cpu`, `Insufficient memory`) for the two to four minutes
Karpenter needs to launch and register a new node. The old worker keeps running
the whole time, so no work is lost; the cost is a slower promotion and a node
launch per rollout. Seen in `staging` on 2026-10-14 (V4). The production pool
from C2 will inherit the same behaviour unless its sizing is chosen on purpose.

What to do:

- Choose one:
  - Size nodes for two workers. Add a NodePool requirement such as
    `karpenter.k8s.aws/instance-memory` of at least 16384, or an instance-size
    list (`large` is too small, `xlarge` fits two), so the surge pod lands on
    the node that is already running.
  - Keep a warm node. Use an Auto Mode static-capacity pool, or a low-priority
    placeholder pod that the surge pod preempts.
  - Accept the wait. Document it in the promotion checklist (F1) so nobody
    reads a `FailedScheduling` event as a failed promotion.
- Do not switch the Deployment to `Recreate`. With the A1 grace period (2100
  seconds) that leaves production without a worker for up to 35 minutes per
  promotion.
- In every case set `limits.cpu` and `limits.memory` on the pool so a values
  typo cannot launch dozens of nodes.
- Apply the choice to
  `k8s-gitops: apps/infra/networking/chart/templates/frontend-nodepool.yaml`
  now (bump the chart version), and to the production NodePool when C2 creates
  it.

Done when: a staging promotion schedules the surge pod without a
`FailedScheduling` event, or the wait is written into F1; and the pool has
`limits`.

Depends on: V4 (done). Pair with: C2, C3.

Source: PRODUCTION-READINESS-TASKS.md C6; PRODUCTION-READINESS.md 4.6, 5.3.

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

**Status (2026-10-19, read-only `aws` and `kubectl get --raw /metrics`; one
tofu edit made, not yet applied)**

Edit made: `k8s-gitops: bootstrap/codeai-k8s/cluster/eks-cluster.tf` now
enables `api`, `audit`, `authenticator`, `controllerManager`, and `scheduler`,
and sets `cloudwatch_log_group_retention_in_days = 90` explicitly. The live log
group `/aws/eks/codeai-k8s/cluster` is already at 90 days (the module default,
STANDARD class, 1.2 GB stored), so the plan should change only the cluster's
logging configuration. The cluster itself shows `deletionProtection: false`
(that is D-series P1 work, noted here only because it was in the same output).

Cost check before applying: the April bill that got audit turned off was not
setup/teardown churn. Ingestion was 2-3 GB/day until 2026-04-06, jumped to
80-120 GB/day the day Crossplane was installed, and stayed there until audit
was disabled on 2026-04-15, after which the group has run at 33-35 MB/day. The
cause is still running: the five AWS provider revisions share one
ServiceAccount (`crossplane-aws`) through a single DeploymentRuntimeConfig, and
each reconcile sets itself as the SA's controller owner, which wakes the other
four. Measured on 2026-10-19: about 570 audit events/s across both API servers
(49 M/day), 94% of them from that loop (74% Metadata level, 26%
RequestResponse). Enabling audit today is estimated at $45-130/day, or
$1.6k-4.6k/month with 90-day storage; the April observation sits at the low end
of that range. With the loop fixed (D14) the estimate is 4-12 GB/day, about
$80-200/month including storage.

Order of operations: land D14 first, then apply this edit. If audit must go on
before D14, set a CloudWatch billing alarm first and expect the April rate.

Note for D10: GuardDuty EKS Audit Log Monitoring reads the audit stream from
the EKS control plane directly and does not require CloudWatch delivery, so D10
depends on D14 (noise) more than on this ticket.

Done when: audit events appear in the cluster's CloudWatch log group.

Depends on: D14 (cost).

Unblocks: F2, D10 (P2).

Source: PRODUCTION-READINESS-TASKS.md D1; PRODUCTION-READINESS.md 6.1.

### D14: Stop the Crossplane AWS providers fighting over the shared crossplane-aws ServiceAccount (P1)

Every Crossplane AWS provider in
`k8s-gitops: apps/infra/crossplane/chart/templates/` references one
`DeploymentRuntimeConfig`, `crossplane-aws-runtime-config`
(`aws-runtime-config.yaml`), whose `serviceAccountTemplate.metadata.name` is
`crossplane-aws`. Crossplane re-applies the runtime ServiceAccount on every
ProviderRevision reconcile with that revision as the controller owner. Five
revisions share the object, so each apply replaces the previous owner, the
change wakes the other four revisions, and the cycle never settles. Nothing
reports unhealthy and Crossplane logs nothing, but the API servers see roughly
550 requests/s. Per reconcile: 5 secret GETs, 2 secret PATCHes, one PATCH each
of the ServiceAccount, Service, and Deployment, and a ProviderRevision status
PUT, all no-ops except the owner flip. Measured 2026-10-19 by sampling
`kubectl get --raw /metrics`: `apiserver_request_total` on one of the two API
servers was 94% this pattern (77 M of 82 M requests in 147 h), and the SA's
controller owner was a different revision on each of eight consecutive reads.

Consequences: this is the 80-120 GB/day of audit logs that got audit logging
turned off in April (D1), it is a steady load on the control plane, and it
keeps all five provider deployments reconciling continuously.

What to do:

- Give each provider its own ServiceAccount. Render one
  `DeploymentRuntimeConfig` per provider in the chart (for example
  `crossplane-aws-acm` with SA `crossplane-aws-acm`, and likewise for `iam`,
  `route53`, `s3`, and the provider family), keep the IRSA annotation on each,
  and point each `Provider.spec.runtimeConfigRef` at its own config. Bump the
  chart `version` in `Chart.yaml`.
- Before that, widen the IRSA trust in
  `k8s-gitops: bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`.
  The `sub` condition is `StringEquals` on exactly
  `system:serviceaccount:crossplane-system:crossplane-aws`. Add the new SA
  names to that list (or switch to `StringLike` on `crossplane-aws-*`). Apply
  the tofu change before the chart change, or every provider loses AWS access
  when its pod restarts with the new SA. Remove the old `crossplane-aws` entry
  once the providers are healthy on the new SAs.
- Expect every provider Deployment to roll once. The old `crossplane-aws` SA is
  left behind with a stale owner reference; delete it by hand afterwards.
- Do not take the shortcut of dropping the SA name from the template:
  Crossplane then names the SA after the revision hash, and the trust policy
  would need a wildcard on `provider-aws-*` that changes on every upgrade.

Done when: the resourceVersion of each new provider SA is unchanged a minute
apart, all providers report `HEALTHY=True`, and a fresh
`apiserver_request_total` sample no longer has secrets and providerrevisions
at the top.

Unblocks: D1 (cost), D10 (P2).

Source: live finding while working D1 on 2026-10-19; PRODUCTION-READINESS.md 6.1.

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

### G4: Publish memcached_endpoint and redis_url from the CloudFormation stack (P1)

V8 (2026-10-21) checked the production caches from the cluster. The network
path is already open: the `autoscale-prod` memcached cluster and Redis
replication group sit in the cluster's VPC, their security groups admit only
the legacy frontend security group, and the `frontend` NodeClass puts that
group on the pod ENI of every frontend node. Bare TCP connects from the
staging and test workers reached the memcached configuration endpoint, all
three memcached nodes, and the Redis primary.

What is missing is the configuration. No `production/cdo/memcached_endpoint`
or `production/cdo/redis_url` secret exists, and
`k8s-gitops: apps/codeai/deployments/production/values.yaml` sets neither
under `locals.yml`, so a production worker would boot on the `config.yml.erb`
defaults: no memcached (the geo backfill cursor in `CDO.shared_cache` falls
back to a per-pod FileStore and dies with the pod) and
`redis://localhost:6379/0` (nothing listens; the geocoder's Redis cache fails
open and every lookup goes uncached to Mapbox or freegeoip). Staging runs in
this state today.

Hardcoding the ElastiCache hostnames in gitops is not acceptable. The stack
that owns the caches should publish them, the same way it already publishes
the database endpoints that B2 consumes:
`code-dot-org: aws/cloudformation/components/database.yml.erb` creates
`AWS::SecretsManager::Secret` resources named `CfnStack/${AWS::StackName}/<key>`
whose value is a `!GetAtt`, and the env-type ExternalSecret in
`k8s-gitops: apps/infra/standard-envtypes/chart/templates/_envtype.tpl` syncs
`CfnStack/<stack>/` keys into `cdo-external-secrets`, where the worker reads
them as `CDO_*` env vars. Legacy frontends already get both values from the
same `!GetAtt` expressions via `aws/cloudformation/bootstrap_chef_stack.sh.erb`,
so EC2 and k8s would derive from one source, and a cache rebuild would update
the secret on its own.

What to do:

- In `code-dot-org: aws/cloudformation/components/memcached.yml.erb`, add a
  secret in the shape of `DBWriterEndpointConfig`:
  `CfnStack/${AWS::StackName}/memcached_endpoint` with
  `!Sub "${Memcached.ConfigurationEndpoint.Address}:${Memcached.ConfigurationEndpoint.Port}"`.
- In `code-dot-org: aws/cloudformation/components/redis.yml.erb`, add
  `CfnStack/${AWS::StackName}/redis_url` with
  `!Sub "rediss://${RedisGroup.PrimaryEndPoint.Address}:${RedisGroup.PrimaryEndPoint.Port}"`.
  The scheme must be `rediss://`: the group has in-transit encryption on and
  no auth token.
- Only `autoscale-prod` renders the cache components: it is the one app
  stack with `Op:Frontends=true`. `staging`, `test`, and `levelbuilder` carry
  `Op:Frontends=false` and own no ElastiCache resources (checked
  2026-10-21), so they stay on the FileStore fallback and the widened find
  matches nothing there.
- The `autoscale-prod` update is additive (two new Secret resources, nothing
  modified or replaced) but it is still a production CloudFormation change.
  Run `bundle exec rake stack:validate` for the production env first: it
  renders the template, creates a change set, prints the pending changes, and
  deletes the change set. Expect `No changes` on the current template and
  exactly two `Add` entries once the edit is in. `rake stack:start` prints
  the same list and prompts `Proceed? [y/n]` before executing.
- In `k8s-gitops: apps/infra/standard-envtypes/chart/templates/_envtype.tpl`,
  widen the CfnStack find regex from
  `db_(cluster_id|endpoint_.*|credential_(writer|reader))` to also match
  `memcached_endpoint|redis_url`, and bump the chart version. The IAM role
  already allows `secretsmanager:GetSecretValue` on `CfnStack/<stack>/*`,
  `cfn_stack_name_overrides` already maps production to `autoscale-prod`, and
  a find that matches nothing is harmless, so this can land before the stacks
  publish.
- ESO re-syncs within 5 minutes of the secrets appearing; running pods pick
  the new keys up on their next rollout. The `production` namespace
  ExternalSecret already syncs `CfnStack/autoscale-prod/` (B2 is live), so
  the two keys can be verified in `cdo-external-secrets` there before any
  production worker exists.
- No security-group, NodeClass, or NetworkPolicy change is needed. Do not add
  anything under `production/cdo/*`.
- Once set, the k8s worker shares one cursor key with the legacy production
  workers in the same memcached cluster (see A3).

Done when: `cdo-external-secrets` in `production` carries `memcached_endpoint`
and `redis_url`, `CDO.shared_cache` is a `MemCacheStore` in the production
worker, and the backfill cursor survives a pod replacement.

Depends on: V8 (done). Pair with: A3, B2, F2.

Source: PRODUCTION-READINESS-TASKS.md G4; PRODUCTION-READINESS.md 9.
