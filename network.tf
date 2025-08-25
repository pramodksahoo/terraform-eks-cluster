# Network Configuration

# Subnet tagging for EKS cluster discovery
resource "aws_ec2_tag" "update_subnet_tags" {
  count = length(var.subnet_ids)

  key           = "kubernetes.io/cluster/${var.cluster_name}"
  value         = "shared"
  resource_id   = var.subnet_ids[count.index]
}

resource "aws_ec2_tag" "update_public_subnet_tags" {
  count = length(var.public_subnet_ids)

  key           = "kubernetes.io/cluster/${var.cluster_name}"
  value         = "shared"
  resource_id   = var.public_subnet_ids[count.index]
}

# Karpenter subnet discovery tags for private subnets
resource "aws_ec2_tag" "karpenter_private_subnet_discovery" {
  count = length(var.subnet_ids)

  key           = "karpenter.sh/discovery"
  value         = var.cluster_name
  resource_id   = var.subnet_ids[count.index]
}

# Public subnets for internet-facing ELB
resource "aws_ec2_tag" "public_subnet_elb_role" {
  count = length(var.public_subnet_ids)

  key         = "kubernetes.io/role/elb"
  value       = "1"
  resource_id = var.public_subnet_ids[count.index]
}

# Private subnets for internal ELB
resource "aws_ec2_tag" "private_subnet_internal_elb_role" {
  count = length(var.subnet_ids)

  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
  resource_id = var.subnet_ids[count.index]
}

# # Karpenter subnet discovery tags for public subnets (if needed)
# resource "aws_ec2_tag" "karpenter_public_subnet_discovery" {
#   count = length(var.public_subnet_ids)

#   key           = "karpenter.sh/discovery/example"
#   value         = var.cluster_name
#   resource_id   = var.public_subnet_ids[count.index]
# } 