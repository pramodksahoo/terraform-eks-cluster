###############################################################################
# Public route table
#
# A single public route table is shared by all public subnets: every one of them
# routes to the same internet gateway, so per-AZ tables would add no value.
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-public"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "public_internet_ipv6" {
  count = var.enable_ipv6 ? 1 : 0

  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Private route tables
#
# One per AZ, each pointing at the NAT Gateway in its own AZ. When
# single_nat_gateway is true they all point at the one shared gateway.
###############################################################################

resource "aws_route_table" "private" {
  count = length(local.private_subnet_cidrs)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? length(aws_route_table.private) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "private_ipv6_egress" {
  count = var.enable_ipv6 && var.enable_egress_only_internet_gateway ? length(aws_route_table.private) : 0

  route_table_id              = aws_route_table.private[count.index].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# Database route table
#
# Deliberately has no default route. Databases reach AWS services through VPC
# endpoints, never through NAT.
###############################################################################

resource "aws_route_table" "database" {
  count = var.create_database_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-database"
    Tier = "database"
  })
}

resource "aws_route_table_association" "database" {
  count = length(aws_subnet.database)

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database[0].id
}

###############################################################################
# Intra route table
#
# Also has no default route. Only the local VPC route and gateway endpoint
# prefix lists apply.
###############################################################################

resource "aws_route_table" "intra" {
  count = var.create_intra_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-intra"
    Tier = "intra"
  })
}

resource "aws_route_table_association" "intra" {
  count = length(aws_subnet.intra)

  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra[0].id
}
