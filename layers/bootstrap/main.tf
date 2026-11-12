###############################################################################
# Bootstrap layer
#
# Everything that talks to the Kubernetes API. Split from the infrastructure
# layer so the kubernetes, helm and kubectl providers are configured from values
# that already exist in state before this apply begins.
#
# Ordering within the layer matters and is expressed with depends_on:
#
#   eks-gateway  -> installs the Gateway API and AWS LBC CRDs. The CRDs must
#                   exist before anything references a Gateway resource, and the
#                   controller decides at startup which Gateway controllers to
#                   enable by detecting them.
#   eks-addons   -> Karpenter and the platform controllers.
#   istio        -> the mesh, last, because its gateways may front Gateways
#                   created by the first module.
###############################################################################

data "terraform_remote_state" "infrastructure" {
  backend = "s3"

  config = {
    bucket   = var.infrastructure_state_bucket
    key      = var.infrastructure_state_key
    region   = coalesce(var.infrastructure_state_region, var.region)
    role_arn = var.infrastructure_state_role_arn
  }
}

locals {
  infra  = data.terraform_remote_state.infrastructure.outputs
  addons = local.infra.addons_input

  default_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "bootstrap"
      Cluster     = local.infra.cluster_name
    },
    var.tags,
  )
}

###############################################################################
# Gateway API
###############################################################################

module "gateway" {
  source = "../../modules/eks-gateway"

  count = var.enable_gateway ? 1 : 0

  cluster_name = local.infra.cluster_name
  region       = local.addons.region
  vpc_id       = local.infra.vpc_id

  gateway_api_version = var.gateway_api_version

  create_default_gateway_classes = true
  default_scheme                 = var.gateway_default_scheme
  default_certificate_arn        = var.gateway_default_certificate_arn

  enable_access_logs = var.gateway_enable_access_logs
  access_logs_bucket = var.gateway_access_logs_bucket
  access_logs_prefix = local.infra.cluster_name

  gateways = var.gateways

  node_selector = var.system_node_selector
  tolerations   = var.system_tolerations

  tags = local.default_tags
}

###############################################################################
# Platform add-ons
###############################################################################

module "addons" {
  source = "../../modules/eks-addons"

  cluster_name = local.infra.cluster_name
  region       = local.addons.region

  enable_karpenter             = var.enable_karpenter
  karpenter_queue_name         = local.infra.karpenter_queue_name
  karpenter_node_iam_role_name = local.infra.karpenter_node_iam_role_name
  karpenter_values             = try(var.addons_values.karpenter, {})

  create_default_node_pool = var.enable_karpenter
  node_pool_capacity_types = var.karpenter_node_pool_capacity_types
  node_pool_cpu_limit      = var.karpenter_node_pool_cpu_limit

  enable_cert_manager = var.enable_cert_manager
  cert_manager_values = try(var.addons_values.cert_manager, {})

  enable_external_dns         = var.enable_external_dns
  external_dns_domain_filters = var.external_dns_domain_filters
  external_dns_policy         = var.external_dns_policy
  external_dns_values         = try(var.addons_values.external_dns, {})

  enable_metrics_server = var.enable_metrics_server
  metrics_server_values = try(var.addons_values.metrics_server, {})

  enable_argocd = var.enable_argocd
  argocd_values = try(var.addons_values.argocd, {})

  enable_monitoring = var.enable_monitoring
  monitoring_values = try(var.addons_values.monitoring, {})

  critical_addons_node_selector = var.system_node_selector
  critical_addons_tolerations   = var.system_tolerations

  tags = local.default_tags

  # The gateway module installs the Gateway API CRDs. external-dns watches
  # HTTPRoute and friends and crash-loops if those kinds do not exist yet.
  depends_on = [module.gateway]
}

###############################################################################
# Istio
###############################################################################

module "istio" {
  source = "../../modules/istio"

  count = var.enable_istio ? 1 : 0

  cluster_name  = local.infra.cluster_name
  mesh_mode     = var.istio_mesh_mode
  chart_version = var.istio_chart_version
  mtls_mode     = var.istio_mtls_mode

  ambient_namespaces = var.istio_ambient_namespaces

  node_selector = var.system_node_selector
  tolerations   = var.system_tolerations

  tags = {
    environment = var.environment
    managed-by  = "terraform"
  }

  # Istio registers the `istio` GatewayClass, which needs the upstream Gateway
  # API CRDs installed by the gateway module.
  depends_on = [module.gateway, module.addons]
}
