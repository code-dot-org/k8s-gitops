# Production readiness overview for codeai-k8s

## Scope

**Going to production first:** the `cdo-active-job-worker` Deployment in the
`production` namespace. It runs `bin/delayed_job --min-priority 10 run`, one
delayed_job process per pod, consuming only priority >= 10 jobs. In the current
codebase that band is the `low_priority` queue, which today holds exactly two
job classes: `AiLessonSummariesJob` and
`ProjectStorage::AnonymousGeoBackfillingJob`
(`../code-dot-org/config.yml.erb:677-690`). Everything else runs at priority 0
and stays on the legacy `production-daemon` EC2 host.

**Not in scope yet:** the dashboard web tier. `dashboard.enabled` defaults to
`false` in the chart, so production renders no `cdo-dashboard` Deployment,
Service, Ingress, or HPA. Several keys in the production values are therefore
no-ops today (see 3.7).

## Priority legend

| Priority | Meaning                                                            |
| -------- | ------------------------------------------------------------------ |
| **P0**   | Do before the first production job runs.                           |
| **P1**   | Do in the first few weeks of running, before anyone depends on it. |
| **P2**   | Do before adding more production workloads, or when time allows.   |

---

## 1. Summary checklist

| Pri | Area       | Item                                                                                                                                    | Where                                                                                                                          |
| --- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| P0  | Worker     | Set `terminationGracePeriodSeconds` to cover the longest low-priority job (30 min today); add chart support                             | `../code-dot-org/k8s/helm/templates/dashboard/_dashboard.yaml`                                                                 |
| P0  | Worker     | Stop `cdo-local-secrets` from blanking Honeybadger, Sentry, PagerDuty, and Slack keys in production                                     | `../code-dot-org/k8s/helm/templates/cdo-local-secrets.yaml`                                                                    |
| P0  | Namespace  | Give the worker its own ServiceAccount and IAM role (IRSA via Crossplane), and extend the Crossplane role-name allowlist                | chart, `apps/infra/standard-envtypes`, `bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`                 |
| P0  | Namespace  | Wire production DB secrets: the legacy stack is `autoscale-prod`, not `production`, so ESO's `CfnStack/production/*` path finds nothing | `apps/infra/standard-envtypes/chart/values.yaml`, `templates/_envtype.tpl`, `templates/aws/single-namespace-envtypes-iam.yaml` |
| P0  | Delivery   | Enable the deployment with `branch: production` so chart and image come from the same line                                              | `apps/codeai/deployments/production/deployment.yaml.disabled`                                                                  |
| P0  | Delivery   | Written rule: k8s production never runs a commit newer than the legacy production deploy (schema coupling)                              | this doc, Kargo promotion checklist                                                                                            |
| P0  | Alerting   | At least one alert that fires when production stops draining low-priority jobs, routed to a real contact point                          | `../infrastructure/observability`                                                                                              |
| P0  | Security   | Turn on EKS `audit` control-plane logging                                                                                               | `bootstrap/codeai-k8s/cluster/eks-cluster.tf`                                                                                  |
| P0  | Decision   | Decide whether legacy workers keep consuming priority >= 10 during the soft launch                                                      | `../code-dot-org/lib/cdo/active_job_backend.rb`                                                                                |
| P1  | Worker     | Worker logs to stdout instead of `log/delayed_job.log`                                                                                  | `../code-dot-org/dashboard/config/initializers/delayed_job_config.rb`                                                          |
| P1  | Worker     | Liveness via a heartbeat plugin plus exec probe; 2 replicas, PDB `maxUnavailable: 1`, topology spread                                   | chart                                                                                                                          |
| P1  | Namespace  | Pod Security Admission labels, ResourceQuota, LimitRange, PriorityClass, default-deny NetworkPolicy                                     | `apps/infra/standard-envtypes`                                                                                                 |
| P1  | Namespace  | Dedicated `production` NodePool/NodeClass with only the security groups production needs, `amd64` requirement, disruption budget        | `apps/infra/networking`                                                                                                        |
| P1  | Security   | Restrict EKS API endpoint CIDRs; add Argo `AppProject` for production; namespace-scope engineer access                                  | `bootstrap/.../eks-cluster.tf`, `apps/infra/argocd`, `apps/codeai/applicationset.yaml`                                         |
| P1  | Security   | Permissions boundary on Crossplane-created roles; tighten Secrets Manager `*` read                                                      | `crossplane-aws.tf`                                                                                                            |
| P1  | Monitoring | Ship container logs to CloudWatch Logs; add k8s and ActiveJob alert rules; contact points in code                                       | `apps/monitoring`, `../infrastructure/observability`                                                                           |
| P1  | Monitoring | Distinguish k8s workers in `code-dot-org/ActiveJob` CloudWatch metrics; fix `ps`-based `WorkerCount`                                    | `../code-dot-org/dashboard/app/jobs/concerns/active_job_metrics.rb`                                                            |
| P1  | Delivery   | CI for this repo (helm template per envType, kustomize build, kubeconform), branch protection with bot bypass, CODEOWNERS               | `.github/` (does not exist yet)                                                                                                |
| P1  | DR         | Move tofu state off `non-prod` keys; cluster deletion protection; rebuild runbook                                                       | `bootstrap/codeai-k8s/*/backend.tf`                                                                                            |
| P1  | Ops        | Runbooks, on-call owner, fix smoke-test paths, refresh stale bootstrap docs                                                             | `bootstrap/codeai-k8s`                                                                                                         |
| P2  | Scaling    | KEDA on `delayed_jobs` queue depth instead of HPA; VPA in recommend mode                                                                | new `apps/infra/keda`                                                                                                          |
| P2  | Delivery   | Promote chart revision together with image digest in Kargo freight; add Kargo verification on `test`                                    | `apps/kargo/projects/codeai`                                                                                                   |
| P2  | Security   | Image signature verification, ValidatingAdmissionPolicy guardrails, GuardDuty EKS protection                                            | cluster                                                                                                                        |
| P2  | Cost       | Cost-allocation tags on NodeClass, NodePool `limits`, reduce 30Gi ephemeral request                                                     | `apps/infra/networking`, production values                                                                                     |

---

## 2. What is already in good shape

Worth stating so the list above does not read as a rebuild.

- GitOps end to end: app-of-apps with `RollingSync` so `infra` converges first
  (`apps/app-of-apps/app-of-apps.yaml`), automated sync with prune and
  self-heal, server-side apply.
- Kargo promotion with immutable image digests and a manual gate on production
  (`apps/kargo/projects/codeai/project-config.yaml` sets
  `autoPromotionEnabled: false` for `production` and `levelbuilder`).
- Per-namespace ESO `SecretStore` backed by a per-envType IRSA role scoped to
  `{env}/cdo/*` and `CfnStack/{env}/*`
  (`apps/infra/standard-envtypes/chart/templates/aws/single-namespace-envtypes-iam.yaml`).
  Adhoc namespaces get a regex-fenced `ClusterSecretStore`. This is the right
  shape for namespace-to-namespace secret isolation.
- SSO through Dex and Google groups for Argo CD and Kargo, with `admin`
  disabled and a documented break-glass path (`apps/infra/argocd/chart/values.yaml`).
