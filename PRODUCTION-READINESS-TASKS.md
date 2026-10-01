# Production readiness task list

Companion to [PRODUCTION-READINESS.md](PRODUCTION-READINESS.md). Tasks are
grouped by concern and ordered P0 to P2 within each group. Each task names
where the change lives and what "done" looks like, and points at the overview
section with the reasoning. Section numbers like `3.1` refer to that file.

| Priority | Meaning                                                       |
| -------- | ------------------------------------------------------------- |
| **P0**   | Before the first production job runs.                         |
| **P1**   | In the first few weeks of running.                            |
| **P2**   | Before adding more production workloads, or when time allows. |

| Concern                            | P0  | P1  | P2  |
| ---------------------------------- | --- | --- | --- |
| 0. Live checks                     | 9   | 0   | 0   |
| A. Worker workload                 | 4   | 6   | 1   |
| B. Production namespace            | 2   | 5   | 0   |
| C. Nodes and scaling               | 0   | 3   | 2   |
| D. Cluster security                | 1   | 5   | 7   |
| E. Monitoring and alerting         | 2   | 10  | 1   |
| F. Delivery (Argo CD, Kargo, repo) | 2   | 5   | 2   |
| G. Reliability and DR              | 0   | 4   | 1   |
| H. Cost and tagging                | 0   | 0   | 2   |
| I. Operations                      | 0   | 3   | 1   |

Launch gate: **F2** is the task that enables production. Its preconditions are
listed there; do not rename `deployment.yaml.disabled` before they are met.

---

## 0. Live checks (P0, read-only)

These were inferred from code only. Record the answer next to each item.

- [ ] **V1 (P0)** List which `production/cdo/db_*`, `db_endpoint_*`, and
      `db_credential_*` keys exist in Secrets Manager and whether
      `CfnStack/autoscale-prod/*` holds the RDS Proxy endpoints.
      Unblocks: B2. See 4.3.
- [ ] **V2 (P0)** In staging, check whether worker CloudWatch metric pushes and
      DCDO (DynamoDB) reads succeed with no pod credentials, and what else fails.
      Unblocks: B1. See 4.2.
- [ ] **V3 (P0)** Check whether metrics-server is installed
      (`kubectl get apiservice v1beta1.metrics.k8s.io`) and whether the staging
      and test dashboard HPAs report metrics. Unblocks: C1. See 5.1.
- [ ] **V4 (P0)** Confirm `ghcr.io/code-dot-org/cdo-rails` is multi-arch, and
      list which architectures the `frontend` NodePool has launched. Unblocks:
      C2, C3. See 4.6.
- [ ] **V5 (P0)** Apply a deny-all NetworkPolicy to a throwaway namespace and
      confirm Auto Mode enforces it. Unblocks: B6. See 4.4.
- [ ] **V6 (P0)** Confirm the EKS module created the secrets KMS key and the
      cluster has `encryption_config` set. See 4.3.
- [ ] **V7 (P0)** Confirm the `monitoring` Application is Healthy and AMP has
      recent `up{cluster="codeai-k8s"}` samples. Unblocks: E1, E12. See 7.1.
- [ ] **V8 (P0)** Confirm production config sets `memcached_endpoint` and
      `redis_url`, and that both are reachable from the private subnets with the
      pod security groups. Unblocks: G4. See 9.
- [ ] **V9 (P0)** Determine what `locals.yml.override_dashboard` and
      `stack_name` do for a worker (URL generation, StackSecret resolution).
      Unblocks: A10. See 3.6, 3.7.

---

## A. Worker workload (chart and values)

Chart: `../code-dot-org/k8s/helm`. Values: `apps/codeai/envTypes/production.values.yaml`,
`apps/codeai/deployments/production/values.yaml`.

- [ ] **A1 (P0)** Add `terminationGracePeriodSeconds` to the shared pod
      template, exposed as `activeJobWorker.terminationGracePeriodSeconds`; set
      production to 2100.
      Where: `templates/dashboard/_dashboard.yaml`, production envType values.
      Done when: the rendered production worker carries the value, and a rolling
      restart in staging during a running low-priority job lets it finish. See 3.1.
