`main` keeps deployment metadata, env policy, and the Kargo temp-wrapper templates.

Rendered manifests live on `stage/<deployment>` branches at `apps/codeai/deployments/<deployment>/deploy/`.
Argo CD deploys those rendered paths directly; Kargo promotion is responsible for rehydrating the OCI release capsule and writing them.
