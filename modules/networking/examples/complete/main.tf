###############################################################################
# Networking module - complete example
#
# A production-shaped VPC: three AZs, four subnet tiers, one NAT Gateway per AZ,
# interface VPC endpoints, flow logs, and the discovery tags EKS, the AWS Load
# Balancer Controller and Karpenter need.
#
#   terraform init && terraform apply
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Example   = "networking-complete"
      ManagedBy = "terraform"
    }
  }
}

module "networking" {
  source = "../../"

  name     = "example-complete"
  vpc_cidr = "10.0.0.0/16"

  # Three AZs is the minimum that survives the loss of one without losing
  # quorum on anything that needs a majority.
  az_count = 3

  # Four tiers:
  #   public   - NAT Gateways and internet-facing load balancers
  #   private  - worker nodes
  #   database - RDS and ElastiCache, with no route off the VPC at all
  #   intra    - control-plane ENIs and interface VPC endpoints, no internet
  #              route, so they keep working through a NAT outage
  create_database_subnets = true
  create_intra_subnets    = true

  # One NAT Gateway per AZ. An AZ losing its gateway does not take the other
  # AZs' egress with it, and no egress byte crosses an AZ boundary.
  enable_nat_gateway = true
  single_nat_gateway = false

  # Keeps control-plane, ECR, S3, STS and CloudWatch traffic off the NAT
  # Gateway. Better security posture and a materially lower NAT data bill.
  enable_vpc_endpoints = true

  enable_flow_logs         = true
  flow_logs_traffic_type   = "ALL"
  flow_logs_retention_days = 365

  # Tags the subnets for cluster, load balancer and Karpenter discovery. Supply
  # every cluster name that will live in this VPC.
  eks_cluster_names         = ["example-complete-eks"]
  karpenter_discovery_value = "example-complete-eks"

  tags = {
    Environment = "example"
    Owner       = "platform-team"
  }
}

output "eks_network_config" {
  description = "Pass straight into modules/eks."
  value       = module.networking.eks_network_config
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "nat_public_ips" {
  description = "The cluster's egress addresses. Give these to anyone allow-listing outbound traffic."
  value       = module.networking.nat_public_ips
}
