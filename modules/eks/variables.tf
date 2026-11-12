###############################################################################
# Cluster identity
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the Karpenter and load-balancer discovery tag value."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-_]{0,99}$", var.cluster_name))
    error_message = "cluster_name must start with an alphanumeric character and contain only alphanumerics, hyphens and underscores (max 100 characters)."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version for the control plane, e.g. "1.37". Only versions in EKS
    standard support should be used; extended support incurs a significant per-cluster
    hourly surcharge and eventually forces an automatic upgrade.
  EOT
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.(3[4-9]|[4-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be 1.34 or newer. Older versions are in extended support or end-of-life on EKS."
  }
}

###############################################################################
# Networking inputs
#
# Supplied either by the networking module in this repo or by the consuming
# team's own VPC. The module never creates networking resources.
###############################################################################

variable "vpc_id" {
  description = "ID of the VPC the cluster is deployed into."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID, e.g. vpc-0a1b2c3d4e5f67890."
  }
}

variable "subnet_ids" {
  description = <<-EOT
    Subnet IDs for worker nodes. Must be private subnets with a route to the internet
    (NAT Gateway) or a complete set of VPC endpoints. At least two subnets in two
    different Availability Zones are required by EKS.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires at least two subnets in two different Availability Zones."
  }
}

variable "control_plane_subnet_ids" {
  description = <<-EOT
    Subnet IDs for the EKS control-plane cross-account ENIs. Defaults to `subnet_ids`
    when empty. Supplying dedicated isolated (intra) subnets keeps the control plane
    independent of NAT Gateway availability.
  EOT
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Public subnet IDs. Not used by the cluster itself; exposed as an output so the gateway module can place internet-facing load balancers."
  type        = list(string)
  default     = []
}

###############################################################################
# API endpoint access
###############################################################################

variable "endpoint_private_access" {
  description = "Enable the private Kubernetes API endpoint. Should always be true."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = <<-EOT
    Expose the Kubernetes API server publicly. Set to false for a fully private cluster
    reachable only from inside the VPC or over VPN/Direct Connect. When true you must
    supply `endpoint_public_access_cidrs`.
  EOT
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDR blocks permitted to reach the public API endpoint. Leaving this at 0.0.0.0/0
    exposes the Kubernetes API to the entire internet and is rejected by a validation
    rule below. Supply office ranges, VPN egress IPs or CI runner ranges.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted for endpoint_public_access_cidrs. Restrict access to known CIDR ranges, or set endpoint_public_access = false."
  }

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry in endpoint_public_access_cidrs must be a valid IPv4 CIDR block."
  }
}

variable "ip_family" {
  description = "IP family for the cluster: `ipv4` or `ipv6`."
  type        = string
  default     = "ipv4"

  validation {
    condition     = contains(["ipv4", "ipv6"], var.ip_family)
    error_message = "ip_family must be either 'ipv4' or 'ipv6'."
  }
}

variable "service_ipv4_cidr" {
  description = "CIDR block for Kubernetes Service IPs. Must not overlap the VPC CIDR. Leave empty for the EKS default (172.20.0.0/16)."
  type        = string
  default     = ""
}

###############################################################################
# Encryption and logging
###############################################################################

variable "enable_secrets_encryption" {
  description = <<-EOT
    Enable envelope encryption of Kubernetes Secrets with a customer-managed KMS key.
    Without this, Secrets are stored in etcd with AWS-managed encryption only.
    Required by most compliance regimes and by CIS EKS Benchmark 2.x.
  EOT
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "ARN of an existing KMS key to use for Secrets envelope encryption. Leave empty to have the module create and manage a dedicated key."
  type        = string
  default     = ""
}

variable "kms_key_deletion_window_in_days" {
  description = "Waiting period before a module-created KMS key is deleted. Deleting the key makes every Secret in the cluster permanently unreadable, so a long window is deliberate."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "kms_key_deletion_window_in_days must be between 7 and 30."
  }
}