- Crossplane IAM confined by a role-name allowlist and tag conditions
  (`bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`).
- A tainted, on-demand `frontend` NodePool that keeps app pods off system nodes
  (`apps/infra/networking/chart/templates/frontend-nodepool.yaml`).
- Metrics: Alloy scraping kubelet, cAdvisor, and kube-state-metrics into the
  shared AMP workspace, with two Kubernetes dashboards already provisioned in
  Grafana (`apps/monitoring`, `../infrastructure/observability/dashboards/grafana/src/dashboards/kubernetes/`).
- `require_external_secrets: true` in every server envType, so a missing
  `cdo-external-secrets` blocks the pod instead of booting with blanks.
- The priority split itself (`priorityMode: low`) is implemented and verified
  by `../code-dot-org/k8s/bin/verify-worker-priorities`.

---

## 3. The worker workload

Facts here come from `../code-dot-org/k8s/helm` (chart `cdo` 0.2.0) and the
delayed_job configuration in `../code-dot-org/dashboard`.

### 3.1 Graceful shutdown (P0)

- The pod template sets no `terminationGracePeriodSeconds` (Kubernetes default
  30 s) and no `preStop` hook (`templates/dashboard/_dashboard.yaml`).
- delayed_job handles SIGTERM by finishing the current job and exiting
  (`raise_signal_exceptions` is left at `false`). A SIGKILL at 30 s leaves the
  job row locked until `max_run_time` expires, which is the gem default of
  **4 hours** because nothing in the repo overrides it
  (`dashboard/config/initializers/delayed_job_config.rb`). A replacement pod
  has a different `locked_by` name and never reclaims the row.
- The legacy launcher gives workers 60 s between TERM and KILL
  (`lib/cdo/active_job_backend.rb:150-172`).
- The two low-priority jobs are the long ones: `AnonymousGeoBackfillingJob`
  self-limits at 30 minutes and holds a MySQL advisory lock;
  `AiLessonSummariesJob` loops over every lesson id and calls OpenAI per item.

Recommendation:

- Add `terminationGracePeriodSeconds` to the chart's pod spec, exposed as
  `activeJobWorker.terminationGracePeriodSeconds`, and set production to at
  least **1800 s** (the geo backfill cap) with margin, for example 2100 s.
  Because delayed_job exits as soon as the current job ends, the real wait is
  the remaining job time, not the full period. Rolling updates surge a new pod
  first, so capacity is not lost while the old pod drains.
- Alternatively shorten the jobs (smaller `limit` per invocation for the
  backfill, chunked lesson lists) so a shorter grace period is honest.
- Do not lower `Delayed::Worker.max_run_time` as the fix. It is the lock-expiry
  guard for legitimately long jobs and lowering it causes double execution.
- Node-level drains must respect the same window; see 5.3 for the NodePool
  `terminationGracePeriod` and disruption budget.

### 3.2 Health signals (P1)

- The worker renders **no** startup, readiness, or liveness probe. Line 39 of
  `templates/dashboard/active-job-worker-deployment.yaml` forces
  `healthChecksEnabled false`, so the envType `healthChecks.enabled: true` has
  no effect on it.
- A wedged worker (lost DB connection loop, stuck HTTP call past its timeout)
  is never restarted. Legacy has the same blind spot: no supervisor, a crashed
  worker stays down until the next deploy.

Recommendation:

- Add a small delayed_job plugin in `code-dot-org` that touches a heartbeat
  file on every loop iteration and on job start/finish, then an `exec`
  liveness probe in the chart that fails when the file is older than N minutes
  (N must exceed the longest expected single job, or the probe must touch the
  file from inside long jobs too). Keep `failureThreshold` generous.
- No readiness probe is needed (no Service), but without one a rollout's new
  pod counts as Ready the moment the container starts. Accept this, or use the
  same heartbeat file as a `startupProbe` so a boot failure is visible as
  Progressing rather than silently CrashLooping.

### 3.3 Replicas, disruption budget, spread (P1)

- `activeJobWorker.replicas` defaults to 1. A node drain, Auto Mode node
  recycle, or consolidation takes the production worker fully offline.
- Chart footgun: `replicas: 0` renders `1` because sprig `default` treats 0 as
  empty (`_dashboard.yaml:58`). Only `enabled: false` removes the worker.
- No PodDisruptionBudget, no `topologySpreadConstraints`, no anti-affinity, no
  `strategy` block, no `revisionHistoryLimit`.

Recommendation:

- Run **2 replicas** in production, add a PDB with `maxUnavailable: 1`, and a
  `topologySpreadConstraints` entry on `topology.kubernetes.io/zone` with
  `whenUnsatisfiable: ScheduleAnyway`. This staggers drains without ever
  blocking node recycling (a `minAvailable: 1` PDB with one replica would block
  it indefinitely).
- Fix the `replicas: 0` rendering so scale-to-zero through values is possible.

### 3.4 Resources (P1/P2)

- Worker requests equal limits: `cpu: 1`, `memory: 4Gi`,
  `ephemeral-storage: 30Gi` (`values.yaml:63-86`). The memory figure was
  measured on a kind cluster; production values add
  `resources.requests.ephemeralStorage: 30Gi` at the chart-wide level too.
- 30Gi of ephemeral storage per worker pod limits bin-packing to a couple of
  pods per default Auto Mode root volume and is far more than a worker that
  builds no assets needs. Because delayed_job logs to a file inside the
  container today (3.6), log growth also counts against it.
- `CDO_ACTIVE_JOB_BACKEND_N_WORKERS_TO_START` and
  `..._ROLLING_RESTART_IN_N_BATCHES` in `extraEnv` are read only by the legacy
  launcher, not by `bin/delayed_job run`. They are inert in the pod.
- `dashboard_workers` sizes the puma web tier, not the worker. The commented
  `dashboard_workers: 32` in `production.values.yaml` is irrelevant to this
  workload.

Recommendation: measure real RSS for the two low-priority jobs in staging,
right-size memory, cut ephemeral storage to single-digit GiB once logs go to
stdout, and remove the inert env vars. Later, run VPA in `Off`/recommend mode
for continuous right-sizing data (P2).

### 3.5 Security context and the root user (P0 check, P1 change)

- Container security context is only `allowPrivilegeEscalation: false`. There
  is no `runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`,
  or `seccompProfile: RuntimeDefault`.
- Pod `runAsUser/runAsGroup/fsGroup` come from chart-wide `user.uid/gid`
  (default 1000). `apps/codeai/deployments/staging/values.yaml` and
  `test/values.yaml` set `uid: 0`/`gid: 0`, so those workers run as root.
  `production/values.yaml` does **not**, which is correct. Guard this with a
  CI check or admission policy so a copy-paste never lands it in production.
- The default ServiceAccount token is automounted and unused.

Recommendation: add `runAsNonRoot: true`, `capabilities.drop: [ALL]`,
`seccompProfile.type: RuntimeDefault`, and `automountServiceAccountToken:
false` to the chart. `readOnlyRootFilesystem` is probably not achievable
without an `emptyDir` for `dashboard/tmp`, `dashboard/log`, and the Rails file
cache; do it with mounts or skip it. These changes are prerequisites for the
`restricted` Pod Security level in 4.4.

### 3.6 Configuration correctness (P0 items marked)

- **Monitoring keys blanked (P0).** `templates/cdo-local-secrets.yaml` always
  renders a Secret whose `stringData` sets `dashboard_honeybadger_api_key`,
  `sentry_dsn`, `sentry_api_key`, `pagerduty_token`, `slack_*` and friends to
  empty strings, and it is the **last** `envFrom` source, so it overrides the
  real values synced from Secrets Manager. The comment says "TODO: override
  keys to DISABLE monitoring services while we get operational". Gate these
  blanks behind a values flag that production leaves off, or move them into a
  local-dev-only values file. Until then production worker exceptions reach
  nothing.
- **Logs to a file (P1).** `delayed_job_config.rb:12` sends the worker logger
  to `log/delayed_job.log`. `kubectl logs` and any future log shipper see
  nothing from jobs. Make the logger honor an env switch (stdout when
  `RAILS_LOG_TO_STDOUT` or a k8s-specific flag is set) and set it in the chart.
- **RAILS_ENV pinned to adhoc.** The chart pins `activeJobWorker.RAILS_ENV:
adhoc` and does not inherit the chart-wide value. The envType files already
  override it (`production.values.yaml` sets `activeJobWorker.RAILS_ENV:
production`). Keep a CI assertion that renders production and greps the
  worker env, since a chart refactor could silently reintroduce adhoc.
- **`!StackSecret` resolution.** `lib/cdo/secrets_config.rb` finds the
  CloudFormation stack name through EC2 instance metadata and
  `ec2:DescribeTags`, then reads `CfnStack/<stack>/<key>`, falling back to
  `<env>/cdo/<key>`. Pods set `AWS_EC2_METADATA_DISABLED=true`, so every
  StackSecret takes the fallback. See 4.3 for what that means for production
  DB endpoints. **Verify** how `locals.yml.stack_name: autoscale-prod`
  interacts with this path.
- Chart hygiene: `Chart.yaml` has no `appVersion` and `version: 0.2.0` has not
  moved with functional changes; `tty: true` on a worker; local-dev MySQL,
  Redis, and MinIO live in the same chart behind flags. Not blockers, but the
  chart is also the production artifact now.

### 3.7 Production values cleanup

`apps/codeai/deployments/production/values.yaml` and
`apps/codeai/envTypes/production.values.yaml` were written for a web tier:

| Key                                                        | Effect for the worker-only production                                                                                                                                                                                        |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `autoscaling.enabled/min/max`                              | No-op. The chart HPA targets `cdo-dashboard` and renders only when `dashboard.enabled`.                                                                                                                                      |
| `healthChecks.enabled: true`                               | No-op for the worker (forced off).                                                                                                                                                                                           |
| `dnsName`, `locals.yml.override_dashboard`                 | No Ingress renders. `override_dashboard` still lands in the ConfigMap and may affect URL generation in mail or logs; **verify** whether the worker should carry the legacy `studio.code.org` value instead.                  |
| `image: ghcr.io/code-dot-org/code-dot-org:git-f666540d...` | Stale: old repository and tag scheme. The first Kargo promotion rewrites it to a `cdo-rails@sha256:` digest. Do not enable production before that promotion has run, or pin it by hand to the same digest `test` is running. |
| `resources.requests.ephemeralStorage: 30Gi`                | Applies chart-wide; see 3.4.                                                                                                                                                                                                 |
| `deploy/` kustomize overlay                                | Parity path only (`kustomize build` mirror, per commit 62f01a92). It references the `code-dot-org` base at `?ref=staging` for production. Keep it in sync or mark it clearly as non-authoritative.                           |

Comment each intentional no-op so the next reader does not assume production
has autoscaling or health checks.

### 3.8 Priority split with the legacy fleet (P0 decision)

- With `--min-priority 10` on k8s, legacy's 140 workers still consume
  priority >= 10 as well: `Cdo::ActiveJobBackend::Command` exposes no
  min/max-priority option (`lib/cdo/active_job_backend.rb:125-135`), so the
  split is one-sided today. `k8s/README.md:128-130` says as much.
- During a soft launch this is arguably desirable: k8s adds capacity and a k8s
  outage is invisible to users. It also means a k8s outage is invisible to
  operators. Decide which you want, write it down, and if the goal is
  "low-priority runs only on k8s", add `--max-priority 9` support to the legacy
  launcher and flip it in the same change window as the production enable.

### 3.9 Schema and code coupling with the legacy deploy (P0 rule)

- The `cdo-rails` image has no migrations and there is no migrate Job
  (`k8s/README.md:51-55`). Schema changes arrive only through the legacy
  production deploy.
- Kargo promotes whatever digest passed `test`, which can be a commit newer
  than what legacy production has deployed. A k8s worker running ahead of the
  schema fails jobs in confusing ways; behind is generally safe.

Rule to adopt now: production freight must be built from a commit at or behind
the commit legacy production is running. Enforce it in the promotion checklist
first, then automate (compare the image's source revision label against the
legacy deploy marker) as part of 8.2.

---

## 4. The production namespace: what to add

The namespace object, ESO `SecretStore`, `ServiceAccount`, and `ExternalSecret`
for `production` are rendered by `apps/infra/standard-envtypes/chart/templates/_envtype.tpl`
because `production` is listed in `single_namespace_environment_types` in the
generated `apps/infra/codeai-cluster-config.values.yaml`. That chart is the
natural place for most namespace-level additions below.

### 4.1 Enabling the deployment (P0)

- `apps/codeai/deployments/production/deployment.yaml.disabled` is the gate.
  It carries `branch: staging` with a FIXME. For production the chart must
  come from the `production` branch, otherwise the image (promoted digest) and
  the chart (staging HEAD) diverge. Set `branch: production` when renaming the
  file. The comment about waiting on DTTs/DTPs/DTLs is about how long the
  `production` branch takes to advance; that is exactly the coupling 3.9 wants.
- Removing or renaming `deployment.yaml` later deletes the Application and, by
  default, cascades to every resource in the namespace. For production
  consider `syncPolicy.preserveResourcesOnDeletion: true` in the
  `codeai` ApplicationSet template (or a production-only template branch) so a
  bad rename does not delete the workload.
- Add a `production` entry to
  `bootstrap/codeai-k8s/cluster-infra-argocd/bin/check-phase-deployment-status`,
  which today checks only `staging-cdo-dashboard` and `test-cdo-dashboard`.

### 4.2 ServiceAccount and IAM for the worker (P0)

- The chart creates no ServiceAccount and sets no `serviceAccountName`; pods
  run as `default` with no IRSA annotation and IMDS disabled. As rendered, the
  worker has **no AWS credentials**.
- What the jobs and the app runtime touch, per the legacy `CDOPolicy`
  (`../code-dot-org/aws/cloudformation/cloud_formation_stack.yml.erb:77-274`)
  and the job code: `cloudwatch:PutMetricData` (every job emits metrics),
  `secretsmanager:GetSecretValue` on `production/cdo/*` (runtime fallthrough
  for any secret-marked key not in the Secret), DynamoDB `GetItem/PutItem/Scan`
  on the DCDO and Gatekeeper tables, S3 on the user-content bucket and
  `cdo-ai`, `logs:*` on `production-*` log groups if logs go to CloudWatch,
  and for AI jobs SageMaker `gen-ai-*`, Bedrock, and Comprehend. The two
  low-priority jobs need at least CloudWatch, DCDO, Secrets Manager, and Redis.
- **Verify** in staging what actually fails today without credentials. The
  metrics pusher batches asynchronously and may fail quietly.

Recommendation:

- Chart: add `serviceAccount.create`, `serviceAccount.name`,
  `serviceAccount.annotations`, wire `serviceAccountName` into the pod spec,
  and default `automountServiceAccountToken: false`.
- IAM: create `codeai-k8s-app-<env>` roles the same way the ESO roles are made
  (Crossplane `Role` plus `RolePolicy` in the standard-envtypes chart, trust on
  `system:serviceaccount:<env>:cdo-app`). Start from `CDOPolicy` minus what a
  worker never does, and scope S3 to the production buckets only.
- Tofu: `crossplane-aws.tf:249-301` restricts the role names Crossplane may
  create to `codeai-k8s-eso-*`, `codeai-k8s-external-dns`, and
  `codeai-k8s-monitoring-alloy`. Add `codeai-k8s-app-*` and, ideally, require
  a permissions boundary on anything Crossplane creates (see 6.5).
- Pod Identity is the simpler AWS mechanism and Auto Mode ships the agent, but
  the repo convention is IRSA via Crossplane. Stay consistent unless you are
  ready to move all roles.

### 4.3 Secrets for production (P0)

- `apps/infra/standard-envtypes/chart/values.yaml` deliberately leaves
  `production` out of `compose_db_url_environment_types` because the legacy
  stack is named `autoscale-prod`, so `CfnStack/production/*` does not exist.
  The production `ExternalSecret` still renders the second `find` on
  `CfnStack/production/db_.*`, which returns nothing, and the IAM policy grants
  only `CfnStack/production/*`.
- Consequence: the worker gets `db_writer`/`db_reader` only from
  `production/cdo/db_writer` and `db_reader`, and the `!StackSecret` keys the
  app also uses (`db_endpoint_proxy_reporting`, `db_credential_reader`,
  `db_endpoint_writer`, and so on, see `dashboard/config/database.yml`) resolve
  via the IMDS-less fallback to `production/cdo/<key>`. **Verify** which of
  those keys exist and are current under `production/cdo/`. (Team note: the
  frozen 2019 `{env}/cdo/db_*` secrets under review for deletion are the
  non-production ones; `production/cdo/*` is out of scope for that cleanup.)

Recommendation:

- Add a per-envType `stack_name` override to the standard-envtypes chart
  (default `= env`, production `= autoscale-prod`) and use it in both the IAM
  resource ARN (`CfnStack/<stack>/*`) and the `ExternalSecret` find path. Then
  add `production` to `compose_db_url_environment_types` so the mysql URLs are
  composed from the live CloudFormation endpoints, matching staging and test.
- Consider pointing the worker at the RDS Proxy endpoints if the legacy stack
  exposes them (the ESO smoke test already reads
  `CfnStack/staging/db_endpoint_proxy_reader_port`), so k8s pods do not add raw
  connections to Aurora.
- `cdo-external-secrets` holds 50+ keys in one Secret. Anyone with
  `get secrets` in `production` reads all of them. Namespace RBAC in 6.2
  matters for this reason.
- Kubernetes Secrets are envelope-encrypted with the EKS module's KMS key by
  default in v21 (**verify** the key exists and `encryption_config` is set).

### 4.4 Namespace guardrails (P1)

Add to the Namespace rendered in `_envtype.tpl` (or a sibling template):

- **Pod Security Admission labels.** Start with
  `pod-security.kubernetes.io/enforce: baseline`, `warn: restricted`,
  `audit: restricted`. Move `enforce` to `restricted` after 3.5 lands.
- **ResourceQuota** for `production`: cap `requests.cpu`, `requests.memory`,
  `pods`, and `count/deployments.apps` at a multiple of the expected footprint
  so a bad values change cannot consume the node pool.
- **LimitRange** with default requests/limits so any future container in the
  namespace gets sane defaults.
- **PriorityClass** `code-org-production` (a high value,
  `preemptionPolicy: PreemptLowerPriority`) applied to production pods, and a
  lower class for staging/test/adhoc. Today they share the same `frontend`
  pool; under pressure the scheduler should evict non-production first.
- **NetworkPolicy** (default-deny ingress and egress, then explicit allows).
  The worker needs no ingress at all. Egress: DNS to `kube-dns`, MySQL 3306 to
  the DB/proxy CIDR, Redis 6379 and memcached 11211 to ElastiCache CIDRs, and
  443 to the internet for OpenAI, aiproxy, Honeybadger, Sentry, MailJet,
  Mapbox, and AWS APIs. Deny everything toward other cluster namespaces and
  the VPC's internal ranges except the DB and cache subnets. EKS Auto Mode
  enforces NetworkPolicy through the built-in VPC CNI agent; **verify** with a
  test policy in staging first, and consider `spec.networkPolicy: DefaultDeny`
  on the NodeClass once every namespace has policies.
- Label the namespace `code.org/environment-type: production` for
  consistency with the adhoc selector (`ClusterExternalSecret` matches on
  that label).

### 4.5 Argo CD project and RBAC for production (P1)

- Every Application, including `codeai-production`, is in `project: default`.
  `default` allows any source repo, any destination, and cluster-scoped
  resources. Argo RBAC maps `engineers@code.org` to `role:admin`
  (`apps/infra/argocd/chart/values.yaml`), so any engineer can sync, delete,
  or hard-refresh production from the UI.
- Create an `AppProject` `codeai-production` with `sourceRepos` limited to the
  two GitHub repos, `destinations` limited to namespace `production`, an empty
  `clusterResourceWhitelist`, and optionally `syncWindows`. Set it through the
  `codeai` ApplicationSet template (a `project` field in `deployment.yaml`
  fed to the template) so only the production deployment moves.
- Add RBAC lines so `engineers@code.org` is read-only on
  `codeai-production/*` and `infrastructure@code.org` (or a smaller group) can
  sync. Kargo's `api.oidc.admins` also includes `engineers@code.org`; decide
  whether every engineer should be able to promote to production or only a
  release group.

### 4.6 A dedicated NodePool and NodeClass for production (P1)

- Staging, test, and production all schedule onto the shared `frontend`
  NodePool. Its NodeClass attaches the cluster primary SG **and** the legacy
  `frontend` SG `sg-663a031e` to every pod on those nodes
  (`frontend-nodeclass.yaml`). That is how pods reach the database, and it
  also means a staging pod is one leaked credential away from production data.
- The NodePool has no `kubernetes.io/arch` requirement. Auto Mode may choose
  Graviton capacity. **Verify** `cdo-rails` is multi-arch; if it is amd64
  only, add `kubernetes.io/arch: In [amd64]` before this becomes a
  CrashLoopBackOff on the wrong node type.
- No `limits`, no `disruption` block, no `expireAfter`, no
  `terminationGracePeriod`; see 5.3.

