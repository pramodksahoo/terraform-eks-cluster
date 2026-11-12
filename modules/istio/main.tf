###############################################################################
# Istio service mesh
#
# Install order is load-bearing and enforced with depends_on:
#
#   base     - CRDs and cluster-wide RBAC. Nothing else can apply until the CRDs
#              are registered.
#   istiod   - the control plane. Validating/mutating webhooks come up here.
#   cni      - node agent that sets up traffic redirection. Must exist before any
#              ambient workload is enrolled, otherwise traffic silently bypasses
#              the mesh.
#   ztunnel  - the ambient L4 data plane. Ambient mode only.
#   gateway  - optional ingress/egress gateway deployments.
#
# Every chart is pinned to the same version: Istio does not support running
# mismatched minor versions across its own components.
###############################################################################

locals {
  mesh_id = coalesce(var.mesh_id, var.cluster_name)

  is_ambient = var.mesh_mode == "ambient"

  # Ambient mode is not optional about the CNI agent: without it nothing performs
  # the redirection into ztunnel and enrolled pods would run outside the mesh
  # while appearing healthy.
  cni_enabled = var.enable_cni || local.is_ambient

  # The `profile` value switches the chart's own defaults over to the ambient
  # variants (ztunnel-aware istiod config, ambient-capable CNI). It is the
  # documented ambient installation path.
  profile_values = local.is_ambient ? { profile = "ambient" } : {}

  revision_values = var.revision == null ? {} : { revision = var.revision }

  scheduling_values = {
    nodeSelector = var.node_selector
    tolerations  = var.tolerations
  }

  # Mesh-wide settings shared by istiod. Kept separate so the merge order with
  # caller-supplied values stays obvious.
  mesh_config = {
    meshConfig = merge(
      {
        trustDomain = var.trust_domain
        defaultConfig = {
          proxyMetadata = {}
        }
        outboundTrafficPolicy = {
          mode = var.outbound_traffic_policy
        }
      },
      var.enable_access_logging ? {
        accessLogFile     = "/dev/stdout"
        accessLogEncoding = "JSON"
      } : {},
    )
  }

  base_values = merge(
    {
      global = {
        istioNamespace = var.namespace
      }
      # Point the `default` revision tag at this install so namespaces labelled
      # istio-injection=enabled resolve to it.
      defaultRevision = coalesce(var.revision, "default")
    },
    local.revision_values,
    var.base_values,
  )

  istiod_values = merge(
    local.profile_values,
    local.revision_values,
    {
      global = {
        istioNamespace = var.namespace
        meshID         = local.mesh_id
        network        = var.network
        multiCluster = {
          clusterName = var.cluster_name
        }
      }
      pilot = merge(
        local.scheduling_values,
        {
          replicaCount = var.istiod_replicas
          podDisruptionBudget = var.enable_pod_disruption_budget ? {
            minAvailable = 1
          } : {}
        },
      )
    },
    local.mesh_config,
    var.istiod_values,
  )

  cni_values = merge(
    local.profile_values,
    {
      global = {
        istioNamespace = var.namespace
      }
      cni = merge(
        local.scheduling_values,
        {
          # Run the agent on every node including tainted ones: a node without the
          # agent cannot carry mesh traffic correctly.
          ambient = {
            enabled = local.is_ambient
          }
        },
      )
    },
    var.cni_values,
  )

  ztunnel_values = merge(
    {
      istioNamespace = var.namespace
      multiCluster = {
        clusterName = var.cluster_name
      }
      network = var.network
    },
    var.ztunnel_values,
  )

  release_labels = {
    for k, v in var.tags : k => v
  }
}

###############################################################################
# Namespace
###############################################################################

resource "kubernetes_namespace_v1" "istio_system" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace

    labels = merge(
      local.release_labels,
      {
        "app.kubernetes.io/managed-by" = "terraform"
        # Excluded from ambient enrolment: the control plane must not be captured
        # by its own data plane.
        "istio.io/dataplane-mode" = "none"
      },
    )
  }
}

###############################################################################
# Charts
###############################################################################

resource "helm_release" "base" {
  name       = "istio-base"
  repository = var.chart_repository
  chart      = "base"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode(local.base_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  skip_crds    = false
  reset_values = true

  depends_on = [kubernetes_namespace_v1.istio_system]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = var.chart_repository
  chart      = "istiod"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode(local.istiod_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [helm_release.base]
}

resource "helm_release" "cni" {
  count = local.cni_enabled ? 1 : 0

  name       = "istio-cni"
  repository = var.chart_repository
  chart      = "cni"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode(local.cni_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [helm_release.istiod]
}

resource "helm_release" "ztunnel" {
  count = local.is_ambient ? 1 : 0

  name       = "ztunnel"
  repository = var.chart_repository
  chart      = "ztunnel"
  version    = var.chart_version
  namespace  = var.namespace

  values = [yamlencode(local.ztunnel_values)]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [helm_release.cni]
}

###############################################################################
# Gateways
###############################################################################

resource "helm_release" "gateway" {
  for_each = var.gateways

  name       = each.key
  repository = var.chart_repository
  chart      = "gateway"
  version    = var.chart_version
  namespace  = coalesce(each.value.namespace, var.namespace)

  values = [yamlencode(merge(
    {
      service = {
        type        = each.value.service_type
        annotations = each.value.annotations
      }
      labels = merge(local.release_labels, each.value.labels)
    },
    local.scheduling_values,
    local.revision_values,
    each.value.values,
  ))]

  timeout      = var.helm_timeout
  wait         = true
  atomic       = true
  reset_values = true

  depends_on = [helm_release.istiod]
}

###############################################################################
# Ambient namespace enrolment
#
# kubernetes_labels patches an existing namespace through server-side apply
# without taking ownership of the whole object, so namespaces created by an
# application pipeline can still be enrolled from here.
###############################################################################

resource "kubernetes_labels" "ambient" {
  for_each = local.is_ambient ? toset(var.ambient_namespaces) : toset([])

  api_version   = "v1"
  kind          = "Namespace"
  field_manager = "terraform-istio-module"
  force         = true

  metadata {
    name = each.value
  }

  labels = {
    "istio.io/dataplane-mode" = "ambient"
  }

  depends_on = [helm_release.ztunnel]
}

###############################################################################
# Mesh-wide mTLS
#
# In ambient mode ztunnel already enforces mTLS between enrolled workloads, but
# an explicit PeerAuthentication is still what rejects plaintext from outside
# the mesh, so it is applied in both modes.
###############################################################################

resource "kubectl_manifest" "mesh_mtls" {
  count = var.mtls_mode == null ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "default"
      namespace = var.namespace
      labels    = local.release_labels
    }
    spec = {
      mtls = {
        mode = var.mtls_mode
      }
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.istiod]
}
