###############################################################################
# Core
###############################################################################

variable "name" {
  description = "Name prefix applied to every networking resource. Typically the platform or cluster name, e.g. `platform-dev`."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 characters, lowercase alphanumeric or hyphen, and may not start or end with a hyphen."
  }
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR block for the VPC. A /16 is recommended so that pod IP exhaustion is not hit when using the AWS VPC CNI."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be /20 or larger (smaller prefix length) to leave room for four subnet tiers."
  }
}

variable "secondary_cidr_blocks" {
  description = <<-EOT
    Additional IPv4 CIDR blocks to associate with the VPC. Commonly used with the
    AWS VPC CNI custom networking feature to place pods in a non-routable
    100.64.0.0/10 range, preserving RFC1918 space for nodes and load balancers.
    Leave empty to disable.
  EOT
  type        = list(string)
  default     = []
}

variable "azs" {
  description = <<-EOT
    Availability Zone names to span, e.g. `["eu-central-1a", "eu-central-1b", "eu-central-1c"]`.
    Leave empty to automatically select the first `az_count` AZs that support EKS in the
    current region. Three AZs are strongly recommended for production.
  EOT
  type        = list(string)
  default     = []
}

variable "az_count" {
  description = "Number of Availability Zones to use when `azs` is not explicitly supplied."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6."
  }
}

###############################################################################
# Subnet layout
###############################################################################

variable "subnet_newbits" {
  description = <<-EOT
    Number of additional bits used when automatically carving subnets out of `vpc_cidr`
    via `cidrsubnet`. With a /16 VPC and the default of 4 you get /20 subnets
    (4091 usable IPs each). Ignored for any tier where an explicit CIDR list is supplied.
  EOT
  type        = number
  default     = 4
}

variable "public_subnet_cidrs" {
  description = "Explicit CIDR blocks for the public subnet tier. Leave empty to derive them automatically from `vpc_cidr`."
  type        = list(string)
  default     = []
}

variable "private_subnet_cidrs" {
  description = "Explicit CIDR blocks for the private application subnet tier (where EKS nodes and pods run). Leave empty to derive automatically."
  type        = list(string)
  default     = []
}

variable "database_subnet_cidrs" {
  description = "Explicit CIDR blocks for the isolated database subnet tier. Leave empty to derive automatically. Set `create_database_subnets = false` to skip this tier entirely."
  type        = list(string)
  default     = []
}

variable "intra_subnet_cidrs" {
  description = <<-EOT
    Explicit CIDR blocks for the intra subnet tier. Intra subnets have no route to the
    internet at all and are used for EKS control-plane cross-account ENIs and VPC
    endpoints. Leave empty to derive automatically.
  EOT
  type        = list(string)
  default     = []
}

variable "create_database_subnets" {
  description = "Create the isolated database subnet tier and an associated DB subnet group."
  type        = bool
  default     = true
}

variable "create_intra_subnets" {
  description = "Create the intra (fully isolated, no NAT) subnet tier used for EKS control-plane ENIs and interface endpoints."
  type        = bool
  default     = true
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses to instances launched in public subnets. Keep false unless you knowingly run public-facing EC2 instances."
  type        = bool
  default     = false
}

###############################################################################
# Egress
###############################################################################

variable "enable_nat_gateway" {
  description = "Provision NAT Gateways so that private subnets can reach the internet for image pulls and API calls."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    Deploy exactly one NAT Gateway shared by every private subnet instead of one per AZ.
    Saves roughly two thirds of the NAT hourly cost but creates a single point of failure
    and cross-AZ data transfer charges. Acceptable for dev, never for production.
  EOT
  type        = bool
  default     = false
}

variable "enable_ipv6" {
  description = "Associate an Amazon-provided /56 IPv6 CIDR with the VPC and assign /64 blocks to each subnet."
  type        = bool
  default     = false
}

variable "enable_egress_only_internet_gateway" {
  description = "Create an egress-only internet gateway so IPv6 workloads in private subnets can reach the internet. Only used when `enable_ipv6` is true."
  type        = bool
  default     = true
}

###############################################################################
# VPC endpoints
###############################################################################

