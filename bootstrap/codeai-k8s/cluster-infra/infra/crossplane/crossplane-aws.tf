#============================================================
# Crossplane AWS IRSA role
#============================================================
#
# This creates one shared IAM role for the Crossplane AWS provider runtimes we
# expect to install first. Keep the trust strict by naming exact service
# accounts. Keep the policy bounded to the AWS services Crossplane should own.

# This policy now derives many names and fences from var.cluster_name. Refuse
# empty input here so the policy never degenerates into wildcard-shaped names.
check "cluster_name_not_empty" {
  assert {
    condition     = trimspace(var.cluster_name) != ""
    error_message = "var.cluster_name must be non-empty."
  }
}

locals {
  crossplane_aws = {
    namespace            = "crossplane-system"
    service_account_name = "crossplane-aws"
    role_name            = "${var.cluster_name}-crossplane-aws"
    oidc_host            = replace(var.oidc_provider_arn, "/^(.*provider/)/", "")
    cluster_subdomain    = var.cluster_subdomain
    parent_zone_arn      = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.parent_domain.zone_id}"
    hosted_zone_arn_wildcard = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/*"
    iam_role_names = [
      "${var.cluster_name}-external-dns",
      "${var.cluster_name}-eso-*",
    ]
    iam_policy_names = [
      "${var.cluster_name}-external-dns",
    ]
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_route53_zone" "parent_domain" {
  name         = var.parent_domain
  private_zone = false
}

data "aws_iam_policy_document" "crossplane_aws_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.crossplane_aws.oidc_host}:sub"
      values = ["system:serviceaccount:${local.crossplane_aws.namespace}:${local.crossplane_aws.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.crossplane_aws.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "crossplane_aws" {
  # ACM create-time fencing is by requested domain names plus request tag.
  # Existing-certificate writes are fenced by resource tag using code.ai/cluster.
  statement {
    effect = "Allow"
    actions = [
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
    ]
    resources = ["*"]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "acm:DomainNames"
      values = [
        # IAM '*' is not DNS-label-aware. This also allows deeper names under
        # the suffix, e.g. foo.bar.k8s.code.org.
        "*.${local.crossplane_aws.cluster_subdomain}",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListTagsForCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:RenewCertificate",
      "acm:UpdateCertificateOptions",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:acm:*:${data.aws_caller_identity.current.account_id}:certificate/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  # Route53 has weak IAM fences here. Hosted zone create and reusable
  # delegation set create/delete stay broad; record changes are fenced below.
  statement {
    effect = "Allow"
    actions = [
      "route53:CreateHostedZone",
      "route53:GetChange",
      "route53:GetReusableDelegationSet",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",

      # Sadly, couldn't find a way to fence these in AWS atm
      "route53:CreateReusableDelegationSet",
      "route53:DeleteReusableDelegationSet",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeTagsForResource",
      "route53:DeleteHostedZone",
      "route53:GetDNSSEC",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = [local.crossplane_aws.hosted_zone_arn_wildcard]
  }

  # TODO: if we want to allocate domains outside *.k8s.code.org, lift this
  # restriction. For now, keep Crossplane in a Route53 playpen while we
  # experiment.
  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
    ]
    resources = [local.crossplane_aws.parent_zone_arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["NS"]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [local.crossplane_aws.cluster_subdomain]
    }
  }

  # TODO: if we want to allocate domains outside *.k8s.code.org, lift this
  # restriction. For now, keep Crossplane in a Route53 playpen while we
  # experiment.
  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
    ]
    resources = [local.crossplane_aws.hosted_zone_arn_wildcard]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        local.crossplane_aws.cluster_subdomain,
        "*.${local.crossplane_aws.cluster_subdomain}",
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListDistributions",
      "cloudfront:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # CloudFront distribution IDs are assigned by AWS. Fence creates by request
  # tag and existing-resource writes by resource tag using code.ai/cluster.
  statement {
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudfront:DeleteDistribution",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:UpdateDistribution",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  # IAM is fenced to the concrete names we expect Crossplane to manage in this
  # cluster. Keep the allow-list explicit so the shared provider role is not a
  # generic IAM admin principal.
  statement {
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateRole",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:PutRolePolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:TagRole",
      "iam:UntagPolicy",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = concat(
      [
        for role_name in local.crossplane_aws.iam_role_names :
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${role_name}"
      ],
      [
        for policy_name in local.crossplane_aws.iam_policy_names :
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${policy_name}"
      ]
    )
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [
      for role_name in local.crossplane_aws.iam_role_names :
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${role_name}"
    ]

    # Attach/detach is authorized on the role ARN; fence the managed policy side
    # separately so these roles cannot bind arbitrary account policies.
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        for policy_name in local.crossplane_aws.iam_policy_names :
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${policy_name}"
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticache:Describe*",
      "elasticache:List*",
    ]
    resources = ["*"]
  }

  # ElastiCache create paths are fenced by request tag. The create-time tag
  # helper is limited to ${cluster_name}-* names so it cannot retag arbitrary
  # existing caches.
  statement {
    effect = "Allow"
    actions = [
      "elasticache:CreateCacheCluster",
      "elasticache:CreateCacheSubnetGroup",
      "elasticache:CreateReplicationGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticache:AddTagsToResource",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:elasticache:*:${data.aws_caller_identity.current.account_id}:cluster:${var.cluster_name}-*",
      "arn:${data.aws_partition.current.partition}:elasticache:*:${data.aws_caller_identity.current.account_id}:replicationgroup:${var.cluster_name}-*",
      "arn:${data.aws_partition.current.partition}:elasticache:*:${data.aws_caller_identity.current.account_id}:subnetgroup:${var.cluster_name}-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticache:DeleteCacheCluster",
      "elasticache:DeleteCacheSubnetGroup",
      "elasticache:DeleteReplicationGroup",
      "elasticache:ModifyCacheCluster",
      "elasticache:ModifyReplicationGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "rds:Describe*",
      "rds:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "rds:AddTagsToResource",
      "rds:CreateDBCluster",
      "rds:CreateDBClusterParameterGroup",
      "rds:CreateDBInstance",
      "rds:CreateDBSubnetGroup",
      "rds:DeleteDBCluster",
      "rds:DeleteDBClusterParameterGroup",
      "rds:DeleteDBInstance",
      "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBCluster",
      "rds:ModifyDBClusterParameterGroup",
      "rds:ModifyDBInstance",
      "rds:ModifyDBSubnetGroup",
      "rds:RemoveTagsFromResource",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:rds:*:${data.aws_caller_identity.current.account_id}:*:${var.cluster_name}-*",
    ]
  }

  # Secrets Manager is intentionally absolute for now. Tighten this once secret
  # naming is fixed. A reasonable future fence is:
  # arn:${partition}:secretsmanager:${region}:${account}:secret:${cluster_name}/crossplane/*
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:BatchGetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecrets",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = ["*"]
  }

  # S3 is fenced to buckets named ${cluster_name}-* at the ARN layer. Create is
  # also fenced by request tag. Steady-state bucket and object access is fenced
  # by the bucket's code.ai/cluster tag.
  statement {
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.cluster_name}-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.cluster_name}-*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:DeleteBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListBucketVersions",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.cluster_name}-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:DeleteObjectTagging",
      "s3:DeleteObjectVersion",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.cluster_name}-*/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:BucketTag/code.ai/cluster"
      values   = [var.cluster_name]
    }
  }
}

resource "aws_iam_role" "crossplane_aws" {
  name               = local.crossplane_aws.role_name
  assume_role_policy = data.aws_iam_policy_document.crossplane_aws_trust.json
}

resource "aws_iam_role_policy" "crossplane_aws" {
  name   = "aws-service-access"
  role   = aws_iam_role.crossplane_aws.id
  policy = data.aws_iam_policy_document.crossplane_aws.json
}
