###############################################################################
# VPC
###############################################################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_secondary_cidr_blocks" {
  description = "Secondary IPv4 CIDR blocks associated with the VPC."
  value       = [for a in aws_vpc_ipv4_cidr_block_association.secondary : a.cidr_block]
}

output "vpc_ipv6_cidr_block" {
  description = "IPv6 CIDR block of the VPC, or null when IPv6 is disabled."
  value       = var.enable_ipv6 ? aws_vpc.this.ipv6_cidr_block : null
}

output "default_security_group_id" {
  description = "ID of the VPC default security group. It has no rules and must not be used."
  value       = aws_vpc.this.default_security_group_id
}

###############################################################################
# Availability Zones
###############################################################################

output "azs" {
  description = "Availability Zones the VPC spans."
  value       = local.azs
}

###############################################################################
# Subnets
###############################################################################

output "public_subnet_ids" {
  description = "IDs of the public subnets. Use for internet-facing load balancers."
  value       = aws_subnet.public[*].id
}

output "public_subnet_arns" {
  description = "ARNs of the public subnets."
  value       = aws_subnet.public[*].arn
}

output "public_subnet_cidr_blocks" {
  description = "CIDR blocks of the public subnets."
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private application subnets. Pass these to the EKS module as the node and cluster subnets."
  value       = aws_subnet.private[*].id
}

output "private_subnet_arns" {
  description = "ARNs of the private application subnets."
  value       = aws_subnet.private[*].arn
}

output "private_subnet_cidr_blocks" {
  description = "CIDR blocks of the private application subnets."
  value       = aws_subnet.private[*].cidr_block
}

output "database_subnet_ids" {
  description = "IDs of the isolated database subnets. Empty when create_database_subnets is false."
  value       = aws_subnet.database[*].id
}

output "database_subnet_group_name" {
  description = "Name of the RDS DB subnet group, or null when database subnets are disabled."
  value       = try(aws_db_subnet_group.this[0].name, null)
}

output "intra_subnet_ids" {
  description = "IDs of the fully isolated intra subnets. Pass these to the EKS module as control_plane_subnet_ids."
  value       = aws_subnet.intra[*].id
}

###############################################################################
# Routing and egress
###############################################################################

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "IDs of the NAT Gateways."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT Gateways. Add these to partner allow-lists for outbound traffic."
  value       = aws_eip.nat[*].public_ip
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables."
  value       = aws_route_table.private[*].id
}

output "database_route_table_id" {
  description = "ID of the database route table, or null when database subnets are disabled."
  value       = try(aws_route_table.database[0].id, null)
}

output "intra_route_table_id" {
  description = "ID of the intra route table, or null when intra subnets are disabled."
  value       = try(aws_route_table.intra[0].id, null)
}

###############################################################################
# VPC endpoints
###############################################################################

output "vpc_endpoint_security_group_id" {
  description = "ID of the security group attached to the interface VPC endpoints."
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}

output "interface_vpc_endpoint_ids" {
  description = "Map of interface endpoint service short name to endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or null when disabled."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

###############################################################################
# Flow logs
###############################################################################

output "flow_log_id" {
  description = "ID of the VPC flow log, or null when disabled."
  value       = try(aws_flow_log.this[0].id, null)
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group created for flow logs, or null."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}

###############################################################################
# Convenience bundle
#
# A single object that can be handed straight to the EKS module, so consumers do
# not have to wire eight separate outputs.
###############################################################################

output "eks_network_config" {
  description = "Pre-assembled networking inputs for the eks module. Pass as `var.network` or splat into individual arguments."
  value = {
    vpc_id                   = aws_vpc.this.id
    vpc_cidr_block           = aws_vpc.this.cidr_block
    private_subnet_ids       = aws_subnet.private[*].id
    public_subnet_ids        = aws_subnet.public[*].id
    control_plane_subnet_ids = var.create_intra_subnets ? aws_subnet.intra[*].id : aws_subnet.private[*].id
    azs                      = local.azs
  }
}
