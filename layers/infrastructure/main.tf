###############################################################################
# Infrastructure layer
#
# AWS-only. No kubernetes, helm or kubectl provider is configured here, and that
# is deliberate: a provider whose configuration depends on a resource created in
# the same apply cannot be planned reliably, and produces the familiar
# "Provider configuration not present" failure on destroy. Everything that talks
# to the Kubernetes API lives in layers/bootstrap, which reads this layer's
# state.
###############################################################################

locals {
  cluster_name = "${var.name}-${var.environment}"

  default_tags = merge(
    {
      Environment = var.environment
      Platform    = var.name
      ManagedBy   = "terraform"
      Repository  = "terraform-eks-cluster"
      Layer       = "infrastructure"
    },
    var.tags,
  )

  # Resolve networking from either the module or the caller-supplied values.
  # Every downstream reference goes through this object so that nothing else in
  # the layer has to care which mode is in use.
  network = var.create_networking ? {
    vpc_id                   = module.networking[0].vpc_id
    vpc_cidr_block           = module.networking[0].vpc_cidr_block
    private_subnet_ids       = module.networking[0].private_subnet_ids
    public_subnet_ids        = module.networking[0].public_subnet_ids
    control_plane_subnet_ids = module.networking[0].intra_subnet_ids
    } : {
    vpc_id             = var.existing_vpc_id
    vpc_cidr_block     = try(data.aws_vpc.existing[0].cidr_block, null)
    private_subnet_ids = var.existing_private_subnet_ids
    public_subnet_ids  = var.existing_public_subnet_ids
    control_plane_subnet_ids = length(var.existing_control_plane_subnet_ids) > 0 ? (
      var.existing_control_plane_subnet_ids
    ) : var.existing_private_subnet_ids
  }
}

###############################################################################
# Existing networking lookups
###############################################################################

data "aws_vpc" "existing" {
  count = var.create_networking ? 0 : 1
  id    = var.existing_vpc_id
}

data "aws_subnet" "existing_private" {
  for_each = var.create_networking ? toset([]) : toset(var.existing_private_subnet_ids)
  id       = each.value
}

###############################################################################
# Preconditions for the "bring your own VPC" path
#
# These fail during plan with an actionable message, rather than halfway through
# an apply with an opaque AWS API error.
###############################################################################

check "existing_networking_supplied" {
  assert {
    condition = var.create_networking || (
      var.existing_vpc_id != null && length(var.existing_private_subnet_ids) >= 2
    )
    error_message = "create_networking is false, so existing_vpc_id and at least two existing_private_subnet_ids must be supplied."
  }
}

check "existing_subnets_span_multiple_azs" {
  assert {
    condition = var.create_networking || length(distinct([
      for s in data.aws_subnet.existing_private : s.availability_zone
    ])) >= 2
    error_message = "existing_private_subnet_ids must span at least two Availability Zones. EKS refuses to create a cluster in a single AZ."
  }
}

check "existing_subnets_in_supplied_vpc" {
  assert {
    condition = var.create_networking || alltrue([
      for s in data.aws_subnet.existing_private : s.vpc_id == var.existing_vpc_id
    ])
    error_message = "Every subnet in existing_private_subnet_ids must belong to existing_vpc_id."
  }
}

###############################################################################
# Networking
###############################################################################

module "networking" {
  source = "../../modules/networking"

  count = var.create_networking ? 1 : 0

  name     = "${var.name}-${var.environment}"
  vpc_cidr = var.vpc_cidr
  azs      = var.azs
  az_count = var.az_count

  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway

  # Intra subnets have no route to the internet at all. The control-plane ENIs
  # and the interface VPC endpoints live there, so they keep working through a
  # NAT Gateway outage and cannot be used as an egress path.
  create_intra_subnets    = true
  create_database_subnets = true

  enable_vpc_endpoints = var.enable_vpc_endpoints

  enable_flow_logs         = var.enable_flow_logs
  flow_logs_retention_days = var.flow_logs_retention_days

  # Applies the kubernetes.io/role/elb, kubernetes.io/role/internal-elb and
  # karpenter.sh/discovery tags the controllers use to find subnets. Without
  # them, load balancer provisioning and Karpenter node launches both fail with
  # errors that point nowhere near the real cause.
  eks_cluster_names         = [local.cluster_name]
  karpenter_discovery_value = local.cluster_name

  tags = merge(local.default_tags, var.networking_tags)
}

###############################################################################
# EKS cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = local.network.vpc_id
  subnet_ids               = local.network.private_subnet_ids
  control_plane_subnet_ids = local.network.control_plane_subnet_ids
  public_subnet_ids        = local.network.public_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  # Baseline capacity is a fixed self-managed ASG; Karpenter owns everything
  # elastic. No EKS managed node groups, and no Cluster Autoscaler.
  create_system_node_group         = true
  system_node_group_instance_types = var.system_node_group_instance_types
  system_node_group_min_size       = var.system_node_group_min_size
  system_node_group_max_size       = var.system_node_group_max_size
  system_node_group_desired_size   = var.system_node_group_desired_size
  self_managed_node_groups         = var.self_managed_node_groups

  ami_type             = var.ami_type
  bottlerocket_version = var.bottlerocket_version
  node_os_disk_size    = var.node_os_disk_size
  node_data_disk_size  = var.node_data_disk_size

  enable_karpenter = var.enable_karpenter

  enable_pod_identity_roles     = true
  external_dns_hosted_zone_arns = var.external_dns_hosted_zone_arns
  cert_manager_hosted_zone_arns = var.cert_manager_hosted_zone_arns

  enable_efs_csi_driver = var.enable_efs_csi_driver

  tags = merge(local.default_tags, var.cluster_tags)

  depends_on = [module.networking]
}
