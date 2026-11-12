###############################################################################
# AWS Load Balancer Controller
#
# Provides two things at once:
#   - the Gateway API implementation (gateway.k8s.aws/alb and /nlb), which is
#     the supported replacement for the retired ingress-nginx controller, and
#   - the classic Ingress and Service type=LoadBalancer implementations, so
#     existing workloads keep working during a migration.
#
# Credentials come from an EKS Pod Identity association created in modules/eks.
###############################################################################

locals {
  controller_values = merge(
    {
      clusterName = var.cluster_name
      region      = var.region
      vpcId       = var.vpc_id

      replicaCount = var.replica_count

      serviceAccount = {
        # Created by this module, not the chart, so the chart can never attach
        # an IRSA role-arn annotation. An IRSA annotation takes precedence over
        # Pod Identity and would point the controller at a role that does not
        # exist.
        create = false
        name   = var.service_account_name
      }

      enableShield = var.enable_waf
      enableWaf    = var.enable_waf
      enableWafv2  = var.enable_waf

      # Tags stamped onto every load balancer, target group and security group
      # the controller creates. Without them these resources are effectively
      # unattributable in a cost report.
      defaultTags = merge(var.tags, {
        "elbv2.k8s.aws/cluster" = var.cluster_name
      })

      controllerConfig = {
        # These gates default to true in 3.6.x and the controller enables each
        # Gateway controller when it detects the matching CRDs. Setting them
        # explicitly documents the intent and keeps behaviour stable if the
        # defaults ever change.
        featureGates = {
          ALBGatewayAPI = true
          NLBGatewayAPI = true
        }
      }

      podDisruptionBudget = {
        maxUnavailable = 1
      }

      priorityClassName = "system-cluster-critical"

      # Spread replicas across AZs so an AZ impairment cannot take out both the
      # leader and the standby at once.
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "topology.kubernetes.io/zone"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/name" = "aws-load-balancer-controller"
          }
        }
      }]

      nodeSelector = var.node_selector
      tolerations  = var.tolerations

      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          memory = "256Mi"
        }
      }
    },
    var.controller_values,
  )
}

resource "kubernetes_service_account_v1" "controller" {
  metadata {
    name      = var.service_account_name
    namespace = var.namespace

    labels = {
      "app.kubernetes.io/name"       = "aws-load-balancer-controller"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # No eks.amazonaws.com/role-arn annotation: credentials are delivered by the
  # EKS Pod Identity agent against the association created in modules/eks.
}

resource "helm_release" "controller" {
  name       = "aws-load-balancer-controller"
  repository = var.chart_repository
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode(local.controller_values)]

  # CRDs are managed explicitly in crds.tf so that upgrades actually apply.
  skip_crds = true

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [
    kubectl_manifest.crds,
    kubernetes_service_account_v1.controller,
  ]
}
