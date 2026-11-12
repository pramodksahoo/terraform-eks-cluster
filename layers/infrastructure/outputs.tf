###############################################################################
# Networking
###############################################################################

output "vpc_id" {
  description = "VPC the cluster runs in, whether created here or supplied."
  value       = local.network.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = local.network.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnets carrying the worker nodes."
  value       = local.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets used for internet-facing load balancers."
  value       = local.network.public_subnet_ids
}

output "control_plane_subnet_ids" {
  description = "Subnets holding the EKS control-plane ENIs."
  value       = local.network.control_plane_subnet_ids
}

output "networking_created_here" {
  description = "Whether this stack owns the networking resources. False means they belong to another team and must not be modified from here."
  value       = var.create_networking
}

output "nat_public_ips" {
  description = "Public IPs of the NAT Gateways. These are the cluster's egress addresses — give them to anyone who needs to allow-list outbound traffic from the cluster."
  value       = try(module.networking[0].nat_public_ips, [])
}

###############################################################################
# Cluster
###############################################################################

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Cluster CA bundle, base64 encoded."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Cluster security group attached to the control-plane ENIs."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Shared node security group."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for the cluster."
  value       = module.eks.oidc_provider_arn
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster."
  value       = module.eks.kubeconfig_command
}

###############################################################################
# Hand-off to the bootstrap layer
###############################################################################

output "cluster_connection" {
  description = "Everything the kubernetes, helm and kubectl providers need. Read from the bootstrap layer through terraform_remote_state."
  value       = module.eks.cluster_connection
}

output "addons_input" {
  description = "Pre-assembled inputs for the eks-gateway and eks-addons modules."
  value = merge(module.eks.addons_input, {
    vpc_id = local.network.vpc_id
  })
}

output "karpenter_node_iam_role_name" {
  description = "IAM role Karpenter-provisioned nodes assume. Referenced by the default EC2NodeClass in the bootstrap layer."
  value       = module.eks.karpenter_node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS queue carrying spot interruption notices."
  value       = module.eks.karpenter_queue_name
}

output "pod_identity_role_arns" {
  description = "IAM role ARNs associated with each platform add-on's service account."
  value       = module.eks.pod_identity_role_arns
}

###############################################################################
# Operator guidance
###############################################################################

output "tag_requirements_for_existing_subnets" {
  description = <<-EOT
    Tags that must already be present on subnets supplied through the existing_*
    variables when create_networking is false.

    These are not cosmetic. The AWS Load Balancer Controller and Karpenter discover
    subnets exclusively by tag; without them, load balancer provisioning and node
    launches fail with errors that give no hint about the real cause.
  EOT
  value = var.create_networking ? null : {
    all_subnets = {
      "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    }
    public_subnets = {
      "kubernetes.io/role/elb" = "1"
    }
    private_subnets = {
      "kubernetes.io/role/internal-elb" = "1"
      "karpenter.sh/discovery"          = local.cluster_name
    }
  }
}
