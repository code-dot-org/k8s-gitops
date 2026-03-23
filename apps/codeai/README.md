CodeAI now uses rendered stage branches.

- `main` keeps deployment metadata and env policy under `apps/codeai/`.
- Kargo renders manifests from the promoted `code-dot-org` commit plus the
  matching immutable image tag.
- Argo CD deploys those rendered manifests from `stage/staging`,
  `stage/test`, `stage/levelbuilder`, and `stage/production`.
- No synthetic `warehouses/codeai/` release record is written back into
  `k8s-gitops`.

The `k8s-adhoc` deployment remains outside this rendered-branch flow.
