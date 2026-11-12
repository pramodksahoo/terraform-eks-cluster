###############################################################################
# CRDs
#
# Three sets of CRDs are needed before the controller can serve Gateway API:
#
#   1. Upstream Gateway API  (gateway.networking.k8s.io) - Gateway, GatewayClass,
#      HTTPRoute, GRPCRoute, TCPRoute, UDPRoute, TLSRoute.
#   2. Controller CRDs       (elbv2.k8s.aws)             - TargetGroupBinding,
#      IngressClassParams and friends.
#   3. Controller Gateway CRDs (gateway.k8s.aws)         - LoadBalancerConfiguration,
#      TargetGroupConfiguration, ListenerRuleConfiguration.
#
# They are applied as first-class resources rather than being left to Helm.
# Helm only ever *creates* a chart's bundled CRDs; it never upgrades them, so a
# chart version bump would leave stale schemas behind and newly added fields
# would be accepted and silently discarded.
#
# The controller decides at startup which Gateway controllers to enable by
# detecting the CRDs. If the chart were installed first, the controllers would
# stay switched off until the pod happened to restart — hence the explicit
# dependency from the release onto these resources.
###############################################################################

locals {
  # Immutable, tag-pinned URLs. Deliberately never a branch ref: a `main` URL
  # changes content with no version bump and no Terraform diff, which is both a
  # reproducibility problem and a supply-chain one.
  default_crd_urls = [
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/${var.gateway_api_channel}-install.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${var.chart_version}/config/crd/gateway/gateway-crds.yaml",
  ]

  crd_urls = var.manage_crds ? coalesce(var.crd_manifest_urls, local.default_crd_urls) : []
}

data "http" "crds" {
  for_each = toset(local.crd_urls)

  url = each.value

  request_headers = {
    Accept = "text/yaml, application/yaml, text/plain"
  }

  # Fail loudly on a 404 or a proxy error page rather than feeding HTML into
  # the YAML splitter and producing a confusing downstream error.
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Fetching CRD manifest ${self.url} returned HTTP ${self.status_code}. Check that the pinned version exists, or set crd_manifest_urls to an internal mirror."
    }
  }
}

data "kubectl_file_documents" "crds" {
  for_each = data.http.crds

  content = each.value.response_body
}

resource "kubectl_manifest" "crds" {
  for_each = merge([
    for url, docs in data.kubectl_file_documents.crds : {
      for id, doc in docs.manifests : "${url}|${id}" => doc
    }
  ]...)

  yaml_body = each.value

  # Server-side apply is what upstream prescribes for these manifests: the
  # Gateway API CRDs exceed the 256 KB last-applied-configuration annotation
  # limit that client-side apply relies on.
  server_side_apply = true
  force_conflicts   = true

  # Deleting a CRD deletes every object of that kind in the cluster. Removing
  # this module should not silently destroy every Gateway and route, so the
  # CRDs are left in place and removed deliberately if ever needed.
  force_new = false

  wait = true
}
