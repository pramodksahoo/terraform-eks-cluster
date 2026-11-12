###############################################################################
# Networking module - minimal example
#
# The cheapest VPC that still works for a development EKS cluster: two AZs,
# public and private subnets only, one shared NAT Gateway.
#
# Do not copy this into production. single_nat_gateway is both a single point
# of failure and a source of cross-AZ data charges, and skipping the intra tier
# puts the control-plane ENIs in the same subnets as the workload.
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
}

module "networking" {
  source = "../../"

  name     = "example-minimal"
  vpc_cidr = "10.1.0.0/16"
  az_count = 2

  create_database_subnets = false
  create_intra_subnets    = false

  enable_nat_gateway = true
  single_nat_gateway = true

  # Endpoints cost an hourly fee per AZ per service. In a development VPC with
  # low egress volume, routing through the single NAT Gateway is cheaper.
  enable_vpc_endpoints = false

  enable_flow_logs         = true
  flow_logs_retention_days = 14

  eks_cluster_names = ["example-minimal-eks"]

  tags = {
    Environment = "dev"
  }
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}
