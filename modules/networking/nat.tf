###############################################################################
# NAT Gateways
#
# One per AZ by default so that a zonal failure cannot sever egress for the
# whole cluster, and so that NAT traffic never crosses an AZ boundary (which is
# both slower and billed as cross-AZ transfer).
###############################################################################

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  # NOTE: the legacy `vpc = true` argument was removed in AWS provider v6.
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-${var.single_nat_gateway ? "shared" : local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name}-nat-${var.single_nat_gateway ? "shared" : local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}
