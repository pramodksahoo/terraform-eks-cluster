data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  control_plane_subnet_ids = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.subnet_ids

  # Discovery tags. Karpenter's EC2NodeClass securityGroupSelectorTerms match on this.
  karpenter_discovery_tag = { "karpenter.sh/discovery" = var.cluster_name }

  tags = merge(var.tags, {
    "eks.cluster.name"             = var.cluster_name
    "app.kubernetes.io/managed-by" = "terraform"
  })

  ###########################################################################
  # Add-ons
  #
  # Installed as EKS managed add-ons rather than Helm charts so that AWS owns
  # version compatibility with the control plane.
  ###########################################################################

  base_addons = {
    # Must be installed before any node joins, otherwise nodes come up without
    # a CNI and sit NotReady.
    vpc-cni = {
      most_recent          = true
      before_compute       = true
      configuration_values = jsonencode(var.vpc_cni_configuration)
    }

    kube-proxy = {
      most_recent = true
    }

    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = var.coredns_replica_count
        # CoreDNS must be able to run on the tainted system node group.
        tolerations = [
          {
            key      = "CriticalAddonsOnly"
            operator = "Exists"
          },
        ]
        resources = {
          limits   = { memory = "256Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
        # Spread replicas across AZs so a zonal failure never takes out DNS.
        podDisruptionBudget = { maxUnavailable = 1 }
      })
    }

    # Brokers IAM credentials to pods via EKS Pod Identity. Required by every
    # Pod Identity association this module creates.
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }

    aws-ebs-csi-driver = {
      most_recent = true
    }

    metrics-server = {
      most_recent = true
    }
  }

  optional_addons = merge(
    var.enable_efs_csi_driver ? { aws-efs-csi-driver = { most_recent = true } } : {},
    var.enable_mountpoint_s3_csi_driver ? { aws-mountpoint-s3-csi-driver = { most_recent = true } } : {},
  )

  addons = merge(local.base_addons, local.optional_addons, var.additional_addons)
}

###############################################################################
# Guard rails
###############################################################################

check "public_endpoint_is_restricted" {
  assert {
    condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
    error_message = "endpoint_public_access is true but endpoint_public_access_cidrs is empty, which would expose the Kubernetes API to the internet."
  }
}

check "karpenter_has_somewhere_to_run" {
  assert {
    condition     = !var.enable_karpenter || var.create_system_node_group || length(var.self_managed_node_groups) > 0
    error_message = "Karpenter is enabled but no node group exists. Karpenter cannot provision the nodes it runs on, so at least one self-managed node group is required to carry the baseline."
  }
}

check "bottlerocket_ami_is_pinned" {
  assert {
    condition     = var.bottlerocket_version != "latest"
    error_message = "bottlerocket_version is 'latest', so every apply may silently replace all baseline nodes when AWS publishes a new AMI. Pin an explicit version."
  }
}

###############################################################################
# EKS cluster
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = local.control_plane_subnet_ids

  # --- API endpoint -------------------------------------------------------
  endpoint_private_access      = var.endpoint_private_access
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null

  ip_family         = var.ip_family
  service_ipv4_cidr = var.service_ipv4_cidr != "" ? var.service_ipv4_cidr : null

  # --- Audit logging ------------------------------------------------------
  enabled_log_types                      = var.enabled_log_types
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
  cloudwatch_log_group_kms_key_id        = var.cloudwatch_log_group_kms_key_id != "" ? var.cloudwatch_log_group_kms_key_id : null

  # --- Secrets envelope encryption ---------------------------------------
  # The module can create its own key, but a key managed here is easier to grant
  # cross-account access to and survives cluster replacement.
  create_kms_key = false
  encryption_config = var.enable_secrets_encryption ? {
    provider_key_arn = local.secrets_kms_key_arn
    resources        = ["secrets"]
  } : null

  # --- Authentication -----------------------------------------------------
  authentication_mode                      = var.authentication_mode
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  access_entries                           = var.access_entries

  enable_irsa = var.enable_irsa

  # --- Add-ons ------------------------------------------------------------
  addons = local.addons

  # --- Node groups --------------------------------------------------------
  # Self-managed ASGs only; see node-groups.tf. There are deliberately no EKS
  # managed node groups: the ASG is fixed baseline capacity and Karpenter owns
  # everything elastic, so the managed node group API buys nothing here.
  eks_managed_node_groups  = {}
  self_managed_node_groups = local.all_node_groups

  # --- Security groups ----------------------------------------------------
  security_group_additional_rules = var.cluster_security_group_additional_rules

  node_security_group_additional_rules = merge(
    {
      # Required so the control plane can reach admission and conversion
      # webhooks (cert-manager, the LBC, Istio) running on node ports.
      ingress_cluster_webhooks = {
        description                   = "Control plane to node webhook ports"
        protocol                      = "tcp"
        from_port                     = 9443
        to_port                       = 9443
        type                          = "ingress"
        source_cluster_security_group = true
      }
      # Node-to-node traffic for overlay/service mesh and pod-to-pod calls.
      ingress_self_all = {
        description = "Node to node, all ports"
        protocol    = "-1"
        from_port   = 0
        to_port     = 0
        type        = "ingress"
        self        = true
      }
    },
    var.node_security_group_additional_rules,
  )

  # Karpenter discovers the node security group through this tag.
  node_security_group_tags = merge(
    local.karpenter_discovery_tag,
    var.node_security_group_tags,
  )

  tags = local.tags
}