- [ ] **A2 (P0)** Stop `cdo-local-secrets` from blanking Honeybadger, Sentry,
      PagerDuty, and Slack keys outside local dev. Gate the blanks behind a values
      flag that is off by default and on only in `development.values.yaml`.
      Where: `templates/cdo-local-secrets.yaml`, `development.values.yaml`.
      Done when: a staging worker exception appears in Honeybadger. See 3.6, 7.5.
- [ ] **A3 (P0)** Decide whether legacy workers keep consuming priority >= 10
      during the soft launch. If the answer is "k8s only", add `--max-priority 9`
      support to the legacy launcher and flip it in the launch change window.
      Where: `../code-dot-org/lib/cdo/active_job_backend.rb`.
      Done when: the decision is written here with its date. See 3.8.
- [ ] **A4 (P0)** Confirm production values never set `user.uid: 0` (staging
      and test do). Add the invariant to F3's CI checks.
      Where: `apps/codeai/deployments/production/values.yaml`.
      Done when: CI fails on a uid 0 in production values. See 3.5.
- [ ] **A5 (P1)** Send delayed_job logs to stdout when an env switch is set,
      and set it in the chart.
      Where: `../code-dot-org/dashboard/config/initializers/delayed_job_config.rb`,
      `values.yaml` `activeJobWorker.extraEnv`.
      Done when: `kubectl logs` on a staging worker shows job output. See 3.6.
- [ ] **A6 (P1)** Add a delayed_job heartbeat plugin that touches a file each
      loop and on job start/finish, plus an `exec` liveness probe in the chart
      (threshold longer than the longest single job). Optionally reuse it as a
      `startupProbe`.
      Where: `../code-dot-org/dashboard/config/initializers/`, chart worker template.
      Done when: a worker whose process is frozen gets restarted in staging. See 3.2.
- [ ] **A7 (P1)** Run 2 replicas in production, add a PDB with
      `maxUnavailable: 1`, a zone `topologySpreadConstraints` entry with
      `ScheduleAnyway`, and fix `replicas: 0` rendering as 1.
      Where: chart worker template, production envType values.
      Done when: a node drain in staging never removes both workers at once. See 3.3.
- [ ] **A8 (P1)** Harden the container: `runAsNonRoot: true`,
      `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`,
      `automountServiceAccountToken: false`. Evaluate `readOnlyRootFilesystem`
      with `emptyDir` mounts for `dashboard/tmp`, `dashboard/log`, and the Rails
      file cache.
      Where: `templates/dashboard/_dashboard.yaml`.
      Done when: the production worker passes the `restricted` PSA level in
      `warn` mode (B3). See 3.5.
- [ ] **A9 (P1)** Right-size the worker: measure RSS for the two low-priority
      jobs in staging, set memory from it, cut `ephemeral-storage` to single-digit
      GiB once A5 lands, and remove the inert `CDO_ACTIVE_JOB_BACKEND_*` env vars.
      Where: `values.yaml` `activeJobWorker`, production deployment values.
      Done when: requests match measured p95 with headroom. See 3.4.
- [ ] **A10 (P1)** Clean up production values: comment each intentional
      no-op (`autoscaling`, `healthChecks`, `dnsName`), resolve
      `override_dashboard` per V9, and either sync or clearly mark the
      `deploy/` kustomize parity overlay as non-authoritative.
      Where: `apps/codeai/envTypes/production.values.yaml`,
      `apps/codeai/deployments/production/`.
      Done when: a reader of the values file knows what applies to the worker. See 3.7.
- [ ] **A11 (P2)** Chart hygiene: add `appVersion`, bump `version` with
      functional changes, drop `tty: true` on the worker, and move local-dev
      MySQL, Redis, and MinIO behind a clearly dev-only values file or subchart.
      Where: `Chart.yaml`, `templates/services/`.
      Done when: production renders from a chart with no dev-only templates. See 3.6.

