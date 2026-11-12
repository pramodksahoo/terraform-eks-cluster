###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both must stay enabled: EKS relies on DNS to resolve the private API server
  # endpoint and for the EFS/EBS CSI drivers to reach their service endpoints.
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  assign_generated_ipv6_cidr_block = var.enable_ipv6

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  for_each = toset(var.secondary_cidr_blocks)

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
}

###############################################################################
# Internet gateway
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_egress_only_internet_gateway" "this" {
  count = var.enable_ipv6 && var.enable_egress_only_internet_gateway ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-eigw" })
}

###############################################################################
# Default security group - CIS AWS Foundations Benchmark 5.4
#
# Taking ownership of the default security group and declaring no rules removes
# every inbound and outbound rule from it. Nothing should ever be attached to the
# default SG; this guarantees that anything accidentally attached is inert.
###############################################################################

resource "aws_default_security_group" "this" {
  count = var.manage_default_security_group ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-default-do-not-use"
    Note = "Intentionally has no rules. Do not attach workloads."
  })
}

###############################################################################
# Default network ACL
#
# Network ACLs are stateless, so an explicit allow is required in both
# directions. This baseline is permissive by design: security groups are the
# primary control, and over-restrictive NACLs break EKS in ways that are
# notoriously hard to diagnose. Tighten per-tier NACLs only with a clear
# threat model.
###############################################################################

resource "aws_default_network_acl" "this" {
  count = var.manage_default_network_acl ? 1 : 0

  default_network_acl_id = aws_vpc.this.default_network_acl_id

  ingress {
    rule_no    = 100
    action     = "allow"
    from_port  = 0
    to_port    = 0
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
  }

  dynamic "ingress" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      rule_no         = 101
      action          = "allow"
      from_port       = 0
      to_port         = 0
      protocol        = "-1"
      ipv6_cidr_block = "::/0"
    }
  }

  egress {
    rule_no    = 100
    action     = "allow"
    from_port  = 0
    to_port    = 0
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
  }

  dynamic "egress" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      rule_no         = 101
      action          = "allow"
      from_port       = 0
      to_port         = 0
      protocol        = "-1"
      ipv6_cidr_block = "::/0"
    }
  }

  # Subnet associations are managed by the aws_subnet resources themselves.
  lifecycle {
    ignore_changes = [subnet_ids]
  }

  tags = merge(var.tags, { Name = "${var.name}-default-nacl" })
}
