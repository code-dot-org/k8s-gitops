# apps/infra implementation plan

This directory ports the Helm releases currently declared in [helm.tf](/Users/seth/src/code-dot-org/k8s/tofu/codeai-k8s/cluster-infra-argocd/helm.tf) into Argo child applications.

The port preserves chart content by copy. Rewrite is avoided. The single intentional chart edit is the local dependency path in `standard-envtypes`, because `eso-per-env` is kept as a shared chart under `apps/infra/charts/`.

## Scope

The managed applications are:

- `networking`
- `external-secrets-operator`
- `external-dns`
- `argocd`
- `kargo-secrets`
- `standard-envtypes`
- `dex`

`eso-per-env` is a chart only. It is not an Argo application.

## Layout

The directory layout is:

- `apps/infra/application.yaml`
- `apps/infra/codeai-cluster-config.values.yaml`
- `apps/infra/charts/eso-per-env/`
- `apps/infra/<app>/application.yaml`
- `apps/infra/<app>/chart/`

Each `apps/infra/<app>/chart/` directory is copied from the corresponding source chart under `code-dot-org/k8s/tofu/codeai-k8s/cluster-infra-argocd/infra/`.

The parent application points only at child `application.yaml` files. It does not recurse through chart content.

## Values policy

All child applications load the same generated values file:

- [codeai-cluster-config.values.yaml](/Users/seth/src/k8s-gitops/apps/infra/codeai-cluster-config.values.yaml)

This keeps the child application manifests structurally uniform.

The generated values file contains:

- `codeai_cluster_config`
- specially shaped values for `networking`
- specially shaped values for `dex`
- specially shaped values for `kargo-secrets`

Actual consumers are:

- `standard-envtypes`
- `networking`
- `dex`
- `kargo-secrets`

The remaining charts load the file and ignore unused keys.

## Sync waves and namespaces

The ordering matches the existing `helm.tf` dependency order with the minimum wave count needed to preserve it.

| application | wave | destination namespace | notes |
| --- | ---: | --- | --- |
| `networking` | `0` | `kube-system` | also creates cluster-scoped resources |
| `external-secrets-operator` | `1` | `external-secrets` | also installs CRDs and cluster-scoped resources |
| `external-dns` | `1` | `external-dns` | namespaced release |
| `argocd` | `2` | `argocd` | also installs CRDs and cluster-scoped resources |
| `kargo-secrets` | `2` | `kargo-system-resources` | also creates resources in `kargo-shared-resources` |
| `standard-envtypes` | `2` | `external-secrets` | also creates env namespace resources and cluster-scoped ESO resources |
| `dex` | `3` | `dex` | also creates a `Role` and `RoleBinding` in `argocd` |

## Child application shape

Each child application uses two sources:

1. chart source
   - repo: `https://github.com/code-dot-org/k8s-gitops.git`
   - revision: `main`
   - path: `apps/infra/<app>/chart`
   - values file: `$values/apps/infra/codeai-cluster-config.values.yaml`
2. values source
   - same repo
   - same revision
   - `ref: values`

Each child application also sets:

- `project: default`
- `metadata.namespace: argocd`
- `destination.server: https://kubernetes.default.svc`
- explicit `destination.namespace`
- `syncPolicy.automated.prune: true`
- `syncPolicy.automated.selfHeal: true`
- `syncOptions`
  - `ServerSideApply=true`
  - `CreateNamespace=true`
- `argocd.argoproj.io/sync-wave`

## Verbatim copy policy

The copied charts preserve:

- `Chart.yaml`
- `Chart.lock`
- `values.yaml`
- templates
- helper content
- comments

The allowed edit set is intentionally small:

- adjust the `standard-envtypes` local dependency path from `file://../eso-per-envtype` to `file://../../charts/eso-per-env`

No other chart comments or prose should be rewritten merely to satisfy the port.

## Validation

The local validation standard is:

- `git diff --check` clean
- `helm template` succeeds for all seven copied charts when rendered against `apps/infra/codeai-cluster-config.values.yaml`

The live validation standard is:

- parent `infra` application discovers only child applications
- no standalone `eso-per-env` application exists
- all seven child applications become `Synced` and `Healthy`

## Handoff

Adoption order matters.

The sequence is:

1. commit and push the `apps/infra` structure
2. let Argo adopt the seven child applications
3. verify the applications are healthy
4. remove OpenTofu ownership of the seven corresponding `helm_release` resources without uninstalling them
5. remove the obsolete `helm_release` blocks from `cluster-infra-argocd`

OpenTofu must not be used to uninstall the releases during handoff.
