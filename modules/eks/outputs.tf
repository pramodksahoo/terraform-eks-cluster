###############################################################################
# Cluster
###############################################################################

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster. Required to configure the kubernetes, helm and kubectl providers."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_platform_version" {
  description = "EKS platform version of the cluster."
  value       = module.eks.cluster_platform_version
}

output "cluster_status" {
  description = "Status of the EKS cluster."
  value       = module.eks.cluster_status
}

###############################################################################
# Identity
###############################################################################

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, used by IRSA."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider, or null when enable_irsa is false."
  value       = try(module.eks.oidc_provider_arn, null)
}

output "cluster_iam_role_arn" {
  description = "ARN of the IAM role assumed by the EKS control plane."
  value       = module.eks.cluster_iam_role_arn
}

output "node_iam_role_arn" {
  description = "ARN of the IAM role attached to node instances."
  value       = module.eks.node_iam_role_arn
}

output "node_iam_role_name" {
  description = "Name of the IAM role attached to node instances."
  value       = module.eks.node_iam_role_name
}

###############################################################################
# Security groups
###############################################################################

output "cluster_security_group_id" {
  description = "ID of the EKS-managed cluster security group attached to the control-plane ENIs."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "ID of the cluster primary security group created by EKS itself."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "ID of the shared node security group. Carries the karpenter.sh/discovery tag."
  value       = module.eks.node_security_group_id
}

###############################################################################
# Node groups
###############################################################################

output "self_managed_node_groups" {
  description = "Attributes of the self-managed node groups (ASGs), keyed by name."
  value       = module.eks.self_managed_node_groups
}

output "self_managed_node_group_names" {
  description = "Names of the self-managed node groups."
  value       = keys(module.eks.self_managed_node_groups)
}

output "system_node_group_ami_id" {
  description = "AMI ID the baseline system ASG is pinned to. Changes here replace every baseline node."
  value       = local.resolved_ami_id
}

output "bottlerocket_ssm_parameter" {
  description = "SSM public parameter the baseline AMI was resolved from. Useful for confirming the pin."
  value       = local.is_bottlerocket ? local.bottlerocket_ssm_parameter : null
}

###############################################################################
# Encryption
###############################################################################

output "secrets_kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes Secrets, or null when encryption is disabled."
  value       = local.secrets_kms_key_arn
}

###############################################################################
# Karpenter
###############################################################################

output "karpenter_node_iam_role_arn" {
  description = "ARN of the IAM role Karpenter-provisioned nodes assume."
  value       = try(module.karpenter[0].node_iam_role_arn, null)
}

output "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role. Reference this in the EC2NodeClass `role` field."
  value       = try(module.karpenter[0].node_iam_role_name, null)
}

output "karpenter_controller_iam_role_arn" {
  description = "ARN of the Karpenter controller IAM role."
  value       = try(module.karpenter[0].iam_role_arn, null)
}

output "karpenter_queue_name" {
  description = "Name of the SQS queue receiving spot interruption notices. Pass to the Karpenter Helm chart as `settings.interruptionQueue`."
  value       = try(module.karpenter[0].queue_name, null)
}

output "karpenter_service_account" {
  description = "Service account name the Karpenter controller must use to pick up its Pod Identity association."
  value       = var.enable_karpenter ? var.karpenter_service_account : null
}

output "karpenter_namespace" {
  description = "Namespace the Karpenter controller must run in."
  value       = var.enable_karpenter ? var.karpenter_namespace : null
}

###############################################################################
# Pod Identity role ARNs
###############################################################################

output "pod_identity_role_arns" {
  description = "Map of platform add-on name to the IAM role ARN associated with its service account."
  value = {
    aws_load_balancer_controller = try(module.pod_identity_aws_lb_controller[0].iam_role_arn, null)
    cert_manager                 = try(module.pod_identity_cert_manager[0].iam_role_arn, null)
    external_dns                 = try(module.pod_identity_external_dns[0].iam_role_arn, null)
    ebs_csi_driver               = try(module.pod_identity_ebs_csi[0].iam_role_arn, null)
    efs_csi_driver               = try(module.pod_identity_efs_csi[0].iam_role_arn, null)
  }
}

###############################################################################
# Convenience bundles
###############################################################################

output "kubeconfig_command" {
  description = "AWS CLI command that writes a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

output "cluster_connection" {
  description = "Everything the kubernetes, helm and kubectl providers need in a single object. Pass straight into the bootstrap layer."
  value = {
    cluster_name                       = module.eks.cluster_name
    cluster_endpoint                   = module.eks.cluster_endpoint
    cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
    region                             = local.region
  }
}

output "addons_input" {
  description = "Pre-assembled inputs for the eks-gateway and eks-addons modules, so the bootstrap layer does not have to rewire every value."
  value = {
    cluster_name            = module.eks.cluster_name
    cluster_endpoint        = module.eks.cluster_endpoint
    oidc_provider_arn       = try(module.eks.oidc_provider_arn, null)
    vpc_id                  = var.vpc_id
    region                  = local.region
    karpenter_queue_name    = try(module.karpenter[0].queue_name, null)
    karpenter_node_role_arn = try(module.karpenter[0].node_iam_role_arn, null)
    karpenter_node_role     = try(module.karpenter[0].node_iam_role_name, null)
    node_security_group_id  = module.eks.node_security_group_id
  }
}
