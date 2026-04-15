#============================================================
# EKS Kubernetes Cluster: codeai-k8s
#============================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  kms_key_administrators = var.cluster_admin_role_arns

  # See: ./eks-cluster-networking.tf
  vpc_id = local.vpc_id
  subnet_ids = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id,
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
  ]

  endpoint_public_access       = true
  node_iam_role_use_name_prefix = false
  node_security_group_use_name_prefix = false

  enabled_log_types = [
    "api",
    "authenticator",
    # TODO: disabled k8s audit for cost reasons while Seth tears down and sets up
    # clusters all day. This was costing about $40/day in CloudWatch usage. I think
    # a setup/teardown cycle of the cluster costs about $5 in cloudwatch logs. Eep.
    #
    # Re-evaluate re-enabling once the cluster is in a stable state; if it is still
    # flooding the logs with spam, keep this off until the churn is fixed.
    #
    # Can check daily usage with:
    # aws cloudwatch get-metric-statistics --region us-east-1 --namespace AWS/Logs --metric-name IncomingBytes --dimensions Name=LogGroupName,Value=/aws/eks/codeai-k8s/cluster --start-time 2026-04-01T00:00:00Z --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 86400 --statistics Sum --output json
    #
    # Should try to turn this on anytime after May 15, 2026 to get k8s audit logs back:
    #
    # "audit",
  ]

  #=============================================================
  # Map AWS IAM roles to cluster permissions (affects kubectl)
  #=============================================================
  access_entries = merge(
    { for arn in var.cluster_readonly_role_arns : arn => {
      principal_arn = arn
      policy_associations = {
        cluster_view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    } },
    { for arn in var.cluster_admin_role_arns : arn => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    } }
  )

  #============================================================
  # EKS Auto Mode: keep the common case boring and let AWS own it.
  #============================================================
  compute_config = {
    enabled    = true
    node_pools = ["system", "general-purpose"]
  }
}