---

## B. Production namespace

Most of these land in `apps/infra/standard-envtypes/chart`, which renders the
`production` Namespace, SecretStore, ServiceAccount, and ExternalSecret.

- [ ] **B1 (P0)** Give the worker an identity: chart `serviceAccount.create`,
      `.name`, `.annotations`, `serviceAccountName` in the pod spec; a Crossplane
      `Role` plus `RolePolicy` per envType named `codeai-k8s-app-<env>` with trust
      on `system:serviceaccount:<env>:cdo-app`; and `codeai-k8s-app-*` added to
      `iam_role_names` in the Crossplane tofu allowlist. Policy scope from the
      legacy `CDOPolicy`: CloudWatch `PutMetricData`, Secrets Manager
      `production/cdo/*`, DCDO and Gatekeeper DynamoDB tables, the production S3
      buckets, `logs:*` on `production-*` groups, and the AI services the jobs use.
      Where: chart, `apps/infra/standard-envtypes/chart/templates/aws/`,
      `bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`.
      Depends on: V2. Done when: a staging pod with the SA pushes a CloudWatch
      metric and reads DCDO. See 4.2.
- [ ] **B2 (P0)** Fix the production DB secrets path: add a per-envType
      `stack_name` override (default `env`, production `autoscale-prod`) used in
      both the IAM resource ARN and the `ExternalSecret` CfnStack find, then add
      `production` to `compose_db_url_environment_types`. Prefer RDS Proxy
      endpoints if V1 shows them.
      Where: `apps/infra/standard-envtypes/chart/values.yaml`,
      `templates/_envtype.tpl`, `templates/aws/single-namespace-envtypes-iam.yaml`.
      Depends on: V1. Done when: `cdo-external-secrets` in `production` contains
      composed `db_writer` and `db_reader` and the ESO sync is Ready. See 4.3.
- [ ] **B3 (P1)** Add Pod Security Admission labels to the Namespace:
      `enforce: baseline`, `warn: restricted`, `audit: restricted`. Move
      `enforce` to `restricted` after A8.
      Where: `templates/_envtype.tpl`.
      Done when: production pods run with `enforce: restricted`. See 4.4.
- [ ] **B4 (P1)** Add a `ResourceQuota` and a `LimitRange` for `production`
      sized at a multiple of the expected worker footprint.
      Where: `apps/infra/standard-envtypes/chart/templates/`.
      Done when: a values typo requesting 100 replicas is rejected. See 4.4.
- [ ] **B5 (P1)** Create `PriorityClass` `code-org-production` and a lower
      class for staging, test, and adhoc; set `priorityClassName` via the chart.
      Where: `apps/infra/standard-envtypes/chart/templates/`, chart pod template.
      Done when: production pods carry the class and non-production pods are
      evicted first under pressure. See 4.4.
- [ ] **B6 (P1)** Default-deny ingress and egress NetworkPolicy in
      `production`, then explicit allows: DNS, MySQL 3306 to the DB or proxy CIDR,
      Redis 6379 and memcached 11211 to ElastiCache CIDRs, 443 to the internet,
      nothing to other cluster namespaces or internal VPC ranges beyond those.
      Roll the same pattern to staging and test, and ingress policies to the
      platform namespaces.
      Where: `apps/infra/standard-envtypes/chart/templates/` (per envType), new
      policies in platform charts.
      Depends on: V5. Done when: a production pod cannot reach the `argocd`
      namespace and can still reach the DB. See 4.4, 6.3.
- [ ] **B7 (P1)** Label the Namespace `code.org/environment-type: production`
      for consistency with the adhoc `ClusterExternalSecret` selector.
      Where: `templates/_envtype.tpl`.
      Done when: label present. See 4.4.

---

## C. Nodes and scaling

