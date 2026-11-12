###############################################################################
# Public subnets
#
# Host internet-facing ALBs and NLBs and the NAT Gateways. No workload should
# ever be scheduled here; EKS nodes belong in the private tier.
###############################################################################

resource "aws_subnet" "public" {
  count = length(local.public_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = var.map_public_ip_on_launch

  ipv6_cidr_block                 = var.enable_ipv6 ? cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, local.tier_index.public * local.az_count + count.index) : null
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = merge(
    local.public_subnet_tags,
    { Name = "${var.name}-public-${local.azs[count.index]}" },
  )
}

###############################################################################
# Private application subnets
#
# EKS managed node groups, Karpenter-provisioned nodes, pods and internal load
# balancers live here. Egress is via NAT Gateway.
###############################################################################

resource "aws_subnet" "private" {
  count = length(local.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  ipv6_cidr_block                 = var.enable_ipv6 ? cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, local.tier_index.private * local.az_count + count.index) : null
  assign_ipv6_address_on_creation = var.enable_ipv6

  tags = merge(
    local.private_subnet_tags,
    { Name = "${var.name}-private-${local.azs[count.index]}" },
  )
}

###############################################################################
# Database subnets
#
# Isolated tier for RDS, ElastiCache and similar. No route to the internet in
# either direction.
###############################################################################

resource "aws_subnet" "database" {
  count = length(local.database_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.database_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-database-${local.azs[count.index]}"
      Tier = "database"
    },
  )
}

resource "aws_db_subnet_group" "this" {
  count = var.create_database_subnets ? 1 : 0

  name        = "${var.name}-db"
  description = "Database subnet group for ${var.name}"
  subnet_ids  = aws_subnet.database[*].id

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

###############################################################################
# Intra subnets
#
# Fully isolated: no NAT, no internet gateway. Used for the EKS control-plane
# cross-account ENIs and for interface VPC endpoints, so that neither depends on
# NAT Gateway availability. Keeping control-plane ENIs out of the private
# application tier also means a NAT outage cannot affect the API server.
###############################################################################

resource "aws_subnet" "intra" {
  count = length(local.intra_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.intra_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    local.eks_cluster_tags,
    {
      Name = "${var.name}-intra-${local.azs[count.index]}"
      Tier = "intra"
    },
  )
}
