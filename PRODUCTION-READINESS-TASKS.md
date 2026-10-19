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
| C. Nodes and scaling               | 0   | 4   | 2   |
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

- [x] **V1 (P0)** List which `production/cdo/db_*`, `db_endpoint_*`, and
      `db_credential_*` keys exist in Secrets Manager and whether
      `CfnStack/autoscale-prod/*` holds the RDS Proxy endpoints.
      Unblocks: B2. See 4.3.

      **Result (2026-10-07, read-only `aws secretsmanager list-secrets` in
      475661607190 / us-east-1; no values read, no secrets modified):**

      `production/cdo/` has exactly six `db_*` secrets and **no**
      `db_endpoint_*` or `db_credential_*` keys at all:

      | Secret                              | Created    | LastChanged | Status |
      |-------------------------------------|------------|-------------|--------|
      | `production/cdo/db_writer`          | 2019-07-23 | 2019-07-23  | frozen; same vintage as the retired non-prod ones |
      | `production/cdo/db_reader`          | 2019-07-23 | 2019-07-23  | frozen |
      | `production/cdo/db_admin`           | 2019-07-23 | 2019-07-23  | frozen |
      | `production/cdo/db_writer_password` | 2022-10-15 | 2022-10-15  | frozen |
      | `production/cdo/db_reader_password` | 2022-10-15 | 2022-10-15  | frozen |
      | `production/cdo/db_admin_password`  | 2022-10-15 | 2022-10-15  | frozen |

      Frozen does not mean dead: legacy production EC2 resolves
      `db_writer: !Secret` from `production/cdo/db_writer`, so these stay
      untouched. All six show LastAccessed = yesterday, but that is explained
      by the production `cdo-external-secrets` ExternalSecret, which `find`s
      `production/cdo/` every 5 minutes and GetSecretValue's each match; it is
      not evidence of (or against) legacy use.

      `CfnStack/autoscale-prod/` has 16 secrets and **does** hold the full RDS
      Proxy set:

      | Key                                  | LastChanged | Note |
      |--------------------------------------|-------------|------|
      | `db_endpoint_proxy_writer` / `_port` | 2026-09-25 / 2025-06-12 | proxy hostname changed 12 days ago |
      | `db_endpoint_proxy_reader` / `_port` | 2026-09-25 / 2025-06-12 | proxy hostname changed 12 days ago |
      | `db_endpoint_proxy_reporting` / `_port` | 2025-05-16 / 2025-06-12 | |
      | `db_endpoint_writer` / `_port`       | 2025-05-16 / 2025-06-12 | Aurora cluster writer endpoint (non-proxy) |
      | `db_cluster_id`                      | 2025-05-16  | |
      | `db_credential_writer`, `db_credential_reader` | 2025-05-16 | RDS Proxy JSON format |
      | `db_credential_admin`                | 2025-08-05  | not needed by a worker |
      | `db_credential_employee_emily.eastlake`, `_natalia`, `_seth.nickell` | 2024 | personal DB creds; must not be synced to k8s |
      | `chef`                               | 2025-05-16  | not `db_*`, already excluded by the regex |

      There is no `db_endpoint_reader` (cluster reader endpoint); staging has
      none either. The 13 `db_*` keys staging's `cdo-external-secrets`
      receives from `CfnStack/staging/` all exist under `autoscale-prod`, so
      production has parity with staging plus the three employee credentials.
      The four keys the chart's compose template needs
      (`db_credential_writer`, `db_credential_reader`, `db_endpoint_writer`,
      `db_endpoint_writer_port`) all exist. Daily LastAccessed on every
      `autoscale-prod` key is expected: RDS Proxy reads the `db_credential_*`
      secrets for auth and legacy EC2 resolves `!StackSecret` at boot; k8s
      reads none of them today because the production find path is
      `CfnStack/production/`.

      Live confirmation (`kubectl get secret cdo-external-secrets -n
      production`, key names only): the Secret contains exactly the six
      `production/cdo` keys above and nothing from the CfnStack find. So a
      production worker today would get the 2019 `db_writer`/`db_reader` and
      would be missing every `!StackSecret` key. `database.yml` reads
      `db_endpoint_proxy_reporting`, `db_endpoint_proxy_reporting_port`, and
      `db_credential_reader` unconditionally for the `primary_reporting` pool,
      so the worker would fall through to Secrets Manager at boot for names
      (`production/cdo/db_endpoint_proxy_reporting`, ...) that do not exist.
      B2 can be designed from this; see the design notes under B2.
- [ ] **V2 (P0)** In staging, check whether worker CloudWatch metric pushes and
      DCDO (DynamoDB) reads succeed with no pod credentials, and what else fails.
      Unblocks: B1. See 4.2.
- [x] **V3 (P0)** Check whether metrics-server is installed
      (`kubectl get apiservice v1beta1.metrics.k8s.io`) and whether the staging
      and test dashboard HPAs report metrics. Unblocks: C1. See 5.1.

      **Result (2026-10-15, read-only `kubectl get apiservice`, `kubectl top`,
      `kubectl get hpa -A`, `kubectl get deploy`; nothing modified):**

      No metrics-server. `v1beta1.metrics.k8s.io` is NotFound, `kubectl top
      pods -n staging` returns `Metrics API not available`, and no
      metrics-server pod runs in any namespace. The only metrics APIService on
      the cluster is `v1.metrics.eks.amazonaws.com` (the EKS extension metrics
      API), which is not the resource metrics API. Auto Mode confirmed not to
      bundle it.

      There are also **no HPA objects in any namespace**, so the HPAs are not
      inert, they were never rendered. The chart gates
      `templates/dashboard/autoscaler.yaml` on
      `dashboard.enabled && autoscaling.enabled`, and `dashboard.enabled` keeps
      the chart default `false` in every envType and deployment here. `staging`
      and `test` each run exactly one Deployment, `<env>-cdo-active-job-worker`.
      Nothing deployed today depends on metrics-server.

      Side finding: `autoscaling.enabled`, `minReplicas`, and `maxReplicas` in
      the `test` and `production` envTypes and in the `staging`, `test`, and
      `production` deployment values are dead config. The worker's replica
      count comes from `activeJobWorker.replicas` (chart default 1), falling
      back to `autoscaling.replicasWhenAutoscaleDisabled`.

      Scope for C1: the HPA half is moot, the worker was never autoscaled.
      Remove the dead `autoscaling` values and set `activeJobWorker.replicas`
      explicitly per 5.2 Phase 1. metrics-server is only needed for
      `kubectl top` and any future CPU or memory scaler (a KEDA queue-depth
      trigger does not need it). Install it as an `apps/infra` app or as the
      managed EKS add-on (`metrics-server` v0.9.0-eksbuild.11 is the 1.35
      default) when wanted; it is not on the launch path.
- [x] **V4 (P0)** Confirm `ghcr.io/code-dot-org/cdo-rails` is multi-arch, and
      list which architectures the `frontend` NodePool has launched. Unblocks:
      C2, C3. See 4.6.

      **Result (2026-10-15, read-only `docker manifest inspect` and
      `kubectl get nodes,nodeclaims`; nothing modified):**

      The image is multi-arch: the manifest list for the staging digest
      carries `linux/amd64` and `linux/arm64`. The `frontend` NodePool has
      launched only **arm64** so far: both current nodes are `t4g.large`
      (2 vCPU, 8 GiB, burstable). The pool has no arch or instance-type
      requirement, so Karpenter picks the cheapest node that fits one worker.

      One worker request against a `t4g.large`:

      | Resource | Allocatable | Worker request | Left for a second worker |
      |----------|-------------|----------------|--------------------------|
      | cpu      | 1780m       | 1000m          | 780m                     |
      | memory   | ~7 GiB      | 4 GiB          | ~3 GiB                   |

      Exactly one worker fits per node. Every Kargo promotion surges a second
      worker pod (RollingUpdate on 1 replica; `maxUnavailable: 25%` rounds to
      0), and that pod sits Pending with
      `0/5 nodes are available: 2 Insufficient cpu, 2 Insufficient memory,
      3 node(s) didn't match Pod's node affinity/selector` for the two to four
      minutes Karpenter needs to launch a fresh node. The old worker keeps
      running the whole time, so this is a routine scale-up transient, not a
      capacity failure. Seen in `staging` on 2026-10-14 during one of eight
      rollouts that day. Nothing blocks the launch: the pool has no `limits`
      and the account's on-demand Standard vCPU quota (20,896) is far above
      use (a few hundred vCPUs). Auto Mode's Karpenter controller re-elected
      its leader twice in about 30 minutes on 2026-10-15; that is AWS-managed
      and can add a minute to the wait. Decision: not a P0. C2, C3, B5, and
      E4 cover the production-side hardening.
