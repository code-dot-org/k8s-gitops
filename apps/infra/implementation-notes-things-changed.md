# implementation notes: things changed

This file records systemic fixes made during the `cluster-infra-argocd`
rebootstrap and Argo self-management rollout. The point is not narrative. The
point is to leave behind exact cause, failed approaches, and the reason the
kept change was kept.

## 2026-04-03: make bootstrap Argo upgrades track `k8s-gitops` `main`

### What happened

`argocd-bootstrap.tf` sparse-cloned `apps/infra/argocd/chart` from
`k8s-gitops`, but `helm_release.argocd_bootstrap` did not reliably notice that
the chart contents had changed at the same path.

The local checkout changed. The Helm release did not always see a change worth
upgrading.

### What was tried

- rely on the sparse checkout content changing in place

### What worked

Add a synthetic bootstrap-only value carrying the current `k8s-gitops` default
branch SHA:

```hcl
values = [
  yamlencode({
    _bootstrap = {
      k8s_gitops_revision = data.github_branch.k8s_gitops_default.sha
    }
  })
]
```

### What did not

- assuming the local chart path changing in place was enough

### Why this change won

It is explicit and cheap. The Helm release can now see a value change whenever
`k8s-gitops` `main` moves, without inventing a more elaborate bootstrap
transport.

## 2026-04-03: enable Git LFS for the `k8s-gitops` Argo repo

### What happened

The self-managed `argocd` app in `k8s-gitops` contains vendored chart tarballs
under `chart/charts/*.tgz`. Those files are tracked with Git LFS.

Repo-server fetched the repo without LFS smudge and then tried to unpack the
pointer file as gzip. The visible error was:

- `gzip: invalid header`

### What was tried

- let the self-managed `argocd` app apply the repo-secret change that would
  have enabled LFS

### What worked

Enable:

```yaml
enableLfs: "true"
```

for the `k8s-gitops` Argo repo secret, then re-run bootstrap so the Tofu-owned
bootstrap Argo release applies the repo secret before the self-managed app has
to render itself.

### What did not

- expecting the broken self-managed `argocd` app to render the fix that would
  have allowed it to render

This was a catch-22.

### Why this change won

It is the smallest repo-scoped fix. Argo already knows how to use LFS. The
missing part was enabling it for the repo whose vendored chart tarballs are
actually LFS objects.

## 2026-04-03: move ESO-dependent Argo secret resources out of the main Argo chart

### What happened

The main Argo wrapper chart rendered ESO-dependent resources:

- `argocd-secret-external-secret.yaml`
- `argocd-dex-client-secret-generator.yaml`

During bootstrap, those resources were unsafe because ESO and its generator
CRDs were not yet up.

The temporary hack was a bootstrap-only value flip:

- bootstrap render: do not install those resources
- self-managed steady-state render: do install them

That created a bad handoff. Self-managed Argo flipped them on before ESO was
fully ready from Argo's point of view.

### What was tried

- a bootstrap-only gate in the main Argo chart
- an override in `argocd-bootstrap.tf` that forced the gate off

### What worked

Move those templates into the `dex` chart, which already comes after Argo and
after ESO:

- `/Users/seth/src/k8s-gitops/apps/infra/dex/chart/templates/argocd-secret-external-secret.yaml`
- `/Users/seth/src/k8s-gitops/apps/infra/dex/chart/templates/argocd-dex-client-secret-generator.yaml`

and remove the bootstrap-only gate from the main Argo chart.

### What did not

- keeping the resources in the main Argo chart with a bootstrap-only flag

### Why this change won

It removed the bootstrap-vs-steady-state mismatch entirely. The main Argo chart
became bootstrap-safe by construction instead of by a temporary value flip.

## 2026-04-03: use `RollingSync` plus restored `Application` health for top-level ordering

### What happened

We needed:

- `infra` first
- then everything else

Plain top-level sync-waves on generated `Application` resources were not a good
fit. The problem was not child resource ordering inside one app. The problem
was ordering whole generated apps and waiting for health.

### What was tried

- top-level sync-wave thinking carried over from the old app-of-apps mental model

### What worked

- enable progressive syncs
- restore `argoproj.io/Application` health assessment
- label the `infra` top-level app with `code.org/bootstrap-group=infra`
- use `RollingSync` with two steps:
  - `In [infra]`
  - `NotIn [infra]`

### What did not

- relying on top-level sync-waves alone

### Why this change won

`RollingSync` sequences generated `Application`s and waits on their health. That
is exactly the top-level problem we had.

## 2026-04-03: size the Argo application controller for bootstrap load

### What happened

On Fargate, the default application-controller shape was too small for the
initial full infra bootstrap. The controller was OOM-killed during rollout.

### What was tried

- restart the controller and let it come back on the default shape

### What worked

Set explicit controller resources:

```yaml
controller:
  resources:
    requests:
      cpu: 1000m
      memory: 4Gi
    limits:
      cpu: 1000m
      memory: 4Gi
```

### What did not