Recommendation: add `production` NodePool and NodeClass templates next to
`frontend`, taint `code.org/environment-type=production:NoSchedule`, attach
only the SGs the production DB and caches require, require `amd64`, and give
non-production its own NodeClass with non-production SGs. The tofu networking
file already notes that production "should be segmented into its own private
subnets" (`eks-cluster-networking.tf:5-7`); the NodeClass can select those
subnets when they exist.

---

## 5. Scaling

### 5.1 What exists

- Chart HPA: CPU and memory utilization at 50 percent, targeting
  `cdo-dashboard` only, no `behavior` block
  (`templates/dashboard/autoscaler.yaml`). Nothing scales the worker.
- HPA on CPU/memory needs metrics-server. It is not in the EKS addons in tofu
  (Auto Mode does not bundle it) and there is no `apps/*` app for it.
  **Verify** whether the staging and test HPAs actually get metrics.
- Node scaling is EKS Auto Mode (Karpenter) through the built-in
  `system` and `general-purpose` pools plus the custom `frontend` pool.

### 5.2 Pod scaling for a delayed_job worker

- CPU utilization is a poor signal: an idle worker polls MySQL every 5 s at
  near-zero CPU, a busy one spends most of its time waiting on OpenAI. Memory
  is flat. An HPA would rarely move and never for the right reason.
- The right signal is queue depth and age for priority >= 10, which lives in
  the `delayed_jobs` table (or in CloudWatch as `WaitingToStartJobCount` and
  `OldestWaitingToStartJobAge` per `JobName`).

Recommendation:

- **Phase 1 (launch):** fixed `replicas: 2`. Non-urgent work does not need
  elasticity on day one, and a fixed count keeps the failure modes simple.
- **Phase 2 (P2):** install KEDA (`apps/infra/keda`, chart `kedacore/keda`) and
  add a `ScaledObject` for the worker with a MySQL trigger such as
  `SELECT COUNT(*) FROM delayed_jobs WHERE priority >= 10 AND failed_at IS NULL
AND locked_at IS NULL AND run_at <= NOW()`, using the reader URL from
  `cdo-external-secrets` through a `TriggerAuthentication`. Set
  `minReplicaCount: 1`, a modest `maxReplicaCount`, `pollingInterval: 60`, and
  a long `cooldownPeriod` (30 minutes or more) so scale-in does not race
  in-flight jobs. KEDA's `aws-cloudwatch` scaler on the existing
  `code-dot-org/ActiveJob` metrics is the alternative if you prefer not to
  hand KEDA a DB credential.
- Scale-in kills pods, so the grace period from 3.1 is a prerequisite.
- Per-pod concurrency is one process. If you need more throughput per node,
  raise replicas rather than trying to run multiple delayed_job processes in
  one container; the launcher that does that is the legacy one.

### 5.3 Node scaling and disruption (P1)

Auto Mode consolidates underutilized nodes and recycles nodes at a maximum
age (`expireAfter`, default about two weeks on Auto Mode pools; tunable up to
30 days). Both drain pods. For a fleet of long-running jobs, set on the
production NodePool:

- `disruption.consolidationPolicy: WhenEmptyOrUnderutilized` with
  `consolidateAfter` of at least several minutes, and a `disruption.budgets`
  entry that only allows disruption during a quiet window (the geo backfill
  cron runs 02:00 to 11:00, so the quiet window is the afternoon and evening).
- `template.spec.terminationGracePeriod` at least as long as the pod grace
  period from 3.1, so an expiring node waits for jobs rather than forcing
  them.
- `limits.cpu` and `limits.memory` as a cost ceiling.
- Instance requirements: `amd64`, current-generation `m`/`c`/`r` families, and
  on-demand (already set) for production.
- Consider the pod annotation `karpenter.sh/do-not-disrupt: "true"` on worker
  pods only if you pair it with the NodePool `terminationGracePeriod`;
  otherwise it blocks node recycling forever.

### 5.4 Right-sizing (P2)

Run VPA in recommendation-only mode for the worker for a few weeks, then set
requests from its p95. Revisit the 30Gi ephemeral request (3.4).

---

## 6. Cluster security

### 6.1 Control plane (P0/P1)

- **Audit logging is off (P0).** `enabled_log_types = ["api",
"authenticator"]` with a note to re-enable `audit` after May 2026
  (`bootstrap/codeai-k8s/cluster/eks-cluster.tf:27-43`). Turn on `audit`, and
  preferably `controllerManager` and `scheduler`, and set an explicit
  CloudWatch log-group retention (90 days is a common baseline). GuardDuty EKS
  Protection also needs the audit stream.
- **Public API endpoint with no CIDR allowlist (P1).**
  `endpoint_public_access = true` and no `endpoint_public_access_cidrs`
  (`eks-cluster.tf:23`). Argo, Kargo, Crossplane, and ESO all run in-cluster
  and use the private endpoint. Restrict public access to office and VPN
  ranges, or disable it and use a bastion or SSM.
- **Deletion protection (P1).** The cluster is routinely destroyed and
  recreated, and all tofu state keys say `non-prod`
  (`bootstrap/codeai-k8s/*/backend.tf`). Before production traffic: turn on
  EKS deletion protection if the module version exposes it, move state to a
  key that says what it is, and agree on a change process for the `cluster`
  root (plan review by a second person).

### 6.2 Identity and RBAC (P1)

- EKS access entries: `Engineering_FullAccess` and `GoogleSignInAdmin` get
  `AmazonEKSClusterAdminPolicy` cluster-wide; `Engineering_ReadOnly` gets view
  (`eks-cluster.tf:48-67`). Every engineer with the full-access role can
  `kubectl exec` into production pods and read `cdo-external-secrets`.
  Consider namespace-scoped access policies (edit on `staging`, `test`,
  `adhoc-*`; view on `production`) for the broad role, and cluster admin for
  the infrastructure group only.
- Argo CD RBAC maps `engineers@code.org` to `role:admin` and Kargo lists the
  same group as admins. Tighten per 4.5.
- Dex `hostedDomains: [code.org]` and group claims are fine. The Google
  service account key for Dex is generated in tofu and passes through state;
  rotate it on a schedule.

### 6.3 Network isolation between namespaces and toward legacy (P1)

- The cluster lives in the code.org default VPC `vpc-6e98810a` and pods on the
  `frontend` NodeClass carry the legacy frontend SG. There is no NetworkPolicy
  anywhere. Any pod in any namespace on those nodes has network reach to
  whatever the legacy frontend can reach, and pod-to-pod traffic across
  namespaces (argocd, kargo, crossplane-system, external-secrets, dex,
  monitoring) is unrestricted.
- Fix in layers: default-deny NetworkPolicy in every namespace (4.4),
  ingress policies on the platform namespaces so only their peers can reach
  them, per-environment NodeClasses with per-environment SGs (4.6), and,
  when the tofu comment is acted on, production subnets.
- Auto Mode blocks pod access to IMDS by default (hop limit 1) and the chart
  sets `AWS_EC2_METADATA_DISABLED`. Keep both.

### 6.4 Pod security baseline (P1/P2)

- Pod Security Admission labels per namespace (4.4).
- For rules PSA does not cover, the built-in `ValidatingAdmissionPolicy`
  (no new operator) can enforce: images from `ghcr.io/code-dot-org/*` only,
  digests required in `production`, no `:latest`, resources set, `runAsUser`
  not 0 in `production`. Kyverno is the richer option if you later want
  mutation or image signature checks.

