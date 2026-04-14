# Only locals used in multiple .tf files should live here.
locals {
  cluster_outs = data.terraform_remote_state.cluster.outputs

  cluster_name      = local.cluster_outs.cluster_name
  cluster_region    = local.cluster_outs.cluster_region
  cluster_subdomain = local.cluster_outs.cluster_subdomain

  oidc_provider_arn       = local.cluster_outs.oidc_provider_arn
  cluster_oidc_issuer_url = local.cluster_outs.cluster_oidc_issuer_url

  single_namespace_environment_types = toset(local.cluster_outs.single_namespace_environment_types)
  node_iam_role_name               = try(local.cluster_outs.node_iam_role_name, "${local.cluster_name}-eks-auto")
  node_security_group_id           = try(local.cluster_outs.node_security_group_id, "")
  private_subnet_ids               = try(local.cluster_outs.private_subnet_ids, sort(data.aws_subnets.private.ids))
}