- [ ] **C1 (P1)** If V3 shows no metrics-server, install it as an EKS add-on
      (tofu) or an `apps/infra` app, or remove the dashboard HPAs that depend on it.
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster.tf` or `apps/infra/`.
      Done when: `kubectl top pods` works and HPAs show current utilization. See 5.1.
- [ ] **C2 (P1)** Add a dedicated `production` NodePool and NodeClass: taint
      `code.org/environment-type=production:NoSchedule`, only the security groups
      production needs, `kubernetes.io/arch In [amd64]`, current-generation
      `m`/`c`/`r`, on-demand, `limits`, `disruption.budgets` restricted to a quiet
      window (afternoon and evening), `consolidateAfter` of several minutes, and
      `terminationGracePeriod` of at least the pod value from A1. Point production
      values at it.
      Where: `apps/infra/networking/chart/templates/`, production envType
      `scheduling`.
      Depends on: V4. Done when: production workers run only on the new pool and
      a node expiry waits for a running job. See 4.6, 5.3.
- [ ] **C3 (P1)** Harden the existing `frontend` pool for staging and test:
      `amd64` requirement if V4 says so, `limits`, a `disruption` block, and its
      own NodeClass with non-production security groups.
      Where: `apps/infra/networking/chart/templates/frontend-node{pool,class}.yaml`.
      Done when: staging pods no longer carry the production frontend SG. See 4.6.
- [ ] **C4 (P2)** Install KEDA (`apps/infra/keda`) and add a `ScaledObject`
      for the production worker on a MySQL trigger counting unlocked
      priority >= 10 jobs (or the `aws-cloudwatch` scaler on
      `WaitingToStartJobCount`): `minReplicaCount: 1`, modest max,
      `pollingInterval: 60`, `cooldownPeriod` of 30 minutes or more.
      Where: new `apps/infra/keda`, chart `ScaledObject` template.
      Depends on: A1. Done when: replicas follow a backlog in staging and scale-in
      never kills a running job. See 5.2.
- [ ] **C5 (P2)** Run VPA in recommendation mode for the worker and feed the
      result back into A9.
      Where: `apps/infra/` (VPA install), chart `VerticalPodAutoscaler` template.
      Done when: a month of recommendations exists. See 5.4.

---

## D. Cluster security

- [ ] **D1 (P0)** Enable `audit`, `controllerManager`, and `scheduler`
      control-plane logs and set CloudWatch retention (90 days baseline).
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster.tf`.
      Done when: audit events appear in the log group. See 6.1.
- [ ] **D2 (P1)** Restrict the public API endpoint with
      `endpoint_public_access_cidrs` (office and VPN), or disable public access
      and use SSM or a bastion.
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster.tf`.
      Done when: `kubectl` from an unlisted network fails. See 6.1.
- [ ] **D3 (P1)** Narrow EKS access entries: namespace-scoped edit for
      `Engineering_FullAccess` on staging, test, and `adhoc-*`, view on
      `production`; cluster admin only for the infrastructure group.
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster.tf`, `variables.tf`.
      Done when: a non-infra engineer cannot `exec` into a production pod. See 6.2.
- [ ] **D4 (P1)** Create Argo `AppProject` `codeai-production` (two source
      repos, destination `production` only, empty cluster-resource whitelist),
      feed `project` through the `codeai` ApplicationSet from `deployment.yaml`,
      and add RBAC so engineers are read-only on it. Decide whether Kargo
      production promotion stays open to `engineers@code.org`.
      Where: `apps/infra/argocd/chart/values.yaml`, `apps/codeai/applicationset.yaml`,
      `apps/kargo/values.yaml`.
      Done when: `argocd app sync codeai-production` is denied for a non-infra user. See 4.5, 6.2.
- [ ] **D5 (P1)** Require a permissions boundary on every role Crossplane
      creates, and tighten the Secrets Manager `*` and untagged RDS statements in
      the Crossplane role.
      Where: `bootstrap/codeai-k8s/cluster-infra/infra/crossplane/crossplane-aws.tf`,
      Crossplane `Role` templates in `apps/infra/*`.
      Done when: a Crossplane `RolePolicy` granting `s3:*` on `*` is rejected by IAM. See 6.5.
