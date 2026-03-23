This app's deployment definitions live under `deployments/`.

`main` holds deployment metadata and Helm values inputs. Argo CD deploys rendered
output from the `stage/<deployment>` branches at
`apps/codeai/deployments/<deployment>/deploy/`.

Kargo now renders from the matching OCI release capsule instead of mutating
`values.yaml` on `main`.
