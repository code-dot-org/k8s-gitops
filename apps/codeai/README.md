This app's deployment definitions live under `deployments/`.

Kargo promotes thin build-lock records from `warehouses/codeai/builds/` and
updates each deployment's `targetRevision` plus deployment-specific `values.yaml`
image.
