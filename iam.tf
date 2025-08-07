# IAM Roles and Policies for EKS Cluster

# =============================================================================
# PRE-EKS IAM ROLES (can be created before EKS cluster)
# =============================================================================

# Karpenter Node Role
resource "aws_iam_role" "karpenter_node_role" {
  count = var.enable_iam_roles ? 1 : 0
  
  name = "KarpenterNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "KarpenterNodeRole-${var.cluster_name}"
    Environment = var.cluster_name
    Purpose     = "Karpenter Node Role"
  }
}

# Attach AWS managed policies to Karpenter Node Role using variables
resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = var.enable_iam_roles ? toset(var.karpenter_node_role_policies) : toset([])
  
  role       = aws_iam_role.karpenter_node_role[0].name
  policy_arn = each.value

  depends_on = [aws_iam_role.karpenter_node_role]
}

# Prometheus Role
resource "aws_iam_role" "prometheus_role" {
  count = var.enable_iam_roles ? 1 : 0
  
  name = "prometheus-role-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "prometheus-role-${var.cluster_name}"
    Environment = var.cluster_name
    Purpose     = "Prometheus Monitoring Role"
  }
}

# Attach AWS managed policies to Prometheus Role using variables
resource "aws_iam_role_policy_attachment" "prometheus_policies" {
  for_each = var.enable_iam_roles ? toset(var.prometheus_role_policies) : toset([])
  
  role       = aws_iam_role.prometheus_role[0].name
  policy_arn = each.value

  depends_on = [aws_iam_role.prometheus_role]
}

# =============================================================================
# POST-EKS IAM ROLES (require EKS cluster and OIDC provider)
# =============================================================================

# Karpenter Controller Role (depends on EKS OIDC provider)
resource "aws_iam_role" "karpenter_controller_role" {
  count = var.enable_iam_roles ? 1 : 0
  
  name = "KarpenterControllerRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
            "${replace(module.eks.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "KarpenterControllerRole-${var.cluster_name}"
    Environment = var.cluster_name
    Purpose     = "Karpenter Controller Role"
  }

  depends_on = [module.eks]
}

# Karpenter Controller Policy
resource "aws_iam_policy" "karpenter_controller_policy" {
  count = var.enable_iam_roles ? 1 : 0
  
  name = "KarpenterControllerPolicy-${var.cluster_name}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Action = [
          "ssm:GetParameter",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:DescribeSpotPriceHistory",
          "ec2:TerminateInstances",
          "pricing:GetProducts",
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ]
        Effect = "Allow"
        Resource = "*"
        Sid = "Karpenter"
      },
      {
        Action = "ec2:TerminateInstances"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/karpenter.sh/provisioner-name" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
        Effect = "Allow"
        Resource = "*"
        Sid = "ConditionalEC2Termination"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node_role[0].arn
        Sid = "PassNodeIAMRole"
      },
      {
        Effect = "Allow"
        Action = "eks:DescribeCluster"
        Resource = "arn:aws:eks:eu-central-1:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
        Sid = "EKSClusterEndpointLookup"
      }
    ], var.karpenter_controller_policy_statements)
  })

  depends_on = [module.eks]
}

# Attach Karpenter Controller Policy to the role
resource "aws_iam_role_policy_attachment" "karpenter_controller_policy_attachment" {
  count = var.enable_iam_roles ? 1 : 0
  
  role       = aws_iam_role.karpenter_controller_role[0].name
  policy_arn = aws_iam_policy.karpenter_controller_policy[0].arn

  depends_on = [aws_iam_role.karpenter_controller_role, aws_iam_policy.karpenter_controller_policy]
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter Node Role"
  value       = var.enable_iam_roles ? aws_iam_role.karpenter_node_role[0].arn : null
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter Controller Role"
  value       = var.enable_iam_roles ? aws_iam_role.karpenter_controller_role[0].arn : null
}

output "prometheus_role_arn" {
  description = "ARN of the Prometheus Role"
  value       = var.enable_iam_roles ? aws_iam_role.prometheus_role[0].arn : null
} 