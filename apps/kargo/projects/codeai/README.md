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
- Each Freight has the image digest and the index annotation
  `org.opencontainers.image.revision`, the `staging` commit the image was built
  from (stamped by `.github/workflows/cdo-rails-image.yml` in code-dot-org).

## The production gate

The production Stage's first promotion step, `legacy-ancestry`, blocks any
Freight whose image commit is not already in the legacy `production` branch.
Staging and test have no gate. Why the gate exists, when to promote, failure
messages, rollback and the accepted gaps:
[`docs/production-promotion.md`](../../../../docs/production-promotion.md).
