###############################################################################
# Node groups
#
# Compute is deliberately split in two:
#
#   Self-managed ASG   Fixed baseline. On-demand, Bottlerocket, pinned AMI.
#                      Hosts only cluster-critical controllers. Never scaled by
#                      anything — not Cluster Autoscaler, not Karpenter.
#
#   Karpenter          Everything elastic. Spot and on-demand, instance types
#                      chosen per pod, consolidated continuously.
#
# Cluster Autoscaler is NOT used and no CA discovery tags are applied to the
# ASG. Two controllers both deciding the size of the same ASG is a well-known
# way to get thrash and orphaned nodes.
###############################################################################

locals {
  is_bottlerocket = startswith(var.ami_type, "BOTTLEROCKET")

  # Bottlerocket publishes AMIs per Kubernetes minor version and architecture.
  node_architecture = strcontains(var.ami_type, "ARM_64") ? "arm64" : "x86_64"

  bottlerocket_ssm_parameter = join("/", [
    "/aws/service/bottlerocket",
    "aws-k8s-${var.kubernetes_version}",
    local.node_architecture,
    var.bottlerocket_version,
    "image_id",
  ])
}

# The EKS module's own SSM lookup is hardcoded to `latest`, which would let AWS
# replace every baseline node the moment it publishes a new AMI. Resolving the
# parameter here is what makes `bottlerocket_version` an actual pin.
data "aws_ssm_parameter" "bottlerocket_ami" {
  count = local.is_bottlerocket ? 1 : 0

  name = local.bottlerocket_ssm_parameter
}

