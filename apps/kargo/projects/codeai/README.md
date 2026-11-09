# Kargo project: codeai

Everything in this directory except `application.yaml` is applied by the Argo
Application `kargo-project-codeai` (a recursive directory source with
`exclude: application.yaml`). Argo's directory source reads only `.yaml`, `.yml`
and `.json` files, so this README is not a manifest.

| file | what it is |
|---|---|
| `application.yaml` | the Argo Application that applies the rest of this directory into the `kargo` namespace |
| `project.yaml`, `namespace.yaml` | the Kargo Project and its namespace, `kargo-project-codeai` |
| `project-config.yaml` | promotion policies: which Stages auto-promote |
| `cluster-config.yaml` | the GitHub webhook receiver that refreshes the Warehouse on push and package events |
| `warehouse.yaml` | follows `ghcr.io/code-dot-org/cdo-rails:latest` by digest and creates one Freight per new digest |
| `stages/*.yaml` | one Stage per codeai deployment; a promotion commits a digest into `apps/codeai/deployments/<name>/values.yaml` and refreshes the `codeai-<name>` Argo Application |

## How Freight flows

- `staging` and `test` auto-promote every new Freight (`project-config.yaml`).
- `production` and `levelbuilder` request Freight that has been verified in
  `test` and promote only when a person creates a Promotion.
- Each Freight carries the image digest and the index annotation
  `org.opencontainers.image.revision`: the `staging` commit the image was built
  from. CI stamps it when it builds the index with regctl
  (`.github/workflows/cdo-rails-image.yml` in code-dot-org).

## The production gate

The production Stage's first promotion step, `legacy-ancestry`, asks the GitHub
compare API whether the Freight's commit is contained in the legacy `production`
branch. The `cdo-rails` image carries no migrations. Only the legacy EC2 deploy
migrates the production database, so an image built from a commit newer than
what legacy runs would be ahead of the schema. The step runs before anything is
cloned or written and fails closed: no annotation, an unknown commit, a commit
ahead of `production`, or an unreachable GitHub all block the promotion.

When to promote, what each failure message means, how to roll back and what the
gate does not cover: [`docs/production-promotion.md`](../../../../docs/production-promotion.md).

Staging and test carry no gate. Their k8s namespaces share databases with legacy
staging and test and already run ahead of them.
