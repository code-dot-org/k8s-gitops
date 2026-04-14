# OpenTofu Kubernetes Cluster: `codeai-k8s` 

This directory contains three OpenTofu root modules. Apply them in order:

1. **[cluster/](cluster/README.md)** — EKS Auto Mode cluster + VPC networking
2. **[cluster-infra/](cluster-infra/README.md)** — AWS-side resources and shared bootstrap config
3. **[cluster-infra-argocd/](cluster-infra-argocd/README.md)** — Kubernetes-side resources and Argo CD bootstrap

## Org-wide bootstrap: only needed once

Only required if you're starting on a fresh account, not needed for each cluster.

1. **[../codeai-k8s-dex/](../codeai-k8s-dex/README.md)** - shared between clusters, only need to apply if this is the first cluster in the org

## Smoke testing a cluster is working once its up

- once a cluster is up, you can use these smoke tests to test it:
  `./cluster-smoke-tests/test-external-secrets.sh`
  `./cluster-smoke-tests/test-ingress.sh`
  `./cluster-smoke-tests/test-nlb.sh`
