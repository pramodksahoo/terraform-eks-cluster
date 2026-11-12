###############################################################################
# Identity and account targeting
###############################################################################

variable "name" {
  description = "Base name for the platform. Used to derive the VPC name and the cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, 3-32 characters, starting with a letter."
  }
}

variable "environment" {
  description = "Environment this stack belongs to. Becomes part of resource names and tags, and is used to pick safer defaults in production."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,16}$", var.environment))
    error_message = "environment must be lowercase alphanumeric with hyphens, 2-16 characters."
  }
}

variable "region" {
  description = "AWS region. Kept as a variable rather than hardcoded so the same stack can be stood up in a second region when multi-region becomes a requirement."
  type        = string
  default     = "eu-central-1"
}

variable "assume_role_arn" {
  description = <<-EOT
    IAM role assumed in the target account before creating anything. This is the
    multi-account mechanism: the pipeline holds one identity and crosses an account
    boundary through a role rather than holding credentials per account.

    Null runs against whatever identity the environment already has, which is
    appropriate for a single-account setup or local development.
  EOT
  type        = string
  default     = null
}

variable "assume_role_external_id" {
  description = "External ID required when assuming assume_role_arn. Protects the target role against the confused-deputy problem."
  type        = string
  default     = null
  sensitive   = true
}

variable "allowed_account_ids" {
  description = <<-EOT
    AWS account IDs this stack is permitted to run against. Terraform refuses to plan
    if the resolved identity is in any other account.

    Set this. It is the cheapest possible guard against a stale variable file pointing
    a development pipeline at the production account.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource through the provider's default_tags."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking: create or reuse
###############################################################################

variable "create_networking" {
  description = <<-EOT
    Whether this stack provisions its own networking.

      true  - a VPC, subnets, route tables, NAT and Internet Gateways, VPC endpoints
              and flow logs are created, correctly tagged for EKS, ELB and Karpenter
              discovery. Use this for a greenfield environment.

      false - no networking resources are created. The cluster is built inside the VPC
              and subnets supplied through the existing_* variables. Use this when a
              platform or network team already owns the VPC.

    When false, the existing subnets must carry the discovery tags EKS and the AWS Load
    Balancer Controller rely on. See `tag_requirements_for_existing_subnets` in the
    outputs for the exact set, and the module README for the rationale.
  EOT
  type        = bool
  default     = true
}

variable "existing_vpc_id" {
  description = "ID of an existing VPC. Required when create_networking is false."
  type        = string
  default     = null
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs for worker nodes. Required when create_networking is false. Must span at least two Availability Zones."
  type        = list(string)
  default     = []
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs for internet-facing load balancers. Optional; omit for a fully private cluster with no public ingress."
  type        = list(string)
  default     = []
}

variable "existing_control_plane_subnet_ids" {
  description = "Subnets for the EKS control-plane ENIs. Optional; defaults to the private subnets. Dedicated subnets keep control-plane ENIs isolated from workload IP exhaustion."
  type        = list(string)
  default     = []
}

###############################################################################
# Networking configuration (ignored when create_networking is false)
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Size it for the pod IP density you expect: with the VPC CNI every pod consumes a VPC address."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread the VPC across. Three is the minimum for a production control plane that tolerates an AZ failure without losing quorum."
  type        = number
  default     = 3
}

variable "azs" {
  description = "Explicit Availability Zone names. Empty selects the first az_count zones in the region that actually support EKS."
  type        = list(string)
  default     = []
}

variable "single_nat_gateway" {
  description = <<-EOT
    Route all private subnets through one NAT Gateway instead of one per AZ.

    This saves roughly two thirds of the NAT hourly cost and is reasonable for
    development. In production it creates both a single point of failure and
    cross-AZ data charges on every byte of egress — leave it false.
  EOT
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "Create NAT Gateways. Set to false only for a fully private VPC that reaches AWS services exclusively through VPC endpoints."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Create interface VPC endpoints for the AWS services the cluster depends on. Keeps control-plane and add-on traffic off the NAT Gateway, which improves both security posture and NAT data cost."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Capture VPC flow logs. Effectively mandatory for incident investigation and for most compliance baselines."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Retention for the flow log group."
  type        = number
  default     = 90
}

variable "networking_tags" {
  description = "Additional tags applied to networking resources only."
  type        = map(string)
  default     = {}
}

###############################################################################
# Cluster
###############################################################################

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane."
  type        = string
  default     = "1.37"
}

