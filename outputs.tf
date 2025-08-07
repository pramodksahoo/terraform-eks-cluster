
# # EKS

output "cluster_endpoint" {
  description = "EKS control plane endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = var.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "eks_cluster_iam_role_arn" {
  description = "IAM role ARN used by EKS cluster control plane"
  value       = module.eks.cluster_iam_role_arn
}

output "eks_cluster_iam_role_name" {
  description = "IAM role name used by EKS cluster control plane"
  value       = element(split("/", module.eks.cluster_iam_role_arn), 1)
}

output "eks_node_iam_role_arn" {
  description = "IAM role ARN used by EKS worker nodes"
  value       = module.eks.node_iam_role_arn
}

####### Node Groups #######

output "node_group_iam_role_arns" {
  description = "The ARNs of the IAM roles created for the EKS node groups"
  value = {
    dev-cluster-primary = try(module.eks.eks_managed_node_groups["dev-cluster-primary"].iam_role_arn, "Node group 'dev-cluster-primary' is not enabled")
    dev-cluster-upgrade = try(module.eks.eks_managed_node_groups["dev-cluster-upgrade"].iam_role_arn, "Node group 'dev-cluster-upgrade' is not enabled")
  }
}

output "node_group_iam_role_names" {
  description = "The names of the IAM roles created for the EKS node groups"
  value = {
    dev-cluster-primary = try(module.eks.eks_managed_node_groups["dev-cluster-primary"].iam_role_name, "Node group 'dev-cluster-primary' is not enabled")
    dev-cluster-upgrade = try(module.eks.eks_managed_node_groups["dev-cluster-upgrade"].iam_role_name, "Node group 'dev-cluster-upgrade' is not enabled")
  }
}
