###############################################################################
# Data sources
###############################################################################

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Only Availability Zones (not Local Zones or Wavelength Zones) are usable for
# EKS subnets, so the filter is explicit rather than relying on defaults.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

###############################################################################
# Locals
###############################################################################

locals {
  azs      = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, var.az_count)
  az_count = length(local.azs)

  # Subnet tiers are packed contiguously so that a /16 VPC with newbits = 4
  # yields: public 0..n, private n..2n, database 2n..3n, intra 3n..4n.
  tier_index = {
    public   = 0
    private  = 1
    database = 2
    intra    = 3
  }

  # Total number of subnet slots the automatic layout requires.
  required_slots  = 4 * local.az_count
  available_slots = pow(2, var.subnet_newbits)

  public_subnet_cidrs = length(var.public_subnet_cidrs) > 0 ? var.public_subnet_cidrs : [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, (local.tier_index.public * local.az_count) + i)
  ]

  private_subnet_cidrs = length(var.private_subnet_cidrs) > 0 ? var.private_subnet_cidrs : [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, (local.tier_index.private * local.az_count) + i)
  ]

  database_subnet_cidrs = !var.create_database_subnets ? [] : (
    length(var.database_subnet_cidrs) > 0 ? var.database_subnet_cidrs : [
      for i in range(local.az_count) :
      cidrsubnet(var.vpc_cidr, var.subnet_newbits, (local.tier_index.database * local.az_count) + i)
    ]
  )

  intra_subnet_cidrs = !var.create_intra_subnets ? [] : (
    length(var.intra_subnet_cidrs) > 0 ? var.intra_subnet_cidrs : [
      for i in range(local.az_count) :
      cidrsubnet(var.vpc_cidr, var.subnet_newbits, (local.tier_index.intra * local.az_count) + i)
    ]
  )

  # One NAT Gateway per AZ by default; a single shared gateway when explicitly opted in.
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : local.az_count) : 0

  # Tags every EKS-aware controller looks for. `shared` (rather than `owned`) is used so
  # that several clusters can safely coexist in one VPC and so that deleting a cluster
  # never attempts to delete subnets this module owns.
  eks_cluster_tags = {
    for cluster in var.eks_cluster_names :
    "kubernetes.io/cluster/${cluster}" => "shared"
  }

  # `kubernetes.io/role/elb` marks subnets the AWS Load Balancer Controller may use for
  # internet-facing ALBs and NLBs. `internal-elb` marks subnets for internal ones.
  public_subnet_tags = merge(
    var.tags,
    local.eks_cluster_tags,
    {
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
    var.public_subnet_tags,
  )

  private_subnet_tags = merge(
    var.tags,
    local.eks_cluster_tags,
    {
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.karpenter_discovery_value != "" ? {
      "karpenter.sh/discovery" = var.karpenter_discovery_value
    } : {},
    var.private_subnet_tags,
  )

  flow_logs_log_group_name = "/aws/vpc/flow-logs/${var.name}"

  create_flow_log_group = var.enable_flow_logs && var.flow_logs_destination_type == "cloud-watch-logs" && var.flow_logs_destination_arn == ""
}

###############################################################################
# Guard rails
###############################################################################

check "subnet_capacity" {
  assert {
    condition     = local.required_slots <= local.available_slots
    error_message = <<-EOT
      The automatic subnet layout needs ${local.required_slots} slots across ${local.az_count} AZs
      but subnet_newbits = ${var.subnet_newbits} only provides ${local.available_slots}.
      Increase subnet_newbits to at least ${ceil(log(local.required_slots, 2))}, reduce az_count,
      or supply explicit *_subnet_cidrs.
    EOT
  }
}

check "production_nat_redundancy" {
  assert {
    condition     = !(var.enable_nat_gateway && var.single_nat_gateway && local.az_count > 1)
    error_message = "single_nat_gateway = true creates a single point of failure across ${local.az_count} AZs. Acceptable for non-production only."
  }
}
