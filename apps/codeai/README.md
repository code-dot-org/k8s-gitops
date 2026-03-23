This app's authored deployment metadata lives under `deployments/`.

Rendered deploy output is written by Kargo into `stage/<deployment>` branches at
`apps/codeai/deployments/<deployment>/deploy/`, and Argo CD deploys directly from
those rendered branches.

Build publication now writes thin build-lock Freight records under
`warehouses/codeai/builds/` instead of editing deployment `values.yaml` files.