### 6.5 Secrets and IAM hygiene (P1)

- Crossplane's role allows `iam:CreateRole`, `iam:PutRolePolicy`, and
  `iam:AttachRolePolicy` on `codeai-k8s-eso-*` and the other allowlisted names
  (`crossplane-aws.tf:249-301`). Anyone who can merge to `main` can therefore
  write an arbitrary inline policy onto the `production` ESO role. Add an
  `iam:PermissionsBoundary` condition so every role Crossplane creates must
  carry a boundary policy that caps it at Secrets Manager read on
  `<env>/cdo/*` plus the small set of app permissions, and require CODEOWNERS
  review on `apps/infra/**` and `apps/**/templates/aws/**` (8.4).
- The Crossplane role also has Secrets Manager `Get*/List*` on `*` ("intentionally
  absolute for now", `crossplane-aws.tf:408-421`) and RDS modify/delete on
  `codeai-k8s-*` without tag conditions. Tighten both once naming is settled.
- Secrets Manager entries created by `modules/bootstrapped-aws-secret` use the
  default KMS key, have no rotation, and pass through tofu plans and state.
  Acceptable for bootstrap secrets; do not extend the pattern to app secrets.
- The Kargo Git credential is a personal access token for `deploy-code-org`
  with push to `main`, and the same token lets tofu commit the generated
  cluster values. Prefer a GitHub App installation token or a fine-grained PAT
  limited to this repo, and use a ruleset bypass rather than an unprotected
  branch (8.4).

### 6.6 Supply chain and images (P2)

- Images are promoted by digest, which is the important part. The Warehouse
  watches the mutable `latest` tag by digest (`warehouse.yaml`); anything CI
  pushes to `latest` becomes freight, so keep publish rights on
  `ghcr.io/code-dot-org/cdo-rails` narrow.
- Pin the `cgr.dev/chainguard/kubectl:latest-dev` hook images in
  `apps/infra/argocd` and `apps/infra/crossplane` by digest.
- Later: sign `cdo-rails` in CI (cosign) and verify signatures at admission
  for `production`; enable GHCR vulnerability scanning and make it visible.

### 6.7 Runtime detection (P2)

Enable GuardDuty EKS Protection (audit-log based) once 6.1 is done, and
evaluate GuardDuty Runtime Monitoring for Auto Mode nodes.

### 6.8 Argo CD and Kargo hardening notes

- `server.insecure: true` is fine behind ALB TLS. `admin.enabled: false` with
  a documented break-glass is good.
- The Argo controller resources carry a "randomly set by Codex" note; profile
  and pin them before production depends on sync latency.
- Kargo's `externalWebhooksServer` is internet-facing on
  `kargo.k8s.code.org/webhooks/...` and authenticated by a shared secret; that
  is normal, but rotate the secret and keep it in Secrets Manager only.

---

## 7. Monitoring and alerting

Grafana is Amazon Managed Grafana (`observability-grafana`, version 12.4),
provisioned by `../infrastructure/observability/opentofu/modules/grafana`.
Dashboards and alert rules are TypeScript in
`../infrastructure/observability/dashboards/grafana/src`, built to JSON and
applied by tofu. The AMP workspace `ws-79f7ef41-111a-4830-a15b-2d5250f0362a`
is shared between the EC2 web tier's OTel collector and this cluster's Alloy.

### 7.1 What exists today

- **Cluster metrics:** Alloy (one replica, `Recreate`, 1Gi `emptyDir` WAL)
  scrapes kubelet, cAdvisor, kube-state-metrics, and itself every 60 s, keeps
  about 38 metric names, and remote-writes with `cluster="codeai-k8s"`
  (`apps/monitoring/chart/files/config.alloy`). kube-state-metrics collects
  nodes, pods, deployments, statefulsets, and HPAs only.
- **Dashboards:** `kubernetes-overview` and `kubernetes-workload-drilldown`
  in folder `Managed/Kubernetes` (`modules/grafana/kubernetes.tf`), plus
  `activejob-overview` on the CloudWatch datasource, which is EC2-daemon
  centric (worker count from the `Daemon` instance, no k8s awareness).
- **Alerting:** rule groups exist only for auth, ScriptLevels#show, and GenAI.
  The root notification policy's contact point is literally named `test`, and
  contact points are created by hand in the UI, not in code
  (`modules/grafana/notifications.tf`). Nothing alerts on this cluster, on
  the collector, on ActiveJob queues, or on MySQL.
- **Logs:** no pipeline. No Fluent Bit, no CloudWatch agent, no Loki.
  Container stdout lives in kubelet only; worker job logs are in a file inside
  the container (3.6).
- **Error tracking:** Honeybadger is the worker's error path (Sentry and OTel
  activate for web processes), and the chart currently blanks its key (3.6).
- **openspec:** the monitoring change is implemented locally; rollout tasks
  4.2 to 4.4 (live coverage check, controlled collector restart, cost
  measurement) are still unchecked
  (`openspec/changes/add-amazon-managed-grafana-monitoring/tasks.md`).

### 7.2 Alerting: the largest gap (P0 minimum, P1 full set)

P0, one end-to-end signal:

- **A canary job.** Enqueue a trivial job at priority 10 every 10 to 15 minutes
  (a cron on the daemon, or later a k8s CronJob) that records its completion
  as a CloudWatch metric or a row. Alert when no canary completed in the last
  45 minutes. This is the only alert that proves the production worker is
  actually draining low-priority work, independent of pods being "Running".
- Route it to a real contact point: a Slack channel the infrastructure group
  reads, and PagerDuty for the critical version once someone is on call for it.

P1, the rest, as Grafana rule groups in code alongside the existing ones:

- **Kubernetes** (Prometheus datasource `effqou9gjnlkwa`, add under
  `src/dashboards/kubernetes/`):
  `kube_deployment_status_replicas_available < kube_deployment_spec_replicas`
  for `namespace="production"` for 10 min; `CrashLoopBackOff` waiting reason
  in production; `container_oom_events_total` increase; pods `Pending` more
  than 10 min; node `Ready=false` or pressure conditions; kubelet evictions;
  HPA (later KEDA) pinned at max for 30 min.
- **Collector staleness:** `time() -
prometheus_remote_storage_queue_highest_sent_timestamp_seconds > 300` and
  `absent(up{job="kubernetes/alloy",cluster="codeai-k8s"})`. These two must
  use `noDataState: Alerting`; every existing rule uses `OK`, which is exactly
  wrong for "the collector died".
- **Independent of Grafana-on-AMP:** a CloudWatch alarm on the AMP workspace's
  `IngestionRate` dropping to zero, so a dead collector pages even if the
  Prometheus datasource is the thing that broke.
- **ActiveJob** (CloudWatch datasource): `OldestWaitingToStartJobAge` for the
  low-priority `JobName`s above a threshold that matches the non-urgent SLO
  (for example 4 hours); `FailedJobCount` rising; no `WaitTime` samples for
  low-priority jobs in 24 hours.