- relying on the Fargate default shape

### Why this change won

It was the smallest safe fix that got the controller through the bootstrap
burst. It is intentionally documented in-chart as provisional and should be
profiled later.

## 2026-04-03: render ESO defaulted fields explicitly

### What happened

Several apps became:

- `Healthy`
- `OutOfSync`

at the same time.

The affected resources were `ExternalSecret` and `ClusterExternalSecret`
objects. ESO was writing additional fields into `spec`, and Argo then compared
live objects that had those fields against desired objects that did not.

Affected apps:

- `dex`
- `kargo-secrets`
- `standard-envtypes`

### What was tried

- refresh the apps
- sync the apps again
- assume the remaining drift was stale status

### What worked

Render the defaulted fields explicitly in Git, including:

- `deletionPolicy: Retain`
- `engineVersion: v2`
- `mergePolicy: Replace`
- `conversionStrategy: Default`
- `decodingStrategy: None`
- `metadataPolicy: None`

This was applied in the copied charts and mirrored into the legacy
`cluster-infra-argocd/infra/*` charts.

### What did not

- repeated refresh/sync without changing the templates

### Why this change won

Argo was comparing `spec`, not intent. The live objects had a stable shape that
we could see and reproduce. Rendering the same shape was the direct fix.

See also:

- `/Users/seth/src/code-dot-org/k8s/tofu/codeai-k8s/TODO.extra-secret-fields.md`

## 2026-04-03: remove the stale vendored `eso-per-envtype` package and rebuild it

### What happened

`standard-envtypes` had been changed to use the shared local dependency:

- `file://../../charts/eso-per-env`

but the chart still had a stale packaged dependency sitting in:

- `apps/infra/standard-envtypes/chart/charts/eso-per-envtype-0.1.0.tgz`

Helm was rendering that stale package, not the shared chart we had edited.

### What was tried

- edit the shared `apps/infra/charts/eso-per-env/templates/_envtype.tpl`

### What worked

- remove the stale vendored package
- run `helm dependency update`
- commit the rebuilt package

### What did not

- editing only the shared chart while the stale package was still present

### Why this change won

It made Helm render the chart we actually meant it to render, without relying
on guesswork about dependency precedence.

## 2026-04-03: make `LoadBalancerConfiguration` match the AWS gateway controller default

### What happened

`networking` stayed `OutOfSync` on:

- `LoadBalancerConfiguration/kube-system/aws-alb`

The live object had:

- `alpnPolicy: None`

and the chart did not.

### What was tried

- assume the diff was just status noise

### What worked

Render:

```yaml
listenerConfigurations:
  - alpnPolicy: None
    protocolPort: "HTTPS:443"
    defaultCertificate: ...
```

### What did not

- leaving the controller-defaulted field implicit

### Why this change won

It was the same class of problem as the ESO defaults, just in a different CRD.

## 2026-04-03: ignore AWS load balancer controller webhook cert churn in Argo

### What happened

The AWS load balancer controller subchart generates webhook certs at render
time when it cannot reuse an existing secret via `lookup`. Under GitOps
rendering in Argo, that produced stable health but permanent diff churn in:

- `Secret/kube-system/aws-load-balancer-tls`
- `MutatingWebhookConfiguration/aws-load-balancer-webhook`
- `ValidatingWebhookConfiguration/aws-load-balancer-webhook`

### What was tried

- rely on the subchart's `keepTLSSecret` behavior

### What worked

Ignore only the generated material:

- secret `/data`
- webhook `clientConfig.caBundle`

in the `networking` `Application`.

### What did not

- expecting the subchart's render-time cert generation to be stable under Argo

### Why this change won

The chart is generating cert bytes during render. That is not meaningful drift
for GitOps purposes. Ignoring only those generated fields is narrower and less
damaging than ignoring the whole resources.

## 2026-04-03: grant Kargo controller CRD discovery explicitly

### What happened

After the bootstrap and infra rollout were fixed, the top-level `kargo` app was
still stuck `Progressing` because `kargo-controller` was crashing.

The concrete error was:

- `error initializing Kargo controller manager: unable to determine if Argo Rollouts is installed: Unauthorized`

Checking the effective RBAC for
`system:serviceaccount:kargo:kargo-controller` showed:

- it could not `list customresourcedefinitions.apiextensions.k8s.io`

### What was tried

- chase the problem as stale rollout residue from the earlier deep clean
- clear the stale `kargo-controller` service account wait
- restart the Argo application controller

Those steps were useful, but they only exposed the real failure more clearly.

### What worked

Use the Kargo chart's `extraObjects` hook to add a narrow ClusterRole and
ClusterRoleBinding granting the controller:

- `get`
- `list`
- `watch`

on:

- `customresourcedefinitions.apiextensions.k8s.io`

### What did not

- pretending this was still only a stale sync operation

### Why this change won

The chart already supports appending extra objects. That let us keep the fix in
Git, scoped tightly to the permission actually missing, without forking the OCI
chart or hand-patching live RBAC.
