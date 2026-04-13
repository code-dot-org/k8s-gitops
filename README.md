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
      application.yaml            # top-level Argo application discovered by app-of-apps
      applicationset.yaml         # or a top-level Argo applicationset wrapped by app-of-apps

    infra/                        # infrastructure / cluster apps live here
      argocd/                     # e.g. argocd itself is defined right here
        application.yaml
        chart/
          templates/
            repos.yaml            # Argo repository Secret objects now live here
      ...

    codeai/
      applicationset.yaml         # define argocd apps for codeai deployments: deployments/*/deployment.yaml

      deployments/
        levelbuilder/             # codeai deployment levelbuilder
          deployment.yaml         # envType=levelbuilder, branch=levelbuilder
          values.yaml             # values.yaml for this deployment: dashboard_workers=27, RAILS_ENV=levelbuilder, etc
        ...

      envTypes/
        levelbuilder.values.yaml  # base values.yaml for all envType=levelbuilder
        ...

    kargo/
      application.yaml            # argocd app for kargo itself
      values.yaml                 # helm values for kargo install
      projects/
        codeai/
          application.yaml        # child argocd app for the codeai kargo project
          namespace.yaml          # namespace for namespaced kargo project resources
          project.yaml            # kargo project for codeai
          project-config.yaml     # kargo projectconfig for codeai
          warehouse.yaml          # kargo warehouse for codeai
          stages/
            levelbuilder.yaml     # kargo stage for codeai deployment levelbuilder
            ...

  bootstrap/                      # tofu to bootstrap a cluster that points at this repoa
```

## Bootstrap Cluster

If you have an existing ArgoCD instance: `kubectl apply -f apps/app-of-apps/bootstrap.yaml`

For creating from scratch, creating an EKS cluster, bootstrapping argocd etc,
see: [./bootstrap/README.md](./bootstrap/README.md).