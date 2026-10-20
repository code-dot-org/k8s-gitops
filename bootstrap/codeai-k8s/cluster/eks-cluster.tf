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

  #============================================================
  # Control-plane logs -> CloudWatch /aws/eks/codeai-k8s/cluster
  #============================================================
  #
  # All five log types are on. `audit` is the only record of who did what
  # through the API server.
  #
  # History: audit was switched off on 2026-04-15 because the log group was
  # ingesting 80-120 GB/day (about $40-60/day). That was not cluster
  # setup/teardown churn. It began on 2026-04-06, the day Crossplane was
  # installed, and comes from the five AWS providers fighting over the shared
  # `crossplane-aws` ServiceAccount at roughly 500 API requests/s.
  # With that loop fixed the whole log group should run at single-digit GB/day.
  # Check daily ingestion with:
  #
  #   aws cloudwatch get-metric-statistics --region us-east-1 \
  #     --namespace AWS/Logs --metric-name IncomingBytes \
  #     --dimensions Name=LogGroupName,Value=/aws/eks/codeai-k8s/cluster \
  #     --start-time "$(date -u -v-7d +%Y-%m-%dT00:00:00Z)" \
  #     --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  #     --period 86400 --statistics Sum --output json
  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # The module owns the log group. Pin retention here so it does not drift
  # with the module default (also 90 today; the live group is already 90).
  cloudwatch_log_group_retention_in_days = 90

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

#============================================================
# Kubelet scrape access across node security groups
#============================================================
#
# The monitoring collector (Alloy) runs on Auto Mode general-purpose nodes,
# which use the EKS primary security group. Frontend NodeClass nodes use the
# module's node security group, which only admits 10250 from itself and the
# control plane. Without this rule, kubelet/cAdvisor scrapes of frontend
# nodes time out. Defined outside the module because referencing
# module.eks.cluster_primary_security_group_id inside its inputs is a cycle.
resource "aws_vpc_security_group_ingress_rule" "node_kubelet_from_cluster_primary" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "Kubelet metrics scraping from cluster-primary-SG nodes"
}
