###############################################################################
# VPC endpoints
#
# Interface endpoints keep EKS control-plane and node traffic on the AWS
# backbone. Three concrete benefits:
#   1. Fully private clusters work without any NAT Gateway.
#   2. ECR image pulls and STS/EKS-Auth calls skip the NAT data-processing fee,
#      which usually pays for the endpoints outright on a busy cluster.
#   3. The `eks-auth` endpoint is a hard requirement for EKS Pod Identity when
#      nodes have no route to the public internet.
###############################################################################

locals {
  # Interface endpoints are placed in the intra tier when it exists, so they stay
  # reachable even if NAT or the application tier is impaired.
  endpoint_subnet_ids = var.create_intra_subnets ? aws_subnet.intra[*].id : aws_subnet.private[*].id

  interface_endpoints = var.enable_vpc_endpoints ? toset(var.vpc_endpoint_services) : toset([])

  # Every route table that should receive the gateway endpoint prefix-list routes.
  gateway_endpoint_route_table_ids = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id,
    aws_route_table.database[*].id,
    aws_route_table.intra[*].id,
  )
}

###############################################################################
# Security group for interface endpoints
#
# Allows HTTPS only, and only from inside the VPC. Interface endpoints are ENIs
# with private IPs, so a VPC-scoped source is the correct boundary.
###############################################################################

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from within the VPC to interface VPC endpoints for ${var.name}"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = var.enable_vpc_endpoints ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC CIDR"

  cidr_ipv4   = aws_vpc.this.cidr_block
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https_secondary" {
  for_each = var.enable_vpc_endpoints ? toset(var.secondary_cidr_blocks) : toset([])

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from secondary VPC CIDR ${each.value}"

  cidr_ipv4   = each.value
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = var.tags

  depends_on = [aws_vpc_ipv4_cidr_block_association.secondary]
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https_ipv6" {
  count = var.enable_vpc_endpoints && var.enable_ipv6 ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC IPv6 CIDR"

  cidr_ipv6   = aws_vpc.this.ipv6_cidr_block
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = var.tags
}

###############################################################################
# Gateway endpoints (no hourly charge, no ENI)
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints && var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_vpc_endpoints && var.enable_dynamodb_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = merge(var.tags, { Name = "${var.name}-dynamodb" })
}

###############################################################################
# Interface endpoints
###############################################################################

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.value}" })
}