- [ ] **D6 (P1)** Replace the `deploy-code-org` personal access token used by
      Kargo and the tofu values publisher with a GitHub App installation token or
      a fine-grained PAT scoped to this repo.
      Where: `bootstrap/codeai-k8s/cluster-infra/infra/kargo-secrets/`,
      `codeai-cluster-config.tf`.
      Done when: the old PAT is revoked and promotions still push. See 6.5.
- [ ] **D7 (P2)** Pin `cgr.dev/chainguard/kubectl:latest-dev` hook images by
      digest.
      Where: `apps/infra/argocd/chart/templates/`, `apps/infra/crossplane/chart/templates/`.
      Done when: no `:latest*` tags remain in `apps/`. See 6.6.
- [ ] **D8 (P2)** Add built-in `ValidatingAdmissionPolicy` rules: images only
      from `ghcr.io/code-dot-org/*`, digests required in `production`, no
      `:latest`, resources set, `runAsUser` not 0 in `production`.
      Where: new `apps/infra/policies` chart.
      Done when: a test pod violating each rule is rejected. See 6.4.
- [ ] **D9 (P2)** Sign `cdo-rails` in CI with cosign, verify at admission for
      `production`, and surface GHCR vulnerability scanning.
      Where: `../code-dot-org/.github/workflows/`, admission policy.
      Done when: an unsigned image cannot start in `production`. See 6.6.
- [ ] **D10 (P2)** Enable GuardDuty EKS Protection and evaluate Runtime
      Monitoring on Auto Mode nodes.
      Where: AWS account settings or tofu.
      Depends on: D1. Done when: findings flow to the existing security channel. See 6.7.
- [ ] **D11 (P2)** Put the Dex Google service-account key and the Kargo
      webhook secret on a rotation schedule.
      Where: `bootstrap/codeai-k8s-dex/`, `bootstrap/codeai-k8s/cluster-infra/infra/kargo-secrets/`.
      Done when: a dated rotation entry exists. See 6.2, 6.8.
- [ ] **D12 (P2)** Profile and pin Argo CD controller and repo-server
      resources instead of the current guessed values.
      Where: `apps/infra/argocd/chart/values.yaml`.
      Done when: requests reflect a week of measured usage. See 6.8.