- **Contact points and routing in code:** `grafana_contact_point` resources for
  Slack and PagerDuty in `modules/grafana/notifications.tf`, child policies for
  the `Managed/Kubernetes` folder and a new `Managed/Backend/ActiveJob` folder,
  and retire the `test` root contact point. Register the new folder in
  `alerts.tf`'s `feature_folder_uids`.

### 7.3 Metrics identity for k8s workers (P1)

- `ActiveJobMetrics` pushes to CloudWatch namespace `code-dot-org/ActiveJob`
  with `Environment=<rack_env>` and `JobName`
  (`../code-dot-org/dashboard/app/jobs/concerns/active_job_metrics.rb`).
  Production k8s workers will report as `Environment=production`, blended with
  the EC2 fleet.
- `WorkerCount` and `PercentWorkersIdle` are computed from a local `ps`, so
  each pod reports itself as a fleet of one, and the once-a-minute reporter
  cron runs only on the EC2 daemon.
- Metric pushes need CloudWatch credentials in the pod (4.2).

Recommendation: add a `Platform` dimension (`ec2` / `k8s`) or an
`Environment=production-k8s` variant, stop emitting `ps`-derived worker counts
from pods, and add a panel row to `activejob-overview` that reads
`kube_deployment_status_replicas_available{deployment="cdo-active-job-worker"}`
next to the queue metrics. Once the environment variable that selects the
dimension exists, it is one line in the envType values.

### 7.4 Logs (P1)

Two prerequisites are in 3.6 (worker logger to stdout) and 4.2 (IAM). Then
pick one shipper:

- Extend Alloy with `loki.source.kubernetes` (tails via the kubelet API, so it
  works from the existing single Deployment) feeding
  `otelcol.exporter.awscloudwatchlogs`, one log group per namespace, 30 to 90
  day retention. One collector, one IAM role, already in `apps/monitoring`.
- Or `aws-for-fluent-bit` as a DaemonSet in a new `apps/logging` app. More
  moving parts, but the standard EKS path and independent of the metrics
  collector's single replica.

The Grafana CloudWatch datasource already covers Logs Insights on `us-east-1`,
so no new datasource is needed. Keep `dashboard/log` on an `emptyDir` in the
meantime so file logs cannot fill the container's ephemeral storage.

### 7.5 Error tracking (P0)

Covered in 3.6: un-blank the Honeybadger key for production and confirm an
exception from a low-priority job shows up in Honeybadger before launch.

### 7.6 Dashboards (P1)

- Add a production-worker row to `kubernetes-workload-drilldown` or a small
  "ActiveJob on Kubernetes" dashboard: replicas available versus desired,
  restarts, memory versus the 4Gi limit, CPU throttling, and the CloudWatch
  queue metrics for the low-priority job names side by side.
- Add RDS/Aurora panels (connections, CPU, replica lag, deadlocks) from the
  CloudWatch datasource. Each worker pod can open up to 5 ActiveRecord
  connections plus the replica and reporting pools plus two 4-connection
  Sequel pools; new pods are a new connection source against limits sized for
  the legacy fleet.

### 7.7 Collector and housekeeping (P1/P2)

- Extend kube-state-metrics collectors with `poddisruptionbudgets`, `jobs`,
  `cronjobs`, `resourcequotas`, and add `kube_deployment_status_condition`,
  `kube_pod_container_status_terminated_reason` to both the collector
  allowlist in `apps/monitoring/chart/values.yaml` and the Alloy keep list.
  The README documents that contract.
- Scrape Argo CD's metrics endpoints (application controller, server,
  applicationset controller, repo server) and alert when `codeai-production`
  is `OutOfSync` or `Degraded` for more than 15 minutes; add Kargo's metrics
  if useful.
- Alloy is a single replica on an ephemeral WAL by design (openspec decision
  5). Accept it, but only with the staleness alerts above in place.
- The Grafana service-account token lives 30 days and rotates only on `tofu
apply`; the weekly scheduled apply (observability CI phase 4) is not done.
  Finish it or Grafana-as-code stops working silently.
- Close openspec rollout tasks 4.2 to 4.4 and record the measured cost.

---

## 8. Delivery process: Argo CD and Kargo

### 8.1 Promote the chart with the image (P2, design now)

- Freight is an image digest only. The chart comes from whatever
  `targetRevision: '{{branch}}'` points at in `apps/codeai/applicationset.yaml`.
  With `branch: production` the chart follows the `production` branch HEAD,
  which can move independently of the promoted image.
- Options, in increasing rigor: keep branch-tracking and rely on the branch
  discipline in 3.9; add a Git subscription to the Warehouse for
  `code-dot-org` `k8s/helm` and have the production promotion write that
  commit into `deployment.yaml`; or have CI stamp the source revision as an
  OCI annotation on `cdo-rails` and have the promotion set `targetRevision`
  from it, so image and chart are always the same commit.

### 8.2 Verification before production eligibility (P2)

