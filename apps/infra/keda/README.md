# KEDA

This Argo CD Application installs one shared KEDA instance in namespace `keda`.
The local wrapper vendors the official KEDA chart and app version **2.21.0**,
which supports the cluster's Kubernetes **1.36** version. The `infra` Application
explicitly includes this Application at sync wave 20. The existing root
ApplicationSet brings infrastructure up before workload applications.

KEDA owns the CRDs, operator, external metrics API server, and admission webhook.
Workload-specific ScaledObjects and TriggerAuthentications belong in the
`code-dot-org` app chart. Installing this dependency alone does not enable
autoscaling for existing workloads. No Terraform/OpenTofu changes are needed
for the chart installation.

## Deployment steps

Run these from the repository root with the intended EKS context selected.

1. Before merging, confirm the context and check for an existing external metrics
   adapter or KEDA installation:

   ```sh
   kubectl config current-context
   kubectl version
   kubectl get apiservice v1beta1.external.metrics.k8s.io --ignore-not-found -o yaml
   kubectl get deployments -A | grep -i keda
   ```

   No matching APIService or deployments is expected for a first installation.
   If the APIService exists, identify its owning adapter before proceeding;
   do not replace another adapter implicitly.

2. Merge the GitOps change into `main`. Automated Argo reconciliation deploys
   it; do not run `helm install` or manually apply CRDs. Refresh the parent
   immediately after merging:

   ```sh
   argocd app get infra --refresh
   ```

   If the parent has not moved to the merged revision, run
   `argocd app sync infra`. Once the `keda` Application exists:

   ```sh
   argocd app get keda --refresh
   ```

   If it has not moved to the merged revision, run `argocd app sync keda`.
   These operations are also available at https://argocd.k8s.code.org.

3. Wait for installation health:

   ```sh
   argocd app wait keda --sync --health --timeout 600
   kubectl -n keda rollout status deployment/keda-operator --timeout=300s
   kubectl -n keda rollout status deployment/keda-operator-metrics-apiserver --timeout=300s
   kubectl -n keda rollout status deployment/keda-admission-webhooks --timeout=300s
   kubectl wait --for=condition=Established --timeout=120s crd/scaledobjects.keda.sh crd/scaledjobs.keda.sh crd/triggerauthentications.keda.sh crd/clustertriggerauthentications.keda.sh crd/cloudeventsources.eventing.keda.sh crd/clustercloudeventsources.eventing.keda.sh
   kubectl wait --for=condition=Available --timeout=180s apiservice/v1beta1.external.metrics.k8s.io
   kubectl get --raw /apis/external.metrics.k8s.io/v1beta1
   ```

   The external metrics list can be empty until ScaledObjects are installed.
   If API discovery or webhook calls fail, check control-plane connectivity to
   the metrics server on TCP 6443 and the admission webhook on TCP 9443,
   including the actual pod/node security groups and network policies. Do not
   enable host networking or change security groups without diagnosing the
   failure. Any necessary infrastructure change should be reviewed separately.

4. Enable and smoke-test a ScaledObject through the monorepo chart in a test
   deployment. Verify its Ready condition, generated HPA, metric retrieval,
   and scale-up/scale-down before enabling other deployments. Ensure only one
   HPA controls each target and that Argo does not reset `spec.replicas`.
   Configure scaler-specific credentials/IAM only when the scaler is selected.

## Local validation and upgrades

```sh
helm lint apps/infra/keda/chart --kube-version 1.36.0
helm template keda apps/infra/keda/chart --namespace keda --kube-version 1.36.0 --include-crds > /tmp/keda-rendered.yaml
git diff --check
```

Helm lint warns that this dependency-only wrapper has no `templates/` directory;
the manifests are rendered from the vendored dependency.

For an upgrade, choose an exact compatible dependency version in `Chart.yaml`,
bump the wrapper's top-level `version`, and run
`helm dependency update apps/infra/keda/chart`. Commit `Chart.yaml`, `Chart.lock`,
and the updated `charts/keda-*.tgz` together. Review the upstream release notes
and CRD changes and repeat rendering and deployment validation. The archive
SHA-256 for 2.21.0 is
`a7da56bf41a33dad9d2fc82a6fdecee552fff947d80bf1e1dbcf4db0f9e26dee`.

The Application uses automated pruning and a cascading deletion finalizer,
matching the other infra apps. Before uninstalling KEDA, migrate/remove its
ScaledObjects and ScaledJobs while the operator is still running; deleting CRDs
also deletes their custom resources. Do not treat uninstall as a routine rollback
of a controller upgrade.

References: [compatibility](https://keda.sh/docs/2.21/operate/cluster/),
[installation](https://keda.sh/docs/2.21/deploy/),
[troubleshooting](https://keda.sh/docs/2.21/troubleshooting/).
