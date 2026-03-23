# gitops repo for codeai-k8s

To change something in ArgoCD for codeai-k8s, edit this repo
and merge to `main`.

Time for ArgoCD to notice changes to either repo:
 - **avg 2m 30s**, max 5 minutes

Time for ArgoCD to deploy depends on what it has to restart
to make the change.

TODO: time codeai deployments, including restart

## Directory Structure

```text
k8s-gitops/
  apps/
    app-of-apps/
      applicationset.yaml         # points argocd at apps/*/application.yaml and applicationset.yaml

    $app_name/
      application.yaml            # argocd will automatically find this application.yaml
      repos.yaml                  # configure application.yaml to load $app_name/*

    codeai/
      applicationset.yaml         # generate Argo apps from deployments/*/deployment.yaml on main

      deployments/
        levelbuilder/             # codeai deployment levelbuilder
          deployment.yaml         # envType=levelbuilder, branch=levelbuilder
          deploy/                 # rendered output on stage/levelbuilder branch
          values.yaml             # legacy Helm-era values kept for compatibility during migration
        ...

      envTypes/
        levelbuilder.values.yaml  # base values.yaml for all envType=levelbuilder
        ...

      kargo/
        templates/
          deploy/
            kustomization.yaml    # copied into temp render workdirs before kustomize-build

    kargo/
      application.yaml            # argocd app for kargo itself
      values.yaml                 # helm values for kargo install

    kargo-project-codeai/
      application.yaml            # argocd app for kargo project codeai
      project.yaml                # kargo project for codeai
      project-config.yaml         # kargo projectconfig for codeai
      warehouse.yaml              # git build-lock warehouse for codeai
      stages/
        levelbuilder.yaml         # kargo stage for codeai deployment levelbuilder
        review-infra-changes.yaml # opens a PR with rendered production manifests
        ...

  warehouses/
    codeai/
      builds/                     # thin build-lock Freight records
      legacy-gitflow/             # merge facts used for downstream promotion gates
```

## Bootstrap Cluster

kubectl apply -f apps/app-of-apps/applicationset.yaml