locals {
  resolved_ami_id = local.is_bottlerocket ? nonsensitive(data.aws_ssm_parameter.bottlerocket_ami[0].value) : null

  ###########################################################################
  # Bootstrap settings
  #
  # Bottlerocket is configured with TOML, not a shell script. The module
  # appends `bootstrap_extra_args` directly beneath the `[settings.kubernetes]`
  # table it renders, so anything here must open its own table.
  #
  # Labels and taints have to travel this way: self-managed nodes have no
  # `labels` or `taints` argument, because there is no EKS node group API to
  # apply them. The kubelet self-registers with them instead.
  #
  # `node.kubernetes.io/role` is safe to self-set. The NodeRestriction
  # admission plugin permits the `node.kubernetes.io` namespace; by contrast
  # `node-role.kubernetes.io/*` is rejected and would stop the kubelet
  # starting, which is why that more familiar key is not used here.
  ###########################################################################

  system_node_labels = merge(
    { "node.kubernetes.io/role" = "system" },
    var.system_node_group_labels,
  )

  system_labels_toml = join("\n", concat(
    ["[settings.kubernetes.node-labels]"],
    [for k, v in local.system_node_labels : format("%q = %q", k, v)],
  ))

  # Bottlerocket taint syntax is a list of "value:Effect" strings per key.
  system_taints_toml = var.system_node_group_taint_system_workloads ? join("\n", [
    "",
    "[settings.kubernetes.node-taints]",
    format("%q = [%q]", "CriticalAddonsOnly", "true:NoSchedule"),
  ]) : ""

  system_bootstrap_extra_args = join("\n", [
    local.system_labels_toml,
    local.system_taints_toml,
    var.bottlerocket_extra_settings,
  ])

  ###########################################################################
  # Shared defaults
  #
  # v21 removed `self_managed_node_group_defaults` along with its managed
  # equivalent, so defaults are merged into each group explicitly.
  ###########################################################################

  node_group_defaults = merge(
    {
      ami_type = var.ami_type
      ami_id   = local.resolved_ami_id

      # Bottlerocket has two volumes and both must be declared. Mapping only
      # one leaves the other at the AMI default, which means unencrypted and
      # undersized.
      #
      #   /dev/xvda  OS: A/B partition sets, bootloader, dm-verity, API store
      #   /dev/xvdb  Data: container images, writable layers, ephemeral storage
      #
      # Bottlerocket grows the data partition to fill the device at boot.
      block_device_mappings = local.is_bottlerocket ? {
        os = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_os_disk_size
            volume_type           = var.node_volume_type
            encrypted             = true
            kms_key_id            = var.node_ebs_kms_key_arn != "" ? var.node_ebs_kms_key_arn : null
            delete_on_termination = true
          }
        }
        data = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = var.node_data_disk_size
            volume_type           = var.node_volume_type
            iops                  = var.node_volume_type == "gp3" ? 3000 : null
            throughput            = var.node_volume_type == "gp3" ? 125 : null
            encrypted             = true
            kms_key_id            = var.node_ebs_kms_key_arn != "" ? var.node_ebs_kms_key_arn : null
            delete_on_termination = true
          }
        }
        } : {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_data_disk_size
            volume_type           = var.node_volume_type
            encrypted             = true
            kms_key_id            = var.node_ebs_kms_key_arn != "" ? var.node_ebs_kms_key_arn : null
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint = "enabled"
        # IMDSv1 is disabled: token-less metadata requests are the classic SSRF
        # credential-theft path.
        http_tokens = "required"
        # A hop limit of 1 means a container cannot reach IMDS through the host
        # network namespace, so pods cannot steal the node role's credentials.
        # Workload credentials come from EKS Pod Identity instead.
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      # Detailed CloudWatch monitoring: 1-minute metric resolution instead of 5.
      enable_monitoring = true

      # Replace instances when the launch template changes, which is how an AMI
      # version bump actually reaches the fleet.
      instance_refresh = {
        strategy = "Rolling"
        preferences = {
          min_healthy_percentage = 66
          instance_warmup        = 300
        }
      }

      health_check_type = "EC2"

      # Spread baseline capacity across AZs and replace an instance whose AZ
      # becomes imbalanced.
      capacity_rebalance = true

      # Registers the node role as an EC2_LINUX access entry, which is how
      # self-managed nodes join a cluster running authentication_mode = "API".
      # Without it nodes boot, pass health checks and never appear in the API.
      create_access_entry = true

      iam_role_additional_policies = merge(
        {
          # SSM Session Manager, and on Bottlerocket the only supported way to
          # reach the admin container. There is no SSH.
          AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
        },
        var.node_additional_iam_policies,
      )

      tags = local.tags
    },
    var.node_group_defaults,
  )

  ###########################################################################
  # Baseline system ASG
  ###########################################################################

  # A single instance type is one Insufficient Capacity Exception away from no
  # baseline at all, so more than one type switches on a mixed instances policy
  # pinned to 100% on-demand. Baseline capacity must never be interruptible —
  # Spot belongs to Karpenter.
  system_diversified = length(var.system_node_group_instance_types) > 1

  system_mixed_instances_policy = local.system_diversified ? {
    instances_distribution = {
      on_demand_allocation_strategy            = "prioritized"
      on_demand_base_capacity                  = var.system_node_group_min_size
      on_demand_percentage_above_base_capacity = 100
    }
    launch_template = {
      override = [
        for instance_type in var.system_node_group_instance_types : {
          instance_type = instance_type
        }
      ]
    }
  } : null

  system_node_group = var.create_system_node_group ? {
    system = {
      name = "${var.cluster_name}-system"

      instance_type              = var.system_node_group_instance_types[0]
      use_mixed_instances_policy = local.system_diversified
      mixed_instances_policy     = local.system_mixed_instances_policy

      # The ASG hardcodes `ignore_changes = [desired_capacity]`, so after
      # creation it is min_size that holds the floor. Both are set to the same
      # value; max_size is higher only to give instance refresh room to surge.
      min_size     = var.system_node_group_min_size
      max_size     = var.system_node_group_max_size
      desired_size = var.system_node_group_desired_size

      bootstrap_extra_args = local.is_bottlerocket ? local.system_bootstrap_extra_args : null

      # No Cluster Autoscaler discovery tags. This ASG is deliberately opaque
      # to any autoscaler.
      autoscaling_group_tags = var.system_node_group_autoscaling_group_tags
    }
  } : {}

  # `tags` and `iam_role_additional_policies` are merged rather than replaced so
  # a per-group override adds to the baseline instead of silently discarding it.
  all_node_groups = {
    for k, v in merge(local.system_node_group, var.self_managed_node_groups) :
    k => merge(
      local.node_group_defaults,
      v,
      {
        tags = merge(
          lookup(local.node_group_defaults, "tags", {}),
          lookup(v, "tags", {}),
        )
        iam_role_additional_policies = merge(
          lookup(local.node_group_defaults, "iam_role_additional_policies", {}),
          lookup(v, "iam_role_additional_policies", {}),
        )
      },
    )
  }
}