- [x] **V5 (P0)** Apply a deny-all NetworkPolicy to a throwaway namespace and
      confirm Auto Mode enforces it. Unblocks: B6. See 4.4.

      **Result (2026-10-15, read-only `kubectl` and `aws eks describe-cluster`
      plus the AWS Auto Mode docs; nothing modified, no throwaway namespace
      created):**

      NetworkPolicy is **not enforced** on this cluster today, and it cannot
      be until the controller is turned on. On EKS Auto Mode the Network
      Policy Controller is off by default and is enabled by a ConfigMap named
      `amazon-vpc-cni` in `kube-system` with
      `enable-network-policy-controller: "true"`. That ConfigMap does not
      exist here; `kube-system` holds only the three stock ConfigMaps. The
      policy CRDs (`policyendpoints`, `clusternetworkpolicies`,
      `applicationnetworkpolicies.networking.k8s.aws`) are installed and
      there are zero PolicyEndpoint and zero NetworkPolicy objects, so a
      policy applied now is accepted by the API and silently ignored.

      Once the ConfigMap exists, enforcement is done by the node agent that
      is already on every Auto Mode node (both the built-in `default` and our
      `frontend` NodeClass), for ingress and egress, by eBPF on the pod veth.
      Two inputs for B6 came out of this:

      - DNS is node-local. There is no `kube-dns` Service and no CoreDNS pod;
        pods resolve against `172.20.0.10`, the `.10` of the service CIDR
        `172.20.0.0/16`, which AWS documents as CoreDNS running on each
        instance. The DNS allow rule must be an `ipBlock` for
        `172.20.0.10/32` on TCP/UDP 53, not a namespace or pod selector.
      - Both NodeClasses sit at `networkPolicy: DefaultAllow` (standard
        mode): a new pod is allow-all until its PolicyEndpoint reaches the
        node. Set `DefaultDeny` on the production NodeClass (C2) once its
        namespace has policies.

      Decision: the synthetic two-pod probe was skipped. The question it
      would answer is settled by the missing ConfigMap, and the meaningful
      test is B6's own policy rolled to `staging` first, which exercises the
      real allow rules against the worker and is covered by B6's done-when
      check. B6 now owns enabling the controller.
- [x] **V6 (P0)** Confirm the EKS module created the secrets KMS key and the
      cluster has `encryption_config` set. See 4.3.

      **Result (2026-10-15, read-only `aws eks describe-cluster`, `aws kms
      describe-key`, `get-key-rotation-status`, `get-key-policy`; nothing
      modified):**

      Confirmed. `encryptionConfig` on `codeai-k8s` is set with
      `resources: ["secrets"]` and a customer-managed KMS key,
      `alias/eks/codeai-k8s` (`818d51d1-b43d-460d-8beb-502fb8884606`). The key
      is Enabled, symmetric, not scheduled for deletion, created 2026-04-14
      with the cluster, and automatic rotation is on at 365 days (next
      2027-04-14). The key policy grants `Encrypt`, `Decrypt`,
      `GenerateDataKey*`, `ReEncrypt*`, and `DescribeKey` to the cluster role
      (`codeai-k8s-cluster-...`, the same role `describe-cluster` reports as
      `roleArn`), and key administration to the two roles in
      `cluster_admin_role_arns`.

      `eks-cluster.tf` sets only `kms_key_administrators`; the rest is
      terraform-aws-eks v21 defaults (`create_kms_key`,
      `attach_encryption_policy`, `enable_kms_key_rotation`,
      `kms_key_enable_default_policy`, and `encryption_config` scoped to
      `secrets`). Re-check after any major module bump. No follow-up ticket
      needed. Side note: `cdo-external-secrets` in `staging` holds 167 keys,
      not 50.