variable "endpoint_public_access" {
  description = <<-EOT
    Expose the Kubernetes API endpoint to the internet.

    Defaults to false. A private endpoint means the API server is reachable only from
    inside the VPC or across a VPN or Direct Connect link, which removes the cluster's
    control plane from internet-wide credential-stuffing and CVE scanning entirely.

    If this is turned on, endpoint_public_access_cidrs must be narrowed.
  EOT
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks permitted to reach the public API endpoint. 0.0.0.0/0 is rejected by the EKS module in this repository."
  type        = list(string)
  default     = []
}

variable "enable_cluster_creator_admin_permissions" {
  description = <<-EOT
    Grant the identity running Terraform cluster-admin through an access entry.

    Convenient for bootstrapping, but it ties cluster administration to whatever
    principal the pipeline happens to use. In production, set this false and grant
    access explicitly through access_entries to named roles.
  EOT
  type        = bool
  default     = true
}

variable "access_entries" {
  description = "EKS access entries granting IAM principals access to the cluster. This replaces the aws-auth ConfigMap, which was removed in EKS module v21."
  type        = any
  default     = {}
}

variable "system_node_group_instance_types" {
  description = <<-EOT
    Instance types for the baseline self-managed ASG, in order of preference. This
    group runs only the platform controllers; application capacity comes from
    Karpenter.

    More than one type enables a mixed instances policy pinned to 100% on-demand, so
    a single Insufficient Capacity Exception cannot leave the cluster without its
    baseline.
  EOT
  type        = list(string)
  default     = ["m7i.large", "m7a.large", "m6i.large"]
}

variable "system_node_group_min_size" {
  description = <<-EOT
    Minimum size of the baseline ASG, and in practice its steady-state size — the
    underlying ASG ignores `desired_capacity` after creation. Two is the floor for a
    highly available controller set.
  EOT
  type        = number
  default     = 2
}

variable "system_node_group_max_size" {
  description = "Maximum size of the baseline ASG. Nothing autoscales this group; headroom exists only so instance refresh can surge during an AMI roll."
  type        = number
  default     = 4
}

variable "system_node_group_desired_size" {
  description = "Initial size of the baseline ASG. Ignored on later applies; change `system_node_group_min_size` instead."
  type        = number
  default     = 2
}

variable "ami_type" {
  description = "AMI family for the self-managed node groups. Bottlerocket is a minimal, immutable, container-only OS with no shell or package manager."
  type        = string
  default     = "BOTTLEROCKET_x86_64"
}

variable "bottlerocket_version" {
  description = <<-EOT
    Bottlerocket OS version pinned for the baseline AMI, as a bare semver. Resolved
    from `/aws/service/bottlerocket/aws-k8s-<version>/<arch>/<this>/image_id`.

    Pinning is deliberate: with `latest`, a new AWS AMI publication would roll every
    baseline node on the next apply.
  EOT
  type        = string
  default     = "1.68.1"
}

variable "node_os_disk_size" {
  description = "Size in GiB of the Bottlerocket OS volume (`/dev/xvda`). Container data does not live here."
  type        = number
  default     = 10
}

variable "node_data_disk_size" {
  description = "Size in GiB of the Bottlerocket data volume (`/dev/xvdb`), holding container images, writable layers and ephemeral storage."
  type        = number
  default     = 100
}

variable "self_managed_node_groups" {
  description = <<-EOT
    Additional self-managed node groups beyond the baseline. Most workloads should run
    on Karpenter instead; use this for capacity that genuinely cannot be dynamically
    provisioned, such as licence-bound or GPU-reserved nodes.

    Note `instance_type` is singular, and labels and taints are passed as Bottlerocket
    TOML through `bootstrap_extra_args`.
  EOT
  type        = any
  default     = {}
}

variable "enable_karpenter" {
  description = "Create the Karpenter IAM roles, instance profile and interruption queue. The controller workload itself is installed by the bootstrap layer."
  type        = bool
  default     = true
}

variable "external_dns_hosted_zone_arns" {
  description = "Route 53 hosted zone ARNs external-dns may write to. Scoping this to specific zones is what stops one cluster from editing another's DNS."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "cert_manager_hosted_zone_arns" {
  description = "Route 53 hosted zone ARNs cert-manager may use for DNS-01 challenges."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "enable_efs_csi_driver" {
  description = "Install the EFS CSI driver addon and its IAM role. Needed only for ReadWriteMany volumes; EBS covers ReadWriteOnce."
  type        = bool
  default     = false
}

variable "cluster_tags" {
  description = "Additional tags applied to cluster resources only."
  type        = map(string)
  default     = {}
}
