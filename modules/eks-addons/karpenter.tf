###############################################################################
# Karpenter
#
# modules/eks creates the controller IAM role, the node IAM role and instance
# profile, the Pod Identity association and the interruption SQS queue. This
# file installs the controller workload and, optionally, a starter NodePool.
###############################################################################

locals {
  karpenter_enabled = var.enable_karpenter

  karpenter_values = merge(
    {
      replicas = var.karpenter_replicas

      settings = merge(
        {
          clusterName = var.cluster_name
        },
        # Without the interruption queue Karpenter learns about a spot reclaim
        # only when the node disappears, instead of getting the two-minute
        # warning that lets it cordon, drain and pre-provision a replacement.
        var.karpenter_queue_name == null ? {} : {
          interruptionQueue = var.karpenter_queue_name
        },
      )

      serviceAccount = {
        # Created by the chart with no IRSA annotation: credentials arrive via
        # the EKS Pod Identity association made in modules/eks.
        create = true
        name   = var.karpenter_service_account
      }

      controller = {
        resources = {
          requests = {
            cpu    = "1"
            memory = "1Gi"
          }
          limits = {
            memory = "1Gi"
          }
        }
      }

      # Spread replicas across AZs so an AZ impairment cannot take both the
      # leader and the standby.
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "topology.kubernetes.io/zone"
        whenUnsatisfiable = "DoNotSchedule"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/instance" = "karpenter"
          }
        }
      }]

      podDisruptionBudget = {
        name           = "karpenter"
        maxUnavailable = 1
      }

      priorityClassName = local.priority_class_name
    },
    local.scheduling,
    var.karpenter_values,
  )
}

###############################################################################
# CRDs
#
# The karpenter chart bundles its CRDs, but Helm only ever *creates* bundled
# CRDs — it never upgrades them. Installing the dedicated karpenter-crd chart
# instead, and telling the main chart to skip its own copies, means a version
# bump actually updates the CRD schemas. Skipping this step is the usual cause
# of a Karpenter upgrade that silently ignores new NodePool fields.
###############################################################################

resource "helm_release" "karpenter_crd" {
  count = local.karpenter_enabled ? 1 : 0

  name       = "karpenter-crd"
  repository = var.karpenter_chart_repository
  chart      = "karpenter-crd"
  version    = var.karpenter_chart_version
  namespace  = var.karpenter_namespace

  create_namespace = true
  timeout          = var.helm_timeout
  wait             = true
  atomic           = true
}

resource "helm_release" "karpenter" {
  count = local.karpenter_enabled ? 1 : 0

  name       = "karpenter"
  repository = var.karpenter_chart_repository
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = var.karpenter_namespace

  create_namespace = true
  skip_crds        = true

  values = [yamlencode(local.karpenter_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [helm_release.karpenter_crd]
}

###############################################################################
# Default provisioning configuration
###############################################################################

locals {
  create_node_pool = local.karpenter_enabled && var.create_default_node_pool

  ec2_node_class = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = merge(
      {
        role = var.karpenter_node_iam_role_name

        amiSelectorTerms = [{
          alias = var.node_pool_ami_alias
        }]

        subnetSelectorTerms = [{
          tags = coalesce(
            var.node_pool_subnet_selector_tags,
            { "karpenter.sh/discovery" = var.cluster_name },
          )
        }]

        securityGroupSelectorTerms = [{
          tags = coalesce(
            var.node_pool_security_group_selector_tags,
            { "karpenter.sh/discovery" = var.cluster_name },
          )
        }]

        blockDeviceMappings = [{
          deviceName = "/dev/xvda"
          ebs = merge(
            {
              volumeSize          = var.node_pool_volume_size
              volumeType          = "gp3"
              encrypted           = true
              deleteOnTermination = true
            },
            var.node_pool_kms_key_id == null ? {} : {
              kmsKeyID = var.node_pool_kms_key_id
            },
          )
        }]

        # Hop limit 1 means a container cannot reach IMDS through the pod
        # network, so a compromised pod cannot mint node-role credentials.
        # IMDSv2 is enforced by requiring a session token.
        metadataOptions = {
          httpEndpoint            = "enabled"
          httpProtocolIPv6        = "disabled"
          httpPutResponseHopLimit = 1
          httpTokens              = "required"
        }

        tags = merge(var.tags, {
          "karpenter.sh/discovery" = var.cluster_name
        })
      },
    )
  }

  node_pool = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.node_pool_capacity_types
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.node_pool_instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = [tostring(var.node_pool_instance_generations - 1)]
            },
          ]

          # Bounded node lifetime: nodes are replaced on a schedule, which is
          # what actually delivers AMI patches to the data plane.
          expireAfter = var.node_pool_expire_after
        }
      }

      # Hard ceiling on how much compute this pool can create.
      limits = {
        cpu = tostring(var.node_pool_cpu_limit)
      }

      disruption = {
        consolidationPolicy = var.node_pool_consolidation_policy
        consolidateAfter    = "1m"
        budgets             = var.node_pool_disruption_budgets
      }
    }
  }
}

resource "kubectl_manifest" "ec2_node_class" {
  count = local.create_node_pool ? 1 : 0

  yaml_body = yamlencode(local.ec2_node_class)

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool" {
  count = local.create_node_pool ? 1 : 0

  yaml_body = yamlencode(local.node_pool)

  server_side_apply = true
  wait              = true

  # The NodePool references the EC2NodeClass by name; applying it first leaves
  # the pool permanently NotReady.
  depends_on = [kubectl_manifest.ec2_node_class]
}