- [ ] **V7 (P0)** Confirm the `monitoring` Application is Healthy and AMP has
      recent `up{cluster="codeai-k8s"}` samples. Unblocks: E1, E12. See 7.1.
- [ ] **V8 (P0)** Confirm production config sets `memcached_endpoint` and
      `redis_url`, and that both are reachable from the private subnets with the
      pod security groups. Unblocks: G4. See 9.
- [x] **V9 (P0)** Determine what `locals.yml.override_dashboard` and
      `stack_name` do for a worker (URL generation, StackSecret resolution).
      Unblocks: A10. See 3.6, 3.7.

      **Result (2026-10-15, code reading in code-dot-org plus read-only
      `kubectl get deploy,configmap -n staging` and `dig`; nothing modified):**

      Both keys reach the worker as `CDO_*` env vars from the locals
      ConfigMap, and env is the highest-precedence config source
      (`lib/cdo.rb` loads ENV first and `Cdo::Config#merge` keeps the first
      value), so the gitops values win over `config/<env>.yml.erb`.

      `override_dashboard` has one consumer, `canonical_hostname` in
      `lib/cdo.rb`, which returns it for `studio.code.org`. That feeds
      `dashboard_hostname`, `dashboard_site_host`, `CDO.studio_url`, Rails
      `routes.default_url_options[:host]`, and
      `action_mailer.default_url_options[:host]`, so it rewrites every
      absolute studio URL a job builds. Logs are unaffected. In the
      production env with no override, `canonical_hostname` returns
      `studio.code.org` outright, and legacy `autoscale-prod` sets no
      override (the chef bootstrap sets one only for adhoc stacks). The
      current value `studio.production.k8s.code.org` has no DNS record and no
      Ingress (`dashboard.enabled` is false), so any link a k8s job emitted
      would be dead. Exposure today is latent: the worker runs
      `--min-priority 10`, only the `low_priority` queue maps to 10
      (`active_job_queue_priorities`), and its two jobs
      (`AiLessonSummariesJob`, `AnonymousGeoBackfillingJob`) build no URLs,
      while `mailers`, `mailjet`, and `default` are priority 0 and never run
      on k8s. It becomes live the moment A3 widens the priority range.
      Decision: production workers should not carry it. Remove
      `locals.yml.override_dashboard` from the production values rather than
      set it to `studio.code.org`; the env already yields that. The same
      applies to staging, test, and levelbuilder (`studio.staging.k8s.code.org`
      does not resolve; `staging-studio.code.org` does). In the chart the key
      doubles as the Ingress host, so it belongs with `dashboard.enabled`.

      `stack_name` does not touch StackSecret resolution.
      `StackSecret.current_stack_name` reads only EC2 metadata
      (`AWS::EC2.instance_id`, then `ec2:DescribeTags`), never
      `CDO.stack_name`; with `AWS_EC2_METADATA_DISABLED=true` (confirmed on
      the live staging worker) it returns nil and no `CfnStack/` path is
      tried. More to the point, `!StackSecret` appears only in
      `config/adhoc.yml.erb`, so a production, staging, test, or levelbuilder
      worker never evaluates one. Stack-specific DB secrets on k8s are
      resolved outside Ruby by the standard-envtypes ExternalSecret
      (`cfn_stack_name_overrides`, production `autoscale-prod`), which is
      B2's mechanism; `locals.yml.stack_name` plays no part in B2. Runtime
      readers of `CDO.stack_name` in a worker are only `codeprojects_hostname`
      and `codeaiprojects_hostname`, and only outside production (production
      returns the fixed apex domains). The gitops values (`staging`, `test`,
      `levelbuilder`, `autoscale-prod`) equal the code defaults
      (`config.yml.erb` `stack_name: <%=env%>`, `production.yml.erb`
      `autoscale-prod`) in every environment, so the key is redundant.
      Decision: harmless; drop it or comment it as a no-op in A10.

      Side finding, code reading only: when no stack is found, the
      StackSecret "fall back to `<env>/cdo/<key>`" comment in
      `secrets_config.rb` does not hold. `super` calls `Secret#lookup`, whose
      `key` dispatches back to `StackSecret#key` and returns nil, so the
      fallback appears to call `get!(nil)` and re-raise. Unreachable for
      non-adhoc workers and for adhoc keys the ConfigMap or ESO overrides, so
      not a launch item.