variable "enabled_log_types" {
  description = <<-EOT
    Control-plane log types shipped to CloudWatch Logs. `audit` and `authenticator` are
    the two that matter for security investigations; omitting them leaves no record of
    who did what in the cluster.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition = alltrue([
      for t in var.enabled_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "enabled_log_types entries must be one of: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention for the control-plane CloudWatch log group."
  type        = number
  default     = 90
}

variable "cloudwatch_log_group_kms_key_id" {
  description = "KMS key ARN used to encrypt the control-plane log group. Leave empty for the AWS-managed CloudWatch Logs key."
  type        = string
  default     = ""
}

###############################################################################
# Authentication and authorisation
###############################################################################

variable "authentication_mode" {
  description = <<-EOT
    Cluster authentication mode. `API` uses EKS Access Entries exclusively and is the
    recommended setting; the aws-auth ConfigMap is not created at all.
    `API_AND_CONFIG_MAP` is provided only to support migrating an existing cluster.

    WARNING: moving from CONFIG_MAP towards API is one-way. You cannot move back.
  EOT
  type        = string
  default     = "API"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be 'API' or 'API_AND_CONFIG_MAP'. The deprecated 'CONFIG_MAP' mode is not supported by this module."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = <<-EOT
    Grant cluster-admin to the IAM principal that runs `terraform apply`. Convenient for
    bootstrapping but means the CI role is a permanent cluster admin. Prefer false in
    production and grant access explicitly through `access_entries`.
  EOT
  type        = bool
  default     = false
}

variable "access_entries" {
  description = <<-EOT
    EKS Access Entries, keyed by a friendly name. This replaces the deprecated aws-auth
    ConfigMap. Map IAM roles (ideally SSO permission-set roles) to EKS access policies.

    Example:
    ```
    access_entries = {
      platform_admins = {
        principal_arn = "arn:aws:iam::111122223333:role/AWSReservedSSO_PlatformAdmin_abc"
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
      app_team_a = {
        principal_arn = "arn:aws:iam::111122223333:role/AppTeamA"
        policy_associations = {
          edit = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace", namespaces = ["team-a"] }
          }
        }
      }
    }
    ```
  EOT
  type        = any
  default     = {}
}

###############################################################################
# Node groups
###############################################################################

variable "self_managed_node_groups" {
  description = <<-EOT
    Additional self-managed node group (ASG) definitions, keyed by name. Merged over
    `node_group_defaults`. The baseline system ASG is created separately and does not
    need to be listed here.

    These become `self_managed_node_groups` on the upstream EKS module, whose type is
    strongly typed: an unrecognised key is a hard error, not a silent no-op. Note
    `instance_type` is singular; use `use_mixed_instances_policy` for several types.

    There is no `labels` or `taints` argument, because there is no EKS node group API
    to apply them. Pass them as Bottlerocket TOML in `bootstrap_extra_args`.

    Example:
    ```
    self_managed_node_groups = {
      memory = {
        instance_type = "r7i.xlarge"
        min_size      = 2
        max_size      = 4
        desired_size  = 2

        bootstrap_extra_args = <<-TOML
          [settings.kubernetes.node-labels]
          "workload-class" = "memory"
        TOML
      }
    }
    ```
  EOT
  type        = any
  default     = {}
}

variable "create_system_node_group" {
  description = <<-EOT
    Create the baseline self-managed ASG that hosts cluster-critical controllers
    (CoreDNS, Karpenter, the load balancer controller).

    Karpenter cannot provision the nodes it runs on, so this ASG is the bootstrap
    floor for the whole cluster. Disable it only if you are supplying an equivalent
    group through `self_managed_node_groups`.
  EOT
  type        = bool
  default     = true
}

variable "system_node_group_instance_types" {
  description = <<-EOT
    Instance types for the baseline system ASG, in order of preference. Keep them
    small; only controllers run here.

    Listing more than one enables a mixed instances policy pinned to 100% on-demand,
    so a single Insufficient Capacity Exception cannot leave the cluster with no
    baseline. Spot is never used for baseline capacity — that is Karpenter's job.
  EOT
  type        = list(string)
  default     = ["m7i.large", "m7a.large", "m6i.large"]

  validation {
    condition     = length(var.system_node_group_instance_types) > 0
    error_message = "At least one instance type is required for the system node group."
  }
}

variable "system_node_group_min_size" {
  description = <<-EOT
    Minimum size of the baseline ASG, and in practice its steady-state size.

    The upstream module hardcodes `ignore_changes = [desired_capacity]` on the ASG,
    so after creation this value is what actually holds the floor. Two is the minimum
    for a highly available controller layout.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_group_min_size >= 2
    error_message = "A baseline of fewer than two nodes leaves cluster-critical controllers with no redundancy."
  }
}

variable "system_node_group_max_size" {
  description = <<-EOT
    Maximum size of the baseline ASG. Nothing scales this group, so the only reason
    to set it above `min_size` is to give instance refresh room to surge during an
    AMI roll. Twice the minimum is a reasonable default.
  EOT
  type        = number
  default     = 4
}

variable "system_node_group_desired_size" {
  description = <<-EOT
    Desired size of the baseline ASG at creation time. Ignored on subsequent applies
    because the upstream ASG ignores `desired_capacity`; change `min_size` instead.
  EOT
  type        = number
  default     = 2
}

variable "system_node_group_taint_system_workloads" {
  description = <<-EOT
    Apply the `CriticalAddonsOnly=true:NoSchedule` taint to the baseline ASG so that
    application pods are forced onto Karpenter-managed capacity. Add-ons installed by
    the eks-addons, eks-gateway and istio modules tolerate this taint automatically.
  EOT
  type        = bool
  default     = true
}

variable "system_node_group_labels" {
  description = <<-EOT
    Extra Kubernetes node labels for the baseline ASG, merged over the default
    `node.kubernetes.io/role = system`.

    These are self-set by the kubelet at registration, so the NodeRestriction
    admission plugin applies: a key in the `kubernetes.io` or `k8s.io` namespaces
    that is not explicitly allowed (`node-role.kubernetes.io/*`, for instance) will
    stop the kubelet starting. Unprefixed keys are always safe.
  EOT
  type        = map(string)
  default     = {}
}

variable "system_node_group_autoscaling_group_tags" {
  description = <<-EOT
    Extra tags applied to the baseline ASG itself, not propagated to instances.

    Do not add Cluster Autoscaler discovery tags (`k8s.io/cluster-autoscaler/*`).
    This ASG is fixed baseline capacity and Karpenter owns elastic scaling; two
    controllers resizing one ASG produces thrash and orphaned nodes.
  EOT
  type        = map(string)
  default     = {}
}

variable "node_group_defaults" {
  description = "Defaults merged into every self-managed node group, including the baseline system ASG. Overridden by per-group settings."
  type        = any
  default     = {}
}

variable "node_os_disk_size" {
  description = <<-EOT
    Size in GiB of the Bottlerocket OS volume (`/dev/xvda`), which holds the A/B
    partition sets, bootloader, dm-verity hash tree and API datastore. Container data
    does not live here, so this rarely needs enlarging.
  EOT
  type        = number
  default     = 10
}

variable "node_data_disk_size" {
  description = <<-EOT
    Size in GiB of the Bottlerocket data volume (`/dev/xvdb`), which holds container
    images, writable layers and ephemeral storage. Size this against your image
    footprint; Bottlerocket grows the partition to fill the device at boot.

    On a non-Bottlerocket AMI this sizes the single root volume instead.
  EOT
  type        = number
  default     = 100
}

variable "node_volume_type" {
  description = "EBS volume type for node volumes. gp3 is cheaper and faster than gp2 and should always be preferred."
  type        = string
  default     = "gp3"
}

variable "node_ebs_kms_key_arn" {
  description = <<-EOT
    KMS key ARN for node volume encryption. Leave empty to use the AWS-managed EBS
    key. Volumes are always encrypted.

    A customer-managed key must grant the Auto Scaling service-linked role
    `kms:CreateGrant` and `kms:GenerateDataKeyWithoutPlaintext`, or instances fail to
    launch with an opaque client error.
  EOT
  type        = string
  default     = ""
}

variable "ami_type" {
  description = <<-EOT
    AMI family for the self-managed node groups.

    Bottlerocket is the default and the only family this module generates bootstrap
    settings for: it is a minimal, immutable, container-only OS with no shell and no
    package manager, which is a materially smaller attack surface than a general
    purpose distribution.

    Node labels and taints are rendered as Bottlerocket TOML, so a non-Bottlerocket
    value means you must supply your own `bootstrap_extra_args` or
    `cloudinit_pre_nodeadm` per group.
  EOT
  type        = string
  default     = "BOTTLEROCKET_x86_64"

  validation {
    condition = contains([
      "BOTTLEROCKET_x86_64",
      "BOTTLEROCKET_ARM_64",
      "BOTTLEROCKET_x86_64_NVIDIA",
      "BOTTLEROCKET_ARM_64_NVIDIA",
      "BOTTLEROCKET_x86_64_FIPS",
      "BOTTLEROCKET_ARM_64_FIPS",
      "AL2023_x86_64_STANDARD",
      "AL2023_ARM_64_STANDARD",
      "AL2023_x86_64_NEURON",
      "AL2023_x86_64_NVIDIA",
    ], var.ami_type)
    error_message = "ami_type must be a Bottlerocket or AL2023 variant. AL2 is end-of-life on EKS."
  }
}

variable "bottlerocket_version" {
  description = <<-EOT
    Bottlerocket OS version to pin the baseline AMI to, resolved through the SSM
    public parameter:

      /aws/service/bottlerocket/aws-k8s-<kubernetes_version>/<arch>/<version>/image_id

    A bare semver with no leading `v`. `latest` is accepted but tripped by a `check`
    block: with `latest`, AWS publishing a new AMI silently rolls every baseline node
    on the next apply, at a time you did not choose.

    Verify a version resolves before pinning it:

    ```
    aws ssm get-parameter --region eu-central-1 \
      --name /aws/service/bottlerocket/aws-k8s-1.37/x86_64/1.68.1/image_id
    ```
  EOT
  type        = string
  default     = "1.68.1"

  validation {
    condition     = var.bottlerocket_version == "latest" || can(regex("^\\d+\\.\\d+\\.\\d+$", var.bottlerocket_version))
    error_message = "bottlerocket_version must be a bare semver such as '1.68.1' (no leading 'v'), or 'latest'."
  }
}

variable "bottlerocket_extra_settings" {
  description = <<-EOT
    Additional Bottlerocket TOML appended to the baseline ASG's user data. Each entry
    must open its own table, because the module renders this directly beneath the
    `[settings.kubernetes]` table it generates.

    Example, for VPC CNI prefix delegation:
    ```
    bottlerocket_extra_settings = <<-TOML
      [settings.kubernetes]
      max-pods = 110
    TOML
    ```
  EOT
  type        = string
  default     = ""
}

variable "node_additional_iam_policies" {
  description = <<-EOT
    Extra IAM policy ARNs attached to the node role, keyed by a friendly name.

    Do not grant broad data-plane permissions here. Anything a specific workload needs
    must be granted with EKS Pod Identity so it is scoped to that one service account,
    not to every pod on the node.
  EOT
  type        = map(string)
  default     = {}
}

###############################################################################
# Security groups
###############################################################################

variable "cluster_security_group_additional_rules" {
  description = "Additional rules added to the cluster (control plane) security group."
  type        = any
  default     = {}
}

variable "node_security_group_additional_rules" {
  description = "Additional rules added to the shared node security group."
  type        = any
  default     = {}
}

variable "node_security_group_tags" {
  description = "Extra tags for the node security group. The Karpenter discovery tag is added automatically."
  type        = map(string)
  default     = {}
}

###############################################################################
# Add-ons
###############################################################################

variable "enable_efs_csi_driver" {
  description = "Install the EFS CSI driver add-on. Only needed when workloads require ReadWriteMany volumes."
  type        = bool
  default     = false
}

variable "enable_mountpoint_s3_csi_driver" {
  description = "Install the Mountpoint for Amazon S3 CSI driver add-on."
  type        = bool
  default     = false
}

variable "vpc_cni_configuration" {
  description = <<-EOT
    Configuration passed to the vpc-cni add-on. Prefix delegation is enabled by default
    because it raises the pod-per-node density ceiling substantially and reduces ENI
    churn. Network policy support is enabled so Kubernetes NetworkPolicy objects are
    actually enforced.
  EOT
  type        = any
  default = {
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
      ENABLE_POD_ENI           = "false"
      AWS_VPC_K8S_CNI_LOGLEVEL = "INFO"
    }
    enableNetworkPolicy = "true"
  }
}

