###############################################################################
# EKS module - complete example
#
# Networking and cluster together. This is the shape layers/infrastructure uses
# and the quickest way to see how the two modules fit.
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

locals {
  cluster_name = "example-complete"
}

module "networking" {
  source = "../../../networking"

  name     = local.cluster_name
  vpc_cidr = "10.2.0.0/16"
  az_count = 3

  create_intra_subnets = true
  enable_vpc_endpoints = true

  eks_cluster_names         = [local.cluster_name]
  karpenter_discovery_value = local.cluster_name
}

module "eks" {
  source = "../../"

  cluster_name       = local.cluster_name
  kubernetes_version = "1.37"

  vpc_id     = module.networking.vpc_id
  subnet_ids = module.networking.private_subnet_ids

  # Control-plane ENIs in the intra tier: no internet route, so they are
  # unaffected by a NAT Gateway failure and cannot be used as an egress path.
  control_plane_subnet_ids = module.networking.intra_subnet_ids
  public_subnet_ids        = module.networking.public_subnet_ids

  # Private endpoint only. Reach the API from inside the VPC, a VPN or a
  # Direct Connect link.
  endpoint_private_access = true
  endpoint_public_access  = false

  # Access entries replace the aws-auth ConfigMap, which was removed in v21 of
  # the upstream EKS module.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Fixed baseline capacity: a self-managed ASG on Bottlerocket, pinned to an
  # exact AMI version. It is tainted so only tolerating workloads land on it;
  # everything else is provisioned by Karpenter. Nothing autoscales this group.
  create_system_node_group         = true
  system_node_group_instance_types = ["m7i.large", "m7a.large", "m6i.large"]
  system_node_group_min_size       = 2
  system_node_group_max_size       = 4
  system_node_group_desired_size   = 2

  ami_type             = "BOTTLEROCKET_x86_64"
  bottlerocket_version = "1.68.1"

  # Creates the Karpenter controller role, node role, instance profile and
  # interruption queue. The controller workload itself is installed by
  # modules/eks-addons.
  enable_karpenter = true

  enable_pod_identity_roles = true

  tags = {
    Environment = "example"
  }
}

output "cluster_connection" {
  description = "Feed into the kubernetes, helm and kubectl providers."
  value       = module.eks.cluster_connection
}

output "addons_input" {
  description = "Feed into modules/eks-gateway and modules/eks-addons."
  value       = module.eks.addons_input
}

output "kubeconfig_command" {
  value = module.eks.kubeconfig_command
}