- [ ] **D13 (P2)** Create production private subnets per the comment in the
      networking tofu and select them from the production NodeClass.
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster-networking.tf`,
      `apps/infra/networking`.
      Done when: production nodes land only in those subnets. See 6.3.

---

## E. Monitoring and alerting

Grafana code lives in `../infrastructure/observability` (dashboards and rules
under `dashboards/grafana/src`, provisioning under `opentofu/modules/grafana`).
Collection lives in `apps/monitoring`.

- [ ] **E1 (P0)** Canary: enqueue a trivial priority-10 job every 10 to 15
      minutes that records completion as a CloudWatch metric; alert when none
      completed in 45 minutes; route to a Slack channel the infrastructure group
      reads (PagerDuty once someone is on call for it).
      Where: `../code-dot-org` (job and cron), Grafana rule and contact point.
      Depends on: B1, V7. Done when: stopping the staging worker fires the alert. See 7.2.
- [ ] **E2 (P0)** Confirm a forced exception from a production worker reaches
      Honeybadger after A2 ships.
      Where: Honeybadger project for dashboard.
      Depends on: A2. Done when: the test exception is visible. See 7.5.
- [ ] **E3 (P1)** Put contact points and routing in code:
      `grafana_contact_point` for Slack and PagerDuty, child policies for
      `Managed/Kubernetes` and a new `Managed/Backend/ActiveJob` folder, retire
      the `test` root contact point, register the folder in `alerts.tf`.
      Where: `opentofu/modules/grafana/{notifications.tf,alerts.tf,dashboards.tf}`.
      Done when: no hand-made contact point remains in use. See 7.2.
- [ ] **E4 (P1)** Kubernetes rule group: production deployment available <
      spec for 10 minutes, CrashLoopBackOff, OOM events, Pending > 10 minutes,
      node NotReady or pressure, evictions, autoscaler at max 30 minutes.
      Where: `dashboards/grafana/src/dashboards/kubernetes/alerts/`.
      Done when: scaling the staging worker to a bad image fires the alert. See 7.2.
- [ ] **E5 (P1)** Collector staleness: Alloy remote-write age > 300 s and
      `absent(up{job="kubernetes/alloy"})` with `noDataState: Alerting`, plus a
      CloudWatch alarm on the AMP workspace `IngestionRate` dropping to zero.
      Where: Kubernetes alert group, CloudWatch alarm in `infrastructure`.
      Done when: scaling Alloy to zero fires both. See 7.2.
- [ ] **E6 (P1)** ActiveJob rules on the CloudWatch datasource:
      `OldestWaitingToStartJobAge` for the low-priority job names above the SLO
      threshold, `FailedJobCount` rising, no low-priority `WaitTime` samples in
      24 hours.
      Where: `dashboards/grafana/src/dashboards/backend/`.
      Depends on: I1 (threshold). Done when: rules exist and route to the
      ActiveJob folder. See 7.2.
- [ ] **E7 (P1)** Metrics identity: add a `Platform` dimension (or
      `Environment=production-k8s`) to `ActiveJobMetrics`, stop emitting
      `ps`-derived `WorkerCount` and `PercentWorkersIdle` from pods, set the
      selector in envType values.
      Where: `../code-dot-org/dashboard/app/jobs/concerns/active_job_metrics.rb`,
      envType values.
      Depends on: B1. Done when: k8s series are separable in `activejob-overview`. See 7.3.
- [ ] **E8 (P1)** Ship container logs to CloudWatch Logs: extend Alloy with
      `loki.source.kubernetes` plus `otelcol.exporter.awscloudwatchlogs` (or
      deploy `aws-for-fluent-bit`), one group per namespace, 30 to 90 day
      retention, `logs:*` added to the collector role.
      Where: `apps/monitoring/chart/files/config.alloy`, `templates/iam.yaml`.
      Depends on: A5. Done when: a production job log line is queryable in Logs
      Insights from Grafana. See 7.4.
- [ ] **E9 (P1)** Dashboards: a production-worker row (replicas, restarts,
      memory vs limit, throttling, low-priority queue metrics side by side) and an
      RDS/Aurora row (connections, CPU, replica lag, deadlocks).
      Where: `dashboards/grafana/src/dashboards/kubernetes/`, `backend/`.
      Done when: both rows render with live data. See 7.6.
- [ ] **E10 (P1)** kube-state-metrics: add `poddisruptionbudgets`, `jobs`,
      `cronjobs`, `resourcequotas` collectors and
      `kube_deployment_status_condition`,
      `kube_pod_container_status_terminated_reason` to both allowlists.
      Where: `apps/monitoring/chart/values.yaml`, `files/config.alloy`.
      Done when: the new series appear in AMP. See 7.7.
- [ ] **E11 (P1)** Finish the weekly scheduled `tofu apply` for observability
      so the 30-day Grafana service-account token keeps rotating.
      Where: `../infrastructure/.github/workflows/`.
      Done when: a scheduled run has rotated the token once. See 7.7.
- [ ] **E12 (P1)** Close openspec rollout tasks 4.2 to 4.4: live coverage
      check, controlled collector restart, measured cost.
      Where: `openspec/changes/add-amazon-managed-grafana-monitoring/tasks.md`.
      Depends on: V7. Done when: the tasks are checked with evidence. See 7.7.
- [ ] **E13 (P2)** Scrape Argo CD (and Kargo) metrics endpoints and alert when
      `codeai-production` is OutOfSync or Degraded for 15 minutes.
      Where: `apps/monitoring/chart/files/config.alloy`, Kubernetes alert group.
      Done when: a deliberately broken production values commit fires it. See 7.7.

---

## F. Delivery (Argo CD, Kargo, repository controls)

- [ ] **F1 (P0)** Write the promotion checklist: image digest equals what
      `test` runs, source commit is at or behind legacy production (schema
      coupling), Honeybadger test exception visible, canary alert green after
      promotion.
      Where: a `docs/` page in this repo linked from the Kargo project.
      Done when: the checklist is linked and used for the first promotion. See 3.9, 8.2.
- [ ] **F2 (P0) Launch gate** Enable production: rename
      `deployment.yaml.disabled` to `deployment.yaml`, set `branch: production`,
      pin `image` to the digest `test` is running (or let the first Kargo
      promotion do it before Argo syncs), add a `production` entry to
      `check-phase-deployment-status`.
      Where: `apps/codeai/deployments/production/`,
      `bootstrap/codeai-k8s/cluster-infra-argocd/bin/check-phase-deployment-status`.
      Preconditions: A1, A2, A3, A4, B1, B2, D1, E1, E2, F1, F6 done.
      Done when: `codeai-production` is Healthy and the canary completes on k8s. See 4.1.
- [ ] **F3 (P1)** Add CI to this repo: render `helm template` per envType with
      its deployment values from the pinned `code-dot-org` branch, `kustomize
