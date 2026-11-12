###############################################################################
# cert-manager
#
# Pod Identity supplies the Route 53 permissions for DNS-01 solving; the chart
# must therefore create a service account with the exact name associated in
# modules/eks, and must NOT carry an IRSA role-arn annotation.
###############################################################################

locals {
  cert_manager_values = merge(
    {
      # `crds.enabled` is the current key. `installCRDs` is deprecated and will
      # be removed; using it on a recent chart silently installs nothing.
      crds = {
        enabled = true
        keep    = true
      }

      replicaCount      = 2
      priorityClassName = local.priority_class_name

      serviceAccount = {
        create = true
        name   = "cert-manager"
      }

      # cert-manager resolves ACME challenges against public DNS. Inside a VPC
      # with private hosted zones the in-cluster resolver would answer with the
      # private record and the self-check would never pass.
      dns01RecursiveNameservers     = "1.1.1.1:53,8.8.8.8:53"
      dns01RecursiveNameserversOnly = true

      webhook    = local.scheduling
      cainjector = merge(local.scheduling, { replicaCount = 2 })

      prometheus = {
        enabled = var.enable_monitoring
        servicemonitor = {
          enabled = var.enable_monitoring
        }
      }
    },
    local.scheduling,
    var.cert_manager_enable_gateway_api ? {
      config = {
        apiVersion       = "controller.config.cert-manager.io/v1alpha1"
        kind             = "ControllerConfiguration"
        enableGatewayAPI = true
      }
    } : {},
    var.cert_manager_values,
  )
}

resource "helm_release" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_chart_version
  namespace  = var.cert_manager_namespace

  create_namespace = true

  values = [yamlencode(local.cert_manager_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true
}

###############################################################################
# external-dns
###############################################################################

locals {
  external_dns_values = merge(
    {
      provider = {
        name = "aws"
      }

      # Required by the chart — it has no default, and omitting it fails the
      # render rather than picking something safe.
      policy = var.external_dns_policy

      sources = var.external_dns_sources

      # Without a domain filter the controller acts on every zone its IAM role
      # can see, which is how one cluster deletes another cluster's records.
      domainFilters = var.external_dns_domain_filters

      # TXT registry ownership records keyed by cluster, so two clusters sharing
      # a zone cannot fight over the same record.
      registry   = "txt"
      txtOwnerId = var.cluster_name
      txtPrefix  = "extdns-${var.cluster_name}-"

      extraArgs = [
        "--aws-zone-type=public",
      ]

      env = [{
        name  = "AWS_REGION"
        value = var.region
      }]

      serviceAccount = {
        create = true
        name   = "external-dns"
      }

      priorityClassName = local.priority_class_name

      serviceMonitor = {
        enabled = var.enable_monitoring
      }
    },
    local.scheduling,
    var.external_dns_values,
  )
}

resource "helm_release" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = var.external_dns_namespace

  create_namespace = true

  values = [yamlencode(local.external_dns_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true
}

###############################################################################
# metrics-server
###############################################################################

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  values = [yamlencode(merge(
    {
      replicas          = 2
      priorityClassName = local.priority_class_name

      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      }

      args = [
        # EKS serves kubelet certificates signed by the cluster CA, so the
        # insecure-tls workaround commonly copied from generic guides is not
        # needed and would weaken the connection for no reason.
        "--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP",
      ]

      resources = {
        requests = {
          cpu    = "100m"
          memory = "200Mi"
        }
      }
    },
    local.scheduling,
    var.metrics_server_values,
  ))]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true
}

###############################################################################
# Argo CD
###############################################################################

resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = var.argocd_namespace

  create_namespace = true

  values = [yamlencode(merge(
    {
      global = local.scheduling

      configs = {
        params = {
          # TLS is terminated on the ALB with an ACM certificate, so the server
          # itself serves plain HTTP inside the cluster. Running TLS on both
          # ends without this flag produces a redirect loop.
          "server.insecure" = true
        }
      }

      controller = {
        replicas = 1
        metrics = {
          enabled        = var.enable_monitoring
          serviceMonitor = { enabled = var.enable_monitoring }
        }
      }

      repoServer = {
        replicas = 2
      }

      server = {
        replicas = 2
      }

      applicationSet = {
        replicas = 2
      }

      "redis-ha" = {
        enabled = false
      }
    },
    var.argocd_values,
  ))]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true
}

###############################################################################
# kube-prometheus-stack
###############################################################################

resource "helm_release" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.monitoring_chart_version
  namespace  = var.monitoring_namespace

  create_namespace = true

  values = [yamlencode(merge(
    {
      prometheus = {
        prometheusSpec = merge(
          {
            retention = var.monitoring_retention

            # Discover ServiceMonitors and PodMonitors from every namespace.
            # The chart defaults to only those carrying its own release label,
            # which quietly drops monitors created by other charts.
            serviceMonitorSelectorNilUsesHelmValues = false
            podMonitorSelectorNilUsesHelmValues     = false
            ruleSelectorNilUsesHelmValues           = false

            storageSpec = {
              volumeClaimTemplate = {
                spec = {
                  storageClassName = var.monitoring_storage_class
                  accessModes      = ["ReadWriteOnce"]
                  resources = {
                    requests = {
                      storage = var.monitoring_storage_size
                    }
                  }
                }
              }
            }
          },
          local.scheduling,
        )
      }

      alertmanager = {
        alertmanagerSpec = local.scheduling
      }

      grafana = merge(
        {
          # No password is set here on purpose: anything passed to the chart
          # from Terraform is stored in plaintext in state. The chart generates
          # a random one into a Secret; read it once and then move to SSO.
          defaultDashboardsEnabled = true
          persistence = {
            enabled          = true
            storageClassName = var.monitoring_storage_class
            size             = "10Gi"
          }
        },
        local.scheduling,
      )

      prometheusOperator   = local.scheduling
      "kube-state-metrics" = local.scheduling

      # The EKS control plane is managed by AWS and does not expose these
      # components, so the stack's default scrape targets for them would alert
      # permanently.
      kubeEtcd              = { enabled = false }
      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeProxy             = { enabled = false }
    },
    var.monitoring_values,
  ))]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true
}