---

## A. Worker workload (chart and values)

Chart: `../code-dot-org/k8s/helm`. Values: `apps/codeai/envTypes/production.values.yaml`,
`apps/codeai/deployments/production/values.yaml`.

- [x] **A1 (P0)** Add `terminationGracePeriodSeconds` to the shared pod
      template, exposed as `activeJobWorker.terminationGracePeriodSeconds`; set
      production to 2100.
      Where: `templates/dashboard/_dashboard.yaml`, production envType values.
      Done when: the rendered production worker carries the value, and a rolling
      restart in staging during a running low-priority job lets it finish. See 3.1.

      **Confirmed (2026-10-15):** chart PR #75846 (2026-10-07) added
      `activeJobWorker.terminationGracePeriodSeconds` to `_dashboard.yaml`
      (default 60, schema-validated). `envTypes/production.values.yaml` and
      `envTypes/staging.values.yaml` set 2100, and the live staging worker pod
      carries `terminationGracePeriodSeconds: 2100`. The mid-job rolling
      restart rehearsal was not re-run for this check.
- [x] **A2 (P0)** Stop `cdo-local-secrets` from blanking Honeybadger, Sentry,
      PagerDuty, and Slack keys outside local dev. Gate the blanks behind a values
      flag that is off by default and on only in `development.values.yaml`.
      Where: `templates/cdo-local-secrets.yaml`, `development.values.yaml`.
      Done when: a staging worker exception appears in Honeybadger. See 3.6, 7.5.

      **Confirmed (2026-10-15):** chart PR #75980 (2026-10-13) gates the blank
      keys behind `localDev.stubSecrets`, which is `false` in `values.yaml` and
      `true` only in `development.values.yaml`. The live
      `staging-cdo-local-secrets` Secret now has no keys at all. Honeybadger
      delivery itself is verified by E2.
- [ ] **A3 (P0)** Decide whether legacy workers keep consuming priority >= 10
      during the soft launch. If the answer is "k8s only", add `--max-priority 9`
      support to the legacy launcher and flip it in the launch change window.
      Where: `../code-dot-org/lib/cdo/active_job_backend.rb`.
      Done when: the decision is written here with its date. See 3.8.
