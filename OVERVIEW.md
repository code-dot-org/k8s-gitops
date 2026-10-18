# k8s-gitops Overview

This is the **GitOps source of truth** for Code.org's `codeai-k8s` EKS cluster. Every Kubernetes resource — from the platform infrastructure to application deployments — is declared in this repo and reconciled by ArgoCD.

**Key UIs:**

- ArgoCD: https://argocd.k8s.code.org
- Kargo: https://kargo.k8s.code.org

**Related repo:** [code-dot-org/code-dot-org](https://github.com/code-dot-org/code-dot-org) — the application source. Its Helm chart lives at `k8s/helm` and Kustomize base at `k8s/kustomize`.

---

## How changes get deployed

1. Merge a change to `main` in this repo.
2. ArgoCD polls for changes — **avg 2m 30s**, max 5 minutes.
3. ArgoCD auto-syncs the affected Application(s).

That's it. There is no CI/CD pipeline in this repo and no manual `kubectl apply` needed for day-to-day work. ArgoCD is the only deployer.

---

## Directory structure

```
k8s-gitops/
  apps/                             # Everything ArgoCD manages
    app-of-apps/                    # Root ApplicationSet (discovers all other apps)
    codeai/                         # The Code.org application
    infra/                          # Platform infrastructure (ArgoCD, DNS, secrets, etc.)
    kargo/                          # Kargo progressive delivery system

  bootstrap/                        # OpenTofu IaC for cluster creation (not day-to-day)
    codeai-k8s/                     # EKS cluster bootstrap (3 ordered modules)
    codeai-k8s-dex/                 # Google Workspace SSO setup (once per org)
    apptrees/                       # Test fixtures for Argo behavior
    modules/                        # Reusable Tofu modules
```

---

## The app-of-apps pattern

ArgoCD uses a single root `ApplicationSet` ([apps/app-of-apps/app-of-apps.yaml](apps/app-of-apps/app-of-apps.yaml)) that automatically discovers all apps by scanning for:

- `apps/*/application.yaml` — treated as passthrough (the file's metadata/spec become the Argo Application directly)
- `apps/*/applicationset.yaml` — wrapped in an Application that points at the directory

This means **adding a new app** is as simple as dropping an `application.yaml` or `applicationset.yaml` into a new `apps/<name>/` directory. ArgoCD will pick it up on its next poll.

The root ApplicationSet uses **RollingSync** with two ordered groups:
1. `infra` (labeled `code.org/bootstrap-group: infra`) — syncs first
2. Everything else — syncs second

All apps use **auto-prune**, **self-heal**, and **ServerSideApply**.

---

## Codeai application deployments

### Deployment structure

Each deployment lives under `apps/codeai/deployments/<name>/` and contains:

- `deployment.yaml` — declares the environment type, namespace, and branch
- `values.yaml` — Helm values: container image, DNS name, scaling, stack config

Current deployments:

| Deployment | Environment | RAILS_ENV | DNS | Notes |
|---|---|---|---|---|
| **staging** | staging | staging | studio.staging.k8s.code.org | Auto-promoted by Kargo |
| **test** | test | staging | — | Manual promote from staging |
| **production** | production | production | studio.production.k8s.code.org | Manual promote from test |
| **levelbuilder** | levelbuilder | levelbuilder | — | Development/admin tools |

### Helm values hierarchy

Values are layered (later overrides earlier):

1. **Base chart** — from `code-dot-org/code-dot-org` repo at `k8s/helm`
2. **Environment type** — `apps/codeai/envTypes/<envType>.values.yaml` (sets `RAILS_ENV`, health checks, scheduling, autoscaling defaults)
3. **Deployment-specific** — `apps/codeai/deployments/<name>/values.yaml` (sets image tag, DNS name, stack name, replica overrides)

Example: for the staging deployment, ArgoCD merges:
```
k8s/helm (base chart)
  + apps/codeai/envTypes/staging.values.yaml       (RAILS_ENV: staging, healthChecks: enabled)
  + apps/codeai/deployments/staging/values.yaml     (image: ghcr.io/...:git-<sha>, dnsName: studio.staging)
```

### How to change a deployment's config

Edit the relevant `values.yaml` file and merge to `main`. ArgoCD does the rest.

- To change something common to all staging-type environments: edit `apps/codeai/envTypes/staging.values.yaml`
- To change something specific to one deployment: edit `apps/codeai/deployments/<name>/values.yaml`

---

## Kargo: image promotion

Kargo handles progressive delivery of new container images through environments.

### How it works

1. **Warehouse** ([apps/kargo/projects/codeai/warehouse.yaml](apps/kargo/projects/codeai/warehouse.yaml)) watches `ghcr.io/code-dot-org/code-dot-org` for new images tagged `git-<40-char-sha>`.
2. **Stages** form a promotion pipeline:
   ```
   Warehouse ──(auto)──> staging ──(manual)──> test ──(manual)──> production
   ```
3. When a promotion runs, Kargo:
   - Clones this repo's `main` branch
   - Updates the target deployment's `values.yaml` with the new image tag
   - Commits with `[skip ci]` and pushes
   - Triggers an ArgoCD refresh on the affected Application

### Promotion in practice

- **staging** receives new images automatically (direct from warehouse)
- **test** and **production** require manual promotion via the [Kargo UI](https://kargo.k8s.code.org)

Kargo commits show up in git history like:
```
Promote staging to git-482363e1c914b6f65ac18d9201456b48bd988cbb [skip ci]
```

### Image writeback (GitHub Actions)

The image tag writeback from CI builds is handled by the `k8s-commit-image-ref-to-argocd.yml` workflow in the [code-dot-org](https://github.com/code-dot-org/code-dot-org) repo (not this repo).

---

## Infrastructure apps

All platform services live under `apps/infra/` and are managed as child applications of the `infra` Argo Application ([apps/infra/application.yaml](apps/infra/application.yaml)).

| App | What it does |
|---|---|
| **networking** | AWS ALB Ingress Controller for load balancing |
| **external-dns** | Auto-creates Route53 DNS records from Ingress annotations |
| **external-secrets-operator** | Syncs AWS Secrets Manager entries into Kubernetes Secrets |
| **standard-envtypes** | Shared per-environment resources (SecretStores, etc.) |
| **dex** | OIDC/SSO provider — authenticates users via Google Workspace |
| **argocd** | ArgoCD itself (self-managed after bootstrap) |
| **crossplane** | Kubernetes-native AWS resource provisioning |
| **kargo-secrets** | Git credentials and webhook secrets for Kargo |

Infrastructure apps use **sync waves** to control ordering (networking first, ArgoCD last). Each app gets its cluster-specific configuration from `apps/infra/codeai-cluster-config.values.yaml`, which is generated by OpenTofu during bootstrap.

---

## Secrets management

Secrets follow a consistent pattern:

1. **Bootstrap**: secrets are created in AWS Secrets Manager by the OpenTofu `cluster-infra` module, prefixed with `k8s/tofu/<cluster>/`
2. **Runtime**: External Secrets Operator reads from AWS Secrets Manager and creates Kubernetes Secrets
3. **Per-environment**: Each environment type gets its own SecretStore via the `standard-envtypes` infra app

The `bootstrapped-aws-secret` Tofu module ([bootstrap/modules/bootstrapped-aws-secret/](bootstrap/modules/bootstrapped-aws-secret/)) provides a reusable pattern:
- Set a variable and apply once to upload a secret to AWS Secrets Manager
- Omit the variable on subsequent applies to read it back

Key secrets:

| Secret | Purpose | AWS path |
|---|---|---|
| Dex Google OAuth | SSO login | `k8s/tofu/<cluster>/dex_google_client_secret` |
| Kargo git PAT | Push deployment commits | `k8s/tofu/<cluster>/kargo/gitops_repo_password` |
| GitHub webhook secret | Kargo refresh webhooks | `k8s/tofu/<cluster>/kargo/github_org_webhook_secret` |

---

## SSO and access control

Authentication is handled by **Dex**, which integrates with Google Workspace:

- Users sign in with their `@code.org` Google account
- Dex looks up Google group membership (e.g., `engineering@code.org`, `infrastructure@code.org`)
- Group membership determines in-cluster permissions

The Google Cloud service account for group lookup is configured in `bootstrap/codeai-k8s-dex/` (one-time setup per org, requires a Google Workspace superadmin to delegate domain-wide access).

---

## Cluster bootstrap (from scratch)

This is only needed when creating a new cluster. Day-to-day work doesn't touch this.

Three OpenTofu root modules applied in order:

### 1. cluster/ — EKS cluster + networking
```bash
cd bootstrap/codeai-k8s/cluster
tofu init && AWS_PROFILE=codeorg-admin tofu apply
```
Creates the EKS Auto Mode cluster, VPC, subnets, NAT gateways, security groups, KMS key, and OIDC provider.

### 2. cluster-infra/ — AWS-side resources
```bash
cd bootstrap/codeai-k8s/cluster-infra
tofu init && AWS_PROFILE=codeorg-admin tofu apply
```
Creates secrets in AWS Secrets Manager, IAM roles, and generates `apps/infra/codeai-cluster-config.values.yaml` (cluster facts consumed by Helm charts).

First-time bootstrap requires setting `dex_google_client_secret`, `kargo_k8s_gitops_repo_username`, and `kargo_k8s_gitops_repo_password` in `terraform.tfvars`. Remove secrets from tfvars after the first apply.

### 3. cluster-infra-argocd/ — Kubernetes bootstrap
```bash
cd bootstrap/codeai-k8s/cluster-infra-argocd
bundle install
tofu init && AWS_PROFILE=cdo-readwrite tofu apply
```
Installs ArgoCD, External Secrets Operator, ExternalDNS, Dex, and bootstraps the app-of-apps. After this, ArgoCD takes over and manages everything from `apps/`.

### Once per org
- `bootstrap/codeai-k8s-dex/` — Google Cloud service account for Dex group lookup. Requires superadmin delegation.

### Smoke tests
```bash
cd bootstrap/codeai-k8s
./cluster-smoke-tests/test-pod-and-dns.sh
./cluster-smoke-tests/test-ingress.sh
./cluster-smoke-tests/test-external-secrets.sh
./cluster-smoke-tests/test-nlb.sh
```

---

## Bootstrapping / destroying app-of-apps without Tofu

If you already have an ArgoCD instance:

```bash
# Create
kubectl apply -f apps/app-of-apps/bootstrap.yaml

# Destroy
kubectl delete -f apps/app-of-apps/bootstrap.yaml
```

Both operations can take 30+ minutes.

---

## Monitoring and debugging tools

Located in `bootstrap/codeai-k8s/cluster-infra-argocd/bin/`:

| Tool | Usage |
|---|---|
| `argo-trace` | Prints the live Argo/Kubernetes dependency tree |
| `watch-argo-trace` | Runs argo-trace in a continuous loop (default for watching the cluster) |
| `log-cluster-events start [label]` | Starts tailing cluster events + argo-trace sidecar logger |
| `log-cluster-events stop` | Stops the event watchers |
| `wait-for-200` | Polls an HTTP endpoint until it returns 200 |

### Log files

When `log-cluster-events` is running, it writes three logs:

- `logs/cluster-events-<timestamp>-<label>.log` — raw cluster events
- `cluster.log` — combined log
- `logs/argo-trace-<label>-<timestamp>.log.md` — primary debugging resource (rendered Argo tree over time)

### Running tests

```bash
cd bootstrap/codeai-k8s/cluster-infra-argocd
bundle install
ruby test/argo-trace/argo_trace_test.rb
ruby test/log_cluster_events_test.rb
ruby test/wait_for_200_test.rb
```

---

## Test fixtures

The `bootstrap/apptrees/` directory contains non-production Argo trees for testing:

- **mimic/** — A small replica of the real `apps/` tree structure. Use it to test ArgoCD behavior (app-of-apps recursion, ApplicationSet wrappers, Ingress) without affecting production. All resource names start with `mimic-`.
- **argo-trace-stress-test/** — A broader stress harness for `argo-trace` covering edge cases: broken workloads, finalizer stalls, Crossplane resources, hook Jobs.

When modifying `apps/app-of-apps/*`, make a parallel edit in `bootstrap/apptrees/mimic/apps/app-of-apps/*` to prevent bitrot.

---

## Common tasks

### Deploy a new image to staging
Automatic — Kargo promotes new images from the warehouse to staging as soon as they appear.

### Promote an image from staging to test (or test to production)
Use the [Kargo UI](https://kargo.k8s.code.org) to manually promote freight between stages.

### Change Helm values for a deployment
Edit the file under `apps/codeai/deployments/<name>/values.yaml` or `apps/codeai/envTypes/<envType>.values.yaml`, then merge to `main`.

### Add a new infrastructure app
1. Create `apps/infra/<name>/` with an `application.yaml` and a `chart/` directory
2. Add a source entry in [apps/infra/application.yaml](apps/infra/application.yaml)
3. Merge to `main`

### Bump an app Helm chart
When modifying an app's Helm chart under `apps/`, always bump the `version:` field in its `Chart.yaml` so ArgoCD detects the change.

### Force an ArgoCD refresh
If ArgoCD hasn't picked up a change within 5 minutes, manually trigger a refresh (and if needed, sync) on the affected Application in the [ArgoCD UI](https://argocd.k8s.code.org).

---

## OpenTofu conventions

- **Non-secrets**: commit to `terraform.tfvars` (or `<env>.tfvars` for env-specific values)
- **Secrets**: use the `bootstrapped-aws-secret` module — set the variable once to upload, then remove it from tfvars
- **Secret naming**: prefix with `k8s/tofu/<cluster>/` for per-cluster secrets, or `k8s/tofu/` for shared secrets
- **Profiles**: `AWS_PROFILE=codeorg-admin` for IAM operations, `AWS_PROFILE=cdo-readwrite` for Kubernetes operations