build` the parity overlays, `kubeconform`, and invariants (production worker
      `RAILS_ENV=production`, production `user.uid` not 0, production image is a
      digest, `apps/*/chart` version bumped on change, `bootstrap/apptrees/mimic`
      in step with `apps/app-of-apps`).
      Where: new `.github/workflows/`.
      Done when: each invariant has a failing test case. See 8.4.
- [ ] **F4 (P1)** Branch protection on `main` with required checks and a
      ruleset bypass for the Kargo and tofu bot identities; `CODEOWNERS` requiring
      infrastructure review on `apps/codeai/deployments/production/**`,
      `apps/codeai/envTypes/production*`, `apps/infra/**`, `apps/kargo/**`,
      `bootstrap/**`.
      Where: GitHub repo settings, `.github/CODEOWNERS`.
      Depends on: D6. Done when: a direct push to `main` by a human is rejected
      and a Kargo promotion still lands. See 8.4.
- [ ] **F5 (P1)** Argo CD notifications to Slack for `on-sync-failed` and
      `on-health-degraded` on `codeai-production`, token via ESO.
      Where: `apps/infra/argocd/chart/values.yaml`.
      Done when: a forced sync failure posts to Slack. See 8.4.
- [ ] **F6 (P1)** Production Application safety: `preserveResourcesOnDeletion:
true`, `PrunePropagationPolicy=foreground`, and a `retry` block for the
      production entry in the `codeai` ApplicationSet.
      Where: `apps/codeai/applicationset.yaml`.
      Done when: renaming `deployment.yaml` in a test tree leaves the workload. See 4.1, 8.5.
- [ ] **F7 (P1)** Write and rehearse the rollback runbook (re-promote earlier
      Freight) in `test`, noting the drain wait from A1.
      Where: `docs/runbooks/`.
      Done when: a rollback has been executed end to end in `test`. See 8.3.
- [ ] **F8 (P2)** Promote chart revision with image: stamp the source revision
      on `cdo-rails` as an OCI annotation (or add a Git subscription to the
      Warehouse) and have production promotion set the chart `targetRevision`
      from the freight.
      Where: `apps/kargo/projects/codeai/{warehouse.yaml,stages/production.yaml}`,
      `apps/codeai/applicationset.yaml`, `../code-dot-org` CI.
      Done when: production chart and image always come from one commit. See 8.1.
- [ ] **F9 (P2)** Kargo `verification` on the `test` stage (Argo Rollouts
      `AnalysisTemplate` CRDs): app healthy, smoke Job that completes a
      priority-10 job, schema-coupling check. Only passing freight becomes
      eligible for `production`.
      Where: `apps/kargo/projects/codeai/stages/test.yaml`, new `apps/infra/argo-rollouts`.
      Done when: failing verification blocks promotion. See 8.2.

---

## G. Reliability and DR

- [ ] **G1 (P1)** Move tofu state off the `non-prod` keys, confirm bucket
      versioning and encryption on `codeai-tofu-state`, and restrict who can write
      the production keys.
      Where: `bootstrap/codeai-k8s/*/backend.tf`, bucket policy.
      Done when: state keys name the environment and a state migration has run. See 6.1, 9.
- [ ] **G2 (P1)** Turn on EKS deletion protection if the module exposes it, and
      adopt a two-person plan review for the `cluster` root.
      Where: `bootstrap/codeai-k8s/cluster/eks-cluster.tf`, team process.
      Done when: `tofu destroy` of the cluster root is refused by AWS. See 6.1.
- [ ] **G3 (P1)** Write the rebuild runbook with measured time and the manual
      steps (DNS delegation, first-apply secrets in tfvars, Dex, local-exec
      restart workarounds).
      Where: `docs/runbooks/`.
      Done when: someone other than the author can follow it. See 9.
- [ ] **G4 (P1)** If V8 fails, configure `memcached_endpoint` and `redis_url`
      for production and open the security-group paths; otherwise record that the
      geo backfill cursor is durable.
      Where: `production/cdo/*` secrets, NodeClass security groups.
      Done when: the backfill cursor survives a pod replacement. See 9.
- [ ] **G5 (P2)** Plan k8s `CronJob` equivalents and a non-host dedup
      strategy for `perform_job` enqueue crons, `report_activejob_metrics`, and
      `archive_failed_jobs`, for the day the EC2 daemon is retired.
      Where: design note in `docs/`.
      Done when: the note exists with owners. See 9.

---

## H. Cost and tagging

- [ ] **H1 (P2)** Add cost-allocation tags (`environment`, `owner`,
      `cost-center`, `code.org/workload-class`) to NodeClass `spec.tags` and
      default provider tags; enable split cost allocation data for EKS.
      Where: `apps/infra/networking/chart/templates/*-nodeclass.yaml`,
      `bootstrap/codeai-k8s/*/providers.tf`.
      Done when: Cost Explorer shows per-namespace spend. See 10.
- [ ] **H2 (P2)** Move staging and test to a spot-capable pool with a
      `capacity-type` requirement, keeping production on-demand.
      Where: `apps/infra/networking`.
      Done when: non-production nodes are spot. See 10.

---

## I. Operations

- [ ] **I1 (P1)** Name the owning team and on-call rotation for k8s worker
      alerts, and set the low-priority SLO (for example: 95 percent of
      priority >= 10 jobs start within 4 hours). E6 thresholds follow from it.
      Where: this file and the on-call tool.
      Done when: the owner and SLO are written here. See 11.
- [ ] **I2 (P1)** Runbooks: worker not draining, queue backlog, ESO sync
      failing, node drain stuck on a long job, Argo break-glass, rollback (F7),
      rebuild (G3).
      Where: `docs/runbooks/`.
      Done when: each alert in E links to a runbook. See 11.
- [ ] **I3 (P1)** Fix the smoke-test scripts (they `cd` to a `../test`
      directory that does not exist) and add a production test that confirms DB
      reachability from the `production` namespace with the worker ServiceAccount.
      Where: `bootstrap/codeai-k8s/cluster-smoke-tests/*.sh`.
      Depends on: B1. Done when: all scripts run from a clean checkout. See 11.
- [ ] **I4 (P2)** Refresh stale bootstrap docs (`deriving-from-addons.md`,
      `cluster-infra-argocd/README.md`) and remove `mimic`-era references.
      Where: `bootstrap/codeai-k8s/`.
      Done when: every file the docs name exists. See 11.
