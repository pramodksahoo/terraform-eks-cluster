###############################################################################
# EKS module - existing VPC example
#
# Deploy a cluster into networking another team owns. No networking resource is
# created and nothing in the supplied VPC is modified.
#
# PREREQUISITES
#
# The subnets must already carry the discovery tags below. The AWS Load Balancer
# Controller and Karpenter find subnets exclusively by tag; without them,
# load balancer provisioning and node launches fail with errors that give no
# hint about the real cause.
#
#   All subnets:      kubernetes.io/cluster/<cluster-name> = shared
#   Public subnets:   kubernetes.io/role/elb               = 1
#   Private subnets:  kubernetes.io/role/internal-elb      = 1
#                     karpenter.sh/discovery               = <cluster-name>
#
# The private subnets also need outbound internet access, through a NAT Gateway
# or a complete set of VPC endpoints. Nodes cannot join the cluster without it.
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

variable "vpc_id" {
  description = "Existing VPC to deploy into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Existing private subnets for the worker nodes. At least two, in different AZs."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Existing public subnets for internet-facing load balancers. Omit for a cluster with no public ingress."
  type        = list(string)
  default     = []
}

module "eks" {
  source = "../../"

  cluster_name       = "example-existing-vpc"
  kubernetes_version = "1.37"

  vpc_id            = var.vpc_id
  subnet_ids        = var.private_subnet_ids
  public_subnet_ids = var.public_subnet_ids

  # Not supplied, so the control-plane ENIs go into the private subnets. Pass
  # control_plane_subnet_ids if the VPC has dedicated subnets for them.

  endpoint_private_access = true
  endpoint_public_access  = false

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  create_system_node_group         = true
  system_node_group_instance_types = ["m7i.large", "m7a.large"]

  ami_type             = "BOTTLEROCKET_x86_64"
  bottlerocket_version = "1.68.1"

  enable_karpenter          = true
  enable_pod_identity_roles = true

  tags = {
    Environment = "example"
  }
}

output "cluster_name" {
  description = "Name of the cluster created on top of the pre-existing VPC."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "AWS CLI command that writes a kubeconfig entry for this cluster."
  value       = module.eks.kubeconfig_command
}
