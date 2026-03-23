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
      applicationset.yaml         # define argocd apps for codeai deployments: deployments/*/deployment.yaml

      deployments/
        levelbuilder/             # codeai deployment levelbuilder
          deployment.yaml         # deployment metadata: envType=levelbuilder, namespace=levelbuilder
          deploy/
            kustomization.yaml    # machine-owned deploy wrapper pinned to a code-dot-org commit
        ...

      envTypes/
        levelbuilder/
          kustomization.yaml      # envType component consumed by deployment wrappers
        ...

    kargo/
      application.yaml            # argocd app for kargo itself
      values.yaml                 # helm values for kargo install

    kargo-project-codeai/
      application.yaml            # argocd app for kargo project codeai
      project.yaml                # kargo project for codeai
      project-config.yaml         # kargo projectconfig for codeai
      warehouse.yaml              # kargo warehouse watching warehouses/codeai/builds
      stages/
        levelbuilder.yaml         # kargo stage for codeai deployment levelbuilder
        ...
```

## Bootstrap Cluster

kubectl apply -f apps/app-of-apps/applicationset.yaml
