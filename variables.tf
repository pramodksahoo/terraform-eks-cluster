# PROVIDER

variable "region" {
  default     = "eu-central-1"
  description = "AWS region"
}

variable "aws_profile" {
  default     = "viewar-s3-terraform"
  description = "Name of aws-cli profile to use"
}

variable "vpc_id" {
  default = "vpc-0746459fe6c860319" # which vpc as needed
}
variable "subnet_ids" {
  type    = list(string)
  default = ["subnet-0d31c021f8ae604c7", "subnet-0f044d4c2c47f6094", "subnet-0f5e8cc600564d21d"] # which subnet as needed
}

variable "public_subnet_ids" {
  type    = list(string)
  default = ["subnet-0ef75f832c29112bf", "subnet-0f04e8e934b7c9361", "subnet-0dd47da85a4a8aa8c"] # which subnet as needed
}

###### EKS Cluster Configuration #####

variable "cluster_name" {
  default     = "example-cluster"
  type        = string
  description = "Name of EKS cluster"
}

variable "cluster_version" {
  default     = "1.33"
  type        = string
  description = "Kubernetes cluster version"
}

variable "cluster_public_cidrs" {
  description = "Allowed CIDRs for public API endpoint access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

#### Primary Node Group Configuration #####

variable "primary_nodegroup_name" {
  default     = "dev-cluster-primary"
  description = "Name of eks nodegroup"
}

variable "primary_min_size" {
  description = "Minimum number of instances in the primary node group"
  type        = number
  default     = 3
}

variable "primary_max_size" {
  description = "Maximum number of instances in the primary node group"
  type        = number
  default     = 6
}

variable "primary_desired_size" {
  description = "Desired number of instances in the primary node group"
  type        = number
  default     = 3
}
# note: only nitro based types work with vpc_cni plugin / toggle  t3a.medium/t3.medium to force node group update
variable "node_instance_type" {
  description = "Instance type for the primary node group"
  type        = list(string)
  default     = ["t3a.medium"]
}

### Upgrade Node Group Configuration #####

variable "upgrade_nodegroup_name" {
  default     = "dev-cluster-upgrade"
  description = "Name of eks nodegroup"
}

variable "upgrade_min_size" {
  description = "Minimum number of instances in the upgrade node group"
  type        = number
  default     = 0
}

variable "upgrade_max_size" {
  description = "Maximum number of instances in the upgrade node group"
  type        = number
  default     = 6
}

variable "upgrade_desired_size" {
  description = "Desired number of instances in the upgrade node group"
  type        = number
  default     = 0
}

variable "upgrade_instance_type" {
  description = "Instance type for the upgrade node group"
  type        = list(string)
  default     = ["t3a.medium"]
}

variable "upgrade_version" {
  description = "Kubernetes version for upgrade node group"
  type        = string
  default     = "1.33"
}

variable "enable_upgrade_nodegroup" {
  description = "Enable the upgrade node group for zero-downtime upgrades"
  type        = bool
  default     = false
}

##  Karpenter ####

variable "karpenter_manifest_dir" {
  type        = string
  description = "Relative path to Karpenter manifest directory"
  default     = "karpenter" # just the directory name, no path.module
}

variable "karpenter_version" {
  description = "Karpenter version"
  type        = string
  default     = "1.5.0"
}

variable "karpenter_cpu_limits" {
  description = "CPU limit for Karpenter provisioning"
  type        = number
  default     = 1000
}

variable "karpenter_instance_families" {
  type        = list(string)
  default     = ["t3a", "t2", "m"]
  description = "Instance families (e.g., c, m, r)"
}

variable "karpenter_capacity_types" {
  type        = list(string)
  default     = ["spot", "on-demand"]
  description = "Capacity types (spot/on-demand)"
}

variable "karpenter_ami_family" {
  type        = string
  default     = "AL2023"  # Default to AL2023 for EKS 1.30+
  description = "AMI family (AL2, AL2023, Bottlerocket)"
}
#### IAM Configuration #####

variable "enable_iam_roles" {
  description = "Enable creation of IAM roles for the cluster"
  type        = bool
  default     = true
}

variable "karpenter_node_role_policies" {
  description = "List of AWS managed policy ARNs to attach to Karpenter Node Role"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
}

variable "prometheus_role_policies" {
  description = "List of AWS managed policy ARNs to attach to Prometheus Role"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  ]
}

variable "karpenter_controller_policy_statements" {
  description = "Custom policy statements for Karpenter Controller Policy"
  type        = list(any)
  default     = []
}

variable "create_node_group_data_source" {
  description = "Whether to create the node group data source for Karpenter deployment"
  type        = bool
  default     = false
}

#### IAM Users for AWS Auth #####

variable "aws_auth_roles" {
  description = "List of IAM roles to add to the aws-auth configmap"
  type        = list(any)
  default     = []
}

# aws_auth user mapping (used for eks-admin users only)
variable "aws_auth_users" {
  default = [
    {
      userarn  = "arn:aws:iam::176523951730:user/terraform"
      username = "terraform"
      groups   = ["system:masters"]
    },
    {
      userarn  = "arn:aws:iam::176523951730:user/pramoda.sahoo"
      username = "pramoda.sahoo"
      groups   = ["system:masters"]
    },
  ]
  description = "K8S RBAC mappings for kube-system/aws_auth"
}

variable "alb_ingress_manifest_dir" {
  type        = string
  description = "Relative path to ALB manifest directory"
  default     = "alb-ingress" # just the directory name, no path.module
}