variable "enable_vpc_endpoints" {
  description = <<-EOT
    Create VPC endpoints for the AWS services an EKS cluster depends on. This keeps traffic
    on the AWS backbone, removes the NAT data-processing charge for those calls, and is a
    hard requirement for fully private clusters.
  EOT
  type        = bool
  default     = true
}

variable "vpc_endpoint_services" {
  description = <<-EOT
    Interface endpoint service short names to create when `enable_vpc_endpoints` is true.
    `eks-auth` is required for EKS Pod Identity to work on nodes in private subnets.
    S3 and DynamoDB are always created as free gateway endpoints and must not be listed here.
  EOT
  type        = list(string)
  default = [
    "ec2",
    "ecr.api",
    "ecr.dkr",
    "eks",
    "eks-auth",
    "elasticloadbalancing",
    "sts",
    "logs",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "kms",
    "autoscaling",
    "sqs",
  ]
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the free S3 gateway VPC endpoint. Strongly recommended: ECR image layers are stored in S3."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Create the free DynamoDB gateway VPC endpoint."
  type        = bool
  default     = false
}

###############################################################################
# Observability
###############################################################################

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs. Required by CIS AWS Foundations Benchmark control 3.9 and by most audit regimes."
  type        = bool
  default     = true
}

variable "flow_logs_destination_type" {
  description = "Where to deliver VPC Flow Logs. `s3` is substantially cheaper for high-volume VPCs; `cloud-watch-logs` is easier to query interactively."
  type        = string
  default     = "cloud-watch-logs"

  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.flow_logs_destination_type)
    error_message = "flow_logs_destination_type must be either 'cloud-watch-logs' or 's3'."
  }
}

variable "flow_logs_destination_arn" {
  description = "ARN of an existing S3 bucket or CloudWatch log group to deliver flow logs to. Leave empty to have the module create a CloudWatch log group."
  type        = string
  default     = ""
}

variable "flow_logs_retention_days" {
  description = "Retention in days for the module-created CloudWatch flow log group."
  type        = number
  default     = 90

  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.flow_logs_retention_days
    )
    error_message = "flow_logs_retention_days must be a retention period CloudWatch Logs accepts."
  }
}

variable "flow_logs_traffic_type" {
  description = "Which traffic to capture in flow logs: ACCEPT, REJECT or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_logs_kms_key_arn" {
  description = "KMS key ARN used to encrypt the module-created CloudWatch flow log group. Leave empty to use the AWS-managed CloudWatch Logs key."
  type        = string
  default     = ""
}

###############################################################################
# EKS integration
###############################################################################

variable "eks_cluster_names" {
  description = <<-EOT
    Names of the EKS clusters that will consume these subnets. The module applies the
    `kubernetes.io/cluster/<name> = shared` tag for each entry so that the AWS Load Balancer
    Controller and the in-tree cloud provider can discover the subnets. Safe to leave empty
    and set later; the ELB role tags below are applied regardless.
  EOT
  type        = list(string)
  default     = []
}

variable "karpenter_discovery_value" {
  description = <<-EOT
    Value for the `karpenter.sh/discovery` tag applied to private subnets. Karpenter
    EC2NodeClass `subnetSelectorTerms` match on this tag. Conventionally the cluster name.
    Leave empty to skip Karpenter subnet tagging.
  EOT
  type        = string
  default     = ""
}

variable "public_subnet_tags" {
  description = "Extra tags merged onto public subnets, in addition to the ELB discovery tags the module always applies."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags merged onto private subnets, in addition to the internal-ELB and Karpenter discovery tags the module always applies."
  type        = map(string)
  default     = {}
}

###############################################################################
# Hardening
###############################################################################

variable "manage_default_security_group" {
  description = <<-EOT
    Take ownership of the VPC default security group and strip every ingress and egress
    rule from it. Required by CIS AWS Foundations Benchmark control 5.4.
  EOT
  type        = bool
  default     = true
}

variable "manage_default_network_acl" {
  description = "Take ownership of the VPC default network ACL and apply a documented baseline rule set."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC. Must remain true for EKS private endpoint resolution to work."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS resolution in the VPC. Must remain true for EKS."
  type        = bool
  default     = true
}

###############################################################################
# Tagging
###############################################################################

variable "tags" {
  description = "Tags applied to every resource created by this module."
  type        = map(string)
  default     = {}
}
