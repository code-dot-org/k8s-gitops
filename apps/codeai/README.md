This app's deployment definitions live under `deployments/`.

Staging, test, levelbuilder, and production are rendered-branch deployments:

- `main` holds the environment policy and Kargo configuration.
- `stage/<env>` holds the fully rendered manifests Argo CD syncs.
- Kargo renders those branches from `warehouses/codeai/freight/current/helm/` plus the values files in this directory.

`k8s-adhoc` remains a live-source Helm deployment so ad hoc work can keep following a source branch directly.

Bootstrap note:
- The first successful promotion to each staged environment creates its `stage/<env>` branch. Until that first render lands, the corresponding Argo CD `Application` will report a missing target revision.