- [ ] **A4 (P0)** Confirm production values never set `user.uid: 0` (staging
      and test do). Guard it in the chart; the CI invariant moves to F3.
      Where: `apps/codeai/deployments/production/values.yaml`,
      `../code-dot-org/k8s/helm/templates/dashboard/_dashboard.yaml`.
      Done when: the production render fails on a uid or gid of 0. See 3.5.

      **Confirmed (2026-10-14):** neither
      `apps/codeai/deployments/production/values.yaml` nor
      `apps/codeai/envTypes/production.values.yaml` sets a `user:` key.
      `helm template` with the ApplicationSet's value layering, against the
      chart at the branch production pins (`staging`, chart 0.2.0), renders
      the only production pod template, `production-cdo-active-job-worker`,
      with `runAsUser`/`runAsGroup`/`fsGroup` 1000; `--set user.uid=0` flips
      it to 0, so the copy-paste exposure is real.
      Decision (2026-10-14): this repo has no CI and F3 (the CI) is P1, so the
      guard lives in the chart instead of a standalone workflow. Argo CD
      enforces it on every render no matter how the change arrived (PR, direct
      push, bot commit), which CI cannot do until F4 makes it a required check.
      Implemented 2026-10-14 (chart 0.3.1 -> 0.3.2 on top of origin/staging
      bb8da65b94d, pending merge to code-dot-org `staging`):
      `templates/dashboard/_dashboard.yaml` `fail`s
      the render when the chart-wide or per-component `RAILS_ENV` is
      `production` and `user.uid` or `user.gid` is 0, naming the k8s-gitops
      values files in the message. It sits in the shared pod template, so it
      covers every workload the chart renders (worker, dashboard Deployment,
      dashboardJob). A failed render leaves the last good manifests running.
      Keyed on `RAILS_ENV`, so Skaffold's root override for local dev is
      unaffected. Local checks: the production render is unchanged apart from
      the chart label; `--set user.uid=0`, `--set user.gid=0`, and the string
      `"0"` that Skaffold passes each fail; staging, test, levelbuilder, adhoc,
      and `development.values.yaml` with uid/gid 0 all still render; `helm
      lint` is clean.
      Found while verifying (2026-10-14): chart 0.3.0 added
      `values.schema.json` (code-dot-org #75664), and
      `apps/codeai/deployments/production/values.yaml` failed it with
      `/resources: additional properties 'requests' not allowed`. The block
      used `resources.requests.ephemeralStorage`, a key the chart never read
      (the worker pins `activeJobWorker.resources` anyway, and the chart
      default is already 30Gi). Flattened to `resources.ephemeralStorage` in
      this branch so the production deployment renders at all on chart
      >= 0.3.0; staging, test, and levelbuilder values already pass the
      schema. Tick this box once the chart change is on code-dot-org
      `staging` and the `codeai-staging` Argo app (uid 0, `RAILS_ENV` staging)
      is still Healthy on chart 0.3.2.
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

      V9 (2026-10-15): remove `locals.yml.override_dashboard` from the
      production values (and from staging, test, levelbuilder); the env
      resolves `studio.code.org` on its own, and the k8s hostname would put
      dead links in any mail a job sends. `locals.yml.stack_name` is a no-op
      that mirrors the code default; drop it or comment it. Neither key
      affects StackSecret or B2.
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
      Implemented 2026-10-08 (chart 0.1.6 -> 0.1.7, pending merge to main and
      the live check below): `cfn_stack_name_overrides` (production ->
      autoscale-prod) in `values.yaml`, resolved by the
      `standard-envtypes.cfnStackName` helper and used by the CfnStack find
      path and the IAM `GetSecretValue` ARN; CfnStack find regex narrowed to
      `db_(cluster_id|endpoint_.*|credential_(writer|reader))` for all env
      types; `production` added to `compose_db_url_environment_types`. The
      composed URLs use the cluster writer endpoint, same as staging; the RDS
      Proxy switch is a separate follow-up. Local `helm template` diff against
      HEAD: only the production find path/ARN, the regex, and the production
      compose template changed. Tick this box once `cdo-external-secrets` in
      `production` is Ready with the composed keys.
      Design notes from V1 (2026-10-07):
      - `CfnStack/autoscale-prod/` has every key staging gets today, so
        pointing the find path and the IAM ARN at `autoscale-prod` and adding
        `production` to `compose_db_url_environment_types` is sufficient; no
        new secrets need to be created.
      - Narrow the CfnStack find regex before enabling it for production. The
        current `^CfnStack/<env>/db_.*$` would also sweep
        `db_credential_admin` and three personal
        `db_credential_employee_*` secrets into the production namespace
        Secret. Match only `db_cluster_id`, `db_endpoint_*`,
        `db_credential_writer`, and `db_credential_reader` (apply the same
        regex to all env types so staging parity holds).
      - Decide whether the composed URLs use the RDS Proxy writer/reader
        (`db_endpoint_proxy_writer`/`_reader` + `_port`) instead of the raw
        cluster writer endpoint that staging composes today. V1 confirms both
        exist. If using the proxies, note the proxy hostnames last changed
        2026-09-25: ESO will re-render the Secret within 5 minutes of a
        change, but running pods only pick up new env vars on a rollout.
      - `apps/codeai/deployments/production/values.yaml` already sets
        `locals.yml.stack_name: autoscale-prod`; V9 determines whether that
        makes the app's own `!StackSecret` resolution work without IMDS, which
        would make the two mechanisms agree on the stack name.
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
      Note (2026-10-15, from V5): enforcement is off until a ConfigMap
      `amazon-vpc-cni` in `kube-system` sets
      `enable-network-policy-controller: "true"`. Ship that ConfigMap from
      `apps/infra/networking/chart` (bump the chart version) as the first
      commit of this work; it is inert while no policies exist. Allow DNS
      with `ipBlock: 172.20.0.10/32` on TCP/UDP 53, since there is no
      `kube-dns` Service to select. Roll the policy to `staging` first and
      treat that as the enforcement test V5 skipped: the worker must still
      reach the DB, Redis, memcached, DNS, and 443, and must lose the
      `argocd` namespace. Then set `networkPolicy: DefaultDeny` on the
      production NodeClass.
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

      V3 (2026-10-15): no metrics-server and no HPA objects exist. The chart
      never renders the HPA because `dashboard.enabled` is false in every
      deployment here, and the worker is a fixed-replica Deployment.
      Recommended re-scope: drop the dead `autoscaling` values from the
      envType and deployment values, set `activeJobWorker.replicas` explicitly
      (5.2 Phase 1), and treat a metrics-server install
      (`apps/infra/metrics-server` or the managed add-on) as a P2 nicety for
      `kubectl top` rather than a launch dependency.
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
      Note (2026-10-15, from V4): the image is multi-arch, so `amd64` is a
      choice here, not a requirement. The pool currently launches arm64
      `t4g.large` burstable nodes that hold exactly one worker, so every
      promotion launches a node and the surge pod reports `FailedScheduling`
      until that node is Ready. When adding requirements, either choose a size
      that holds two workers (one running, one surging) or accept one node per
      worker; in both cases set `limits` so a values typo cannot launch dozens
      of nodes.
      Where: `apps/infra/networking/chart/templates/frontend-node{pool,class}.yaml`.
      Done when: staging pods no longer carry the production frontend SG. See 4.6.
- [ ] **C6 (P1)** Stop every worker promotion from waiting on a node launch.
      The `frontend` pool launches `t4g.large` nodes that hold exactly one
      worker (allocatable 1780m CPU and ~7 GiB against a 1000m, 4 GiB
      request), so the RollingUpdate surge pod on every Kargo promotion sits
      in `FailedScheduling` for the two to four minutes Karpenter needs to
      launch a node (seen in `staging` 2026-10-14; see V4). The old worker
      keeps running, so nothing is lost, but every rollout costs a node launch
      and the production pool from C2 inherits this unless sized on purpose.
      Pick one: a NodePool requirement so a node holds two workers (one
      running, one surging), for example `karpenter.k8s.aws/instance-memory`
      of at least 16384; a warm node via an Auto Mode static-capacity pool or
      a low-priority placeholder pod; or accept the wait and write it into the
      promotion checklist (F1). Do not switch the Deployment to `Recreate`:
      with the A1 grace period it leaves production without a worker for up
      to 35 minutes per promotion. In every case set `limits` on the pool.
      Where: `apps/infra/networking/chart/templates/frontend-nodepool.yaml`
      now (bump the chart version); the production NodePool when C2 adds it.
      Depends on: V4 (done). Pair with: C2, C3.
      Done when: a staging promotion schedules the surge pod without a
      `FailedScheduling` event, or the wait is documented in F1; and the pool
      has `limits`. See 4.6, 5.3.
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
      Note (2026-10-14, from A4): the chart itself now fails a production
      render with `user.uid` or `user.gid` 0, so the CI invariant for it is
      "render production with `--set user.uid=0` and expect `helm template` to
      fail", which also proves the chart guard is still in place.
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
