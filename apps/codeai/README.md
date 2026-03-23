CodeAI now uses rendered stage branches.

- `main` keeps deployment metadata and env policy under `apps/codeai/`.
- Kargo renders manifests from the promoted `code-dot-org` commit plus the
  matching immutable image tag.
- Argo CD deploys `staging`, `test`, and `levelbuilder` from the auto-syncing
  `codeai` `ApplicationSet`.
- `codeai-production` is a separate Argo CD `Application` with no automated
  sync so the Kargo `production` stage remains the deploy gate after review.
- No synthetic `warehouses/codeai/` release record is written back into
  `k8s-gitops`.
- Before merging the Argo cutover to rendered branches, seed
  `stage/staging`, `stage/test`, `stage/levelbuilder`, and `stage/production`.
  Those refs are remote rollout state; the repo cannot declare them into
  existence on its own.

The `k8s-adhoc` deployment remains outside this rendered-branch flow.