- Kargo Stage `verification` (needs Argo Rollouts' `AnalysisTemplate` CRDs)
  on the `test` stage: wait for the Argo app healthy, run a smoke Job that
  enqueues and completes a priority-10 job, and check the schema-coupling rule
  from 3.9. Only freight that passes becomes eligible for `production`.
- Until then, a written promotion checklist: image digest equals what `test`
  runs, commit is at or behind legacy production, Honeybadger receives a test
  exception, canary alert is green after promotion.

### 8.3 Rollback

Kargo can re-promote any earlier Freight to `production`; that rewrites the
digest in `deployments/production/values.yaml` and syncs. Write the two-command
procedure into a runbook and rehearse it once in `test`. Note the rollout wait
implied by the grace period in 3.1.

### 8.4 Repository controls (P1)

- There is no `.github/` in this repo. Add CI that renders
  `helm template` for every envType with the matching deployment values from
  the `code-dot-org` chart at the pinned branch, runs `kustomize build` on the
  parity overlays, validates with `kubeconform`, and asserts a few
  invariants: production worker env has `RAILS_ENV=production`, production
  `user.uid` is not 0, production image is a digest, `Chart.yaml` version
  bumped when `apps/*/chart` changes (the AGENTS.md rule).
- Branch protection on `main` with required checks, and a ruleset bypass for
  the Kargo and tofu bot identities that push `[skip ci]` commits. Today
  nothing stops a direct push.
- `CODEOWNERS` requiring infrastructure review on
  `apps/codeai/deployments/production/**`, `apps/codeai/envTypes/production*`,
  `apps/infra/**`, `apps/kargo/**`, and `bootstrap/**`.
- Argo CD notifications (bundled in the chart) to Slack on
  `on-sync-failed`, `on-health-degraded` for the production Application.

### 8.5 Sync policy notes

`prune: true` and `selfHeal: true` are right for production drift control.
Add `syncOptions: [PrunePropagationPolicy=foreground]` and a `retry` block for
the production Application so transient webhook or ESO races do not leave a
half-synced state.

---

## 9. Reliability, DR, and coupling to legacy

- **Stateless by design.** The worker keeps nothing that matters on disk. The
  `shared_cache` cursor for the geo backfill lives in memcached when
  `memcached_endpoint` is set and falls back to a per-pod FileStore otherwise;
  **verify** production sets it, or the backfill restarts from zero after a
  pod replacement.
- **Cluster rebuild is the DR plan** and it is exercised often, but the docs
  that describe it are stale (`cluster-infra/deriving-from-addons.md`,
  `cluster-infra-argocd/README.md` reference files that no longer exist) and
  the app-of-apps bootstrap relies on `local-exec` restart workarounds that run
  on every apply. Write down the measured rebuild time and the manual steps
  (DNS delegation, first-apply secrets in tfvars, Dex).
- **Two AZs, one NAT per AZ.** Fine for this workload.
- **Legacy dependencies that stay:** schema migrations, the `perform_job`
  enqueue crons (`only_one` dedup is per host), `report_activejob_metrics`,
  and `archive_failed_jobs` all run on the EC2 daemon. If the daemon is ever
  retired, each needs a k8s CronJob with a different dedup strategy.
- **Tofu state:** bucket `codeai-tofu-state` in `us-west-2` with native
  locking. Confirm versioning and encryption on the bucket and restrict who can
  write the production keys.

---

## 10. Cost and tagging (P2)

- Default provider tags are only `environment-type = k8s`. Add
  cost-allocation tags (`environment`, `owner`, `cost-center`,
  `code.org/workload-class`) to the NodeClass `spec.tags` so Auto Mode
  instances and volumes are attributable, and enable split cost allocation
  data for EKS in Cost Explorer for per-namespace numbers.
- NodePool `limits` on the production and frontend pools bound runaway
  scaling.
- The 30Gi ephemeral-storage request forces large root volumes and few pods
  per node (3.4).
- Audit logging was disabled for cost during churn; for a steady-state
  production cluster it is a small, expected line item.
- On-demand only is right for production workers with long jobs. Staging and
  test could move to spot with a `capacity-type` requirement on a separate
  pool.

---

## 11. Operations

- **Ownership and on-call.** Name the team that receives k8s worker alerts and
  the SLO for low-priority work (for example: 95 percent of priority >= 10
  jobs start within 4 hours). The alert thresholds in 7.2 follow from it.
- **Runbooks** (a `docs/runbooks/` directory here or in `infrastructure`):
  worker not draining, queue backlog, rollback via Kargo, ESO secret sync
  failing, node drain stuck on a long job, Argo break-glass (already in the
  values comments), cluster rebuild.
- **Fix the smoke tests.** Every script in
  `bootstrap/codeai-k8s/cluster-smoke-tests/` changes into
  `$(dirname)/../test`, which does not exist; the manifests are in
  `cluster-infra-argocd/test/`. Add a production-flavored test that confirms
  DB reachability from the `production` namespace with the production
  ServiceAccount.
- **Housekeeping:** remove the `mimic`-era references, refresh the bootstrap
  READMEs, and keep `bootstrap/apptrees/mimic` in step with any
  `apps/app-of-apps` structural change (AGENTS.md rule).

---

## 12. Things to verify with live access before acting

Each of these was inferred from code only.

1. Which `production/cdo/db_*` and `db_endpoint_*` / `db_credential_*` keys
   exist in Secrets Manager, and whether `CfnStack/autoscale-prod/*` holds the
   proxy endpoints (4.3).
2. Whether the staging worker's CloudWatch metric pushes and DCDO reads
   succeed today with no pod credentials (4.2).
3. Whether metrics-server is installed and the staging/test dashboard HPAs
   have metrics (5.1).
4. Whether `cdo-rails` is multi-arch, and which architectures the `frontend`
   NodePool has actually launched (4.6).
5. Whether NetworkPolicy is enforced on Auto Mode nodes in this cluster (4.4).
6. Whether the EKS module created the secrets KMS key and `encryption_config`
   (4.3).
7. Whether the `monitoring` Application is Healthy and AMP is receiving
   `cluster="codeai-k8s"` samples (openspec 4.3).
8. Whether `production` sets `memcached_endpoint` and `redis_url` reachable
   from the cluster's private subnets and security groups (9).
9. What `locals.yml.override_dashboard` and `stack_name` do to a worker that
   generates URLs or resolves StackSecrets (3.6, 3.7).

---

## Appendix: key files by topic

| Topic                       | Files                                                                                                                                                                                                                                                                                                                       |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Production deployment       | `apps/codeai/applicationset.yaml`, `apps/codeai/deployments/production/{deployment.yaml.disabled,values.yaml,deploy/}`, `apps/codeai/envTypes/production.values.yaml`, `apps/codeai/envTypes/production/`                                                                                                                   |
| Namespace, ESO, IAM         | `apps/infra/standard-envtypes/chart/{values.yaml,templates/_envtype.tpl,templates/aws/single-namespace-envtypes-iam.yaml}`, `apps/infra/codeai-cluster-config.values.yaml`                                                                                                                                                  |
| Nodes and ingress           | `apps/infra/networking/chart/templates/{frontend-nodepool.yaml,frontend-nodeclass.yaml,ingress-class*.yaml}`                                                                                                                                                                                                                |
| Argo CD                     | `apps/infra/argocd/chart/values.yaml`, `apps/app-of-apps/app-of-apps.yaml`                                                                                                                                                                                                                                                  |
| Kargo                       | `apps/kargo/values.yaml`, `apps/kargo/projects/codeai/{project-config.yaml,warehouse.yaml,stages/production.yaml}`                                                                                                                                                                                                          |
| Crossplane IAM              | `apps/infra/crossplane/chart/values.yaml`, `bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`                                                                                                                                                                                                          |
| Cluster                     | `bootstrap/codeai-k8s/cluster/{eks-cluster.tf,eks-cluster-networking.tf,terraform.tfvars,backend.tf}`                                                                                                                                                                                                                       |
| Monitoring (this repo)      | `apps/monitoring/{application.yaml,values.yaml,README.md}`, `apps/monitoring/chart/{values.yaml,files/config.alloy,templates/}`, `openspec/changes/add-amazon-managed-grafana-monitoring/`                                                                                                                                  |
| Monitoring (infrastructure) | `../infrastructure/observability/dashboards/grafana/src/dashboards/kubernetes/`, `../infrastructure/observability/opentofu/modules/grafana/{main.tf,kubernetes.tf,dashboards.tf,alerts.tf,notifications.tf}`                                                                                                                |
| Chart                       | `../code-dot-org/k8s/helm/{Chart.yaml,values.yaml}`, `../code-dot-org/k8s/helm/templates/dashboard/{_dashboard.yaml,active-job-worker-deployment.yaml,autoscaler.yaml}`, `../code-dot-org/k8s/helm/templates/cdo-local-secrets.yaml`, `../code-dot-org/k8s/README.md`                                                       |
| Worker runtime              | `../code-dot-org/dashboard/config/initializers/delayed_job_config.rb`, `../code-dot-org/dashboard/app/jobs/concerns/active_job_metrics.rb`, `../code-dot-org/lib/cdo/active_job_backend.rb`, `../code-dot-org/lib/cdo/secrets_config.rb`, `../code-dot-org/dashboard/config/database.yml`, `../code-dot-org/config.yml.erb` |
| Legacy IAM and alarms       | `../code-dot-org/aws/cloudformation/cloud_formation_stack.yml.erb`, `../code-dot-org/aws/cloudformation/components/alarms.yml.erb`                                                                                                                                                                                          |
