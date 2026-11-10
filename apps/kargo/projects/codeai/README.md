# Kargo project: codeai

The Argo Application `kargo-project-codeai` applies everything in this
directory except `application.yaml`.

- `application.yaml`: the Argo Application that applies the rest of this
  directory into the `kargo` namespace.
- `project.yaml`, `namespace.yaml`: the Kargo Project and its namespace,
  `kargo-project-codeai`.
- `project-config.yaml`: promotion policies, which Stages auto-promote.
- `cluster-config.yaml`: the GitHub webhook receiver that refreshes the
  Warehouse on push and package events.
- `warehouse.yaml`: follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest
  and creates one Freight per new digest.
- `stages/*.yaml`: one Stage per codeai deployment. A promotion commits a
  digest into `apps/codeai/deployments/<name>/values.yaml` and refreshes the
  `codeai-<name>` Argo Application.

## How Freight flows

- `staging` and `test` auto-promote every new Freight (`project-config.yaml`).
- `production` and `levelbuilder` request Freight that has been verified in
  `test` and promote only when a person creates a Promotion.
- Each Freight carries the image digest and the index annotation
  `org.opencontainers.image.revision`, the `staging` commit the image was built
  from (stamped by `.github/workflows/cdo-rails-image.yml` in code-dot-org).

## The production gate

The production Stage's first promotion step, `legacy-ancestry`, asks the GitHub
compare API whether the Freight's commit is contained in the legacy `production`
branch. The image carries no migrations and only the legacy EC2 deploy migrates
the production database, so an image newer than legacy would run ahead of the
schema. The step runs before anything is cloned or written and fails closed: no
annotation, an unknown commit, a commit ahead of `production`, or an unreachable
GitHub all block the promotion.

Runbook, with when to promote, failure messages, rollback and the accepted gaps:
[`docs/production-promotion.md`](../../../../docs/production-promotion.md).

Staging and test have no gate: their namespaces share databases with legacy
staging and test and already run ahead of them.