variable "coredns_replica_count" {
  description = "Number of CoreDNS replicas. Two is the minimum for availability during node rotation."
  type        = number
  default     = 2
}

variable "additional_addons" {
  description = "Extra EKS add-ons to install, keyed by add-on name. Merged over the module's baseline add-on set."
  type        = any
  default     = {}
}

###############################################################################
# Karpenter
###############################################################################

variable "enable_karpenter" {
  description = <<-EOT
    Provision the AWS-side resources Karpenter needs: the node IAM role and its access
    entry, the controller IAM role with a Pod Identity association, the SQS interruption
    queue and the EventBridge rules that feed it.

    The Karpenter controller itself is installed by the eks-addons module via Helm.
  EOT
  type        = bool
  default     = true
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in. Must match the eks-addons module."
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Service account name used by the Karpenter controller."
  type        = string
  default     = "karpenter"
}

###############################################################################
# Pod Identity roles for platform add-ons
###############################################################################

variable "enable_pod_identity_roles" {
  description = <<-EOT
    Create EKS Pod Identity roles and associations for the platform add-ons installed by
    the eks-gateway and eks-addons modules: the AWS Load Balancer Controller, cert-manager,
    external-dns and the EBS/EFS CSI drivers.

    Pod Identity is preferred over IRSA: no OIDC provider trust to manage, roles are
    reusable across clusters, and credentials are brokered per pod rather than per node.
  EOT
  type        = bool
  default     = true
}

variable "external_dns_hosted_zone_arns" {
  description = "Route 53 hosted zone ARNs external-dns may modify. Defaults to all zones in the account, which should be narrowed in production."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "cert_manager_hosted_zone_arns" {
  description = "Route 53 hosted zone ARNs cert-manager may use for DNS-01 ACME challenges."
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

###############################################################################
# IRSA
###############################################################################

variable "enable_irsa" {
  description = <<-EOT
    Create the IAM OIDC provider for the cluster. Pod Identity is the preferred
    mechanism, but IRSA remains necessary for third-party controllers that do not yet
    support Pod Identity, and for cross-account role assumption from pods.
  EOT
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
