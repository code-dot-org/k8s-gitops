# codeai-k8s cluster bootstrap

This directory holds tofu modules that bootstrap an EKS codeai-k8s cluster which then looks to `../apps/`
in this repo as its source of truth. If you're setting up a cluster from scratch, start by reading 
[./codeai-k8s/README.md](./codeai-k8s/README.md).

## OpenTofu norms for our repo

## Non-secrets: commit to terraform.tfvars

- Commit non-secrets into the repo as terraform.tfvars, or, if we need env specific naming for something $env.tfvars e.g. staging.tfvars

## Secrets: use module/bootstrapped-aws-secret

- To make secret upload/download to AWS Secrets Manager easy+consistent **use module/bootstrapped-aws-secret**
  - See: `bootstrap/modules/bootstrapped-aws-secret/README.md`
  - For an example using the module, see: `bootstrap/codeai-k8s/cluster-infra/infra/dex/dex-google-client-secret.tf`
- Prefix secrets in AWS Secrets Manager with `k8s/tofu/${clustername}/` for per-cluster secrets, or `k8s/tofu/` for all-cluster secrets.
