###############################################################################
# GatewayClasses and load balancer defaults
#
# The GatewayClass is the platform team's contract with application teams: an
# application team writes `gatewayClassName: aws-alb` and inherits the scheme,
# TLS policy, certificate, subnets and attributes defined here, without needing
# to know anything about the AWS wiring behind it.
#
# Defaults attach to the class through parametersRef, which on a GatewayClass
# is namespaced. The referenced LoadBalancerConfiguration therefore lives in a
# platform-owned namespace that application teams cannot write to.
###############################################################################

locals {
  create_classes = var.create_default_gateway_classes

  default_lbc_namespace = var.gateway_class_defaults_namespace

  # The controller models attributes as a list of {key, value} objects; a map is
  # a far better authoring surface, so it is converted here. Sorted for a stable
  # plan.
  default_lb_attributes = [
    for k in sort(keys(local.default_lb_attribute_map)) : {
      key   = k
      value = local.default_lb_attribute_map[k]
    }
  ]

  default_lb_attribute_map = merge(
    var.default_load_balancer_attributes,
    var.enable_access_logs ? merge(
      {
        "access_logs.s3.enabled" = "true"
        "access_logs.s3.bucket"  = var.access_logs_bucket
      },
      var.access_logs_prefix == null ? {} : {
        "access_logs.s3.prefix" = var.access_logs_prefix
      },
    ) : {},
  )

  default_listener_attributes = [
    for k in sort(keys(var.default_listener_attributes)) : {
      key   = k
      value = var.default_listener_attributes[k]
    }
  ]

  # HTTPS listener defaults are only emitted when a certificate is available.
  # A HTTPS listener with no certificate is rejected by ELB, so it is better to
  # omit the listener configuration entirely and let the Gateway's own listener
  # definition drive it.
  default_https_listener = var.default_certificate_arn == null ? [] : [
    merge(
      {
        protocolPort       = "HTTPS:443"
        defaultCertificate = var.default_certificate_arn
        sslPolicy          = var.default_ssl_policy
      },
      length(local.default_listener_attributes) > 0 ? {
        listenerAttributes = local.default_listener_attributes
      } : {},
    )
  ]

  default_lb_config_spec = merge(
    {
      scheme        = var.default_scheme
      ipAddressType = var.default_ip_address_type
      tags          = var.tags
    },
    length(local.default_lb_attributes) > 0 ? {
      loadBalancerAttributes = local.default_lb_attributes
    } : {},
    var.default_subnet_selector_tags == null ? {} : {
      loadBalancerSubnetsSelector = var.default_subnet_selector_tags
    },
    length(local.default_https_listener) > 0 ? {
      listenerConfigurations = local.default_https_listener
    } : {},
  )
}

resource "kubectl_manifest" "default_alb_config" {
  count = local.create_classes ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.k8s.aws/v1"
    kind       = "LoadBalancerConfiguration"
    metadata = {
      name      = "${var.alb_gateway_class_name}-defaults"
      namespace = local.default_lbc_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = local.default_lb_config_spec
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.controller]
}

resource "kubectl_manifest" "default_nlb_config" {
  count = local.create_classes ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.k8s.aws/v1"
    kind       = "LoadBalancerConfiguration"
    metadata = {
      name      = "${var.nlb_gateway_class_name}-defaults"
      namespace = local.default_lbc_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    # NLB listeners are L4; the HTTPS listener defaults above do not apply.
    spec = {
      scheme        = var.default_scheme
      ipAddressType = var.default_ip_address_type
      tags          = var.tags
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.controller]
}

resource "kubectl_manifest" "alb_gateway_class" {
  count = local.create_classes ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = var.alb_gateway_class_name
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      controllerName = "gateway.k8s.aws/alb"
      description    = "Application Load Balancer, for HTTPRoute and GRPCRoute."
      parametersRef = {
        group     = "gateway.k8s.aws"
        kind      = "LoadBalancerConfiguration"
        name      = "${var.alb_gateway_class_name}-defaults"
        namespace = local.default_lbc_namespace
      }
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.default_alb_config]
}

resource "kubectl_manifest" "nlb_gateway_class" {
  count = local.create_classes ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = var.nlb_gateway_class_name
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      controllerName = "gateway.k8s.aws/nlb"
      description    = "Network Load Balancer, for TCPRoute, UDPRoute and TLSRoute."
      parametersRef = {
        group     = "gateway.k8s.aws"
        kind      = "LoadBalancerConfiguration"
        name      = "${var.nlb_gateway_class_name}-defaults"
        namespace = local.default_lbc_namespace
      }
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.default_nlb_config]
}

###############################################################################
# Caller-defined LoadBalancerConfiguration objects
###############################################################################

locals {
  lb_configs = {
    for name, c in var.load_balancer_configurations : name => {
      namespace = coalesce(c.namespace, local.default_lbc_namespace)

      spec = merge(
        {
          tags = merge(var.tags, c.tags)
        },
        c.scheme == null ? {} : { scheme = c.scheme },
        c.ip_address_type == null ? {} : { ipAddressType = c.ip_address_type },
        c.load_balancer_name == null ? {} : { loadBalancerName = c.load_balancer_name },
        c.security_group_ids == null ? {} : { securityGroups = c.security_group_ids },
        c.security_group_prefixes == null ? {} : { securityGroupPrefixes = c.security_group_prefixes },
        c.source_ranges == null ? {} : { sourceRanges = c.source_ranges },
        c.merging_mode == null ? {} : { mergingMode = c.merging_mode },

        # Explicit subnet IDs win over a selector in the controller, so only one
        # is ever emitted to keep the resulting behaviour unambiguous.
        c.subnet_ids != null ? {
          loadBalancerSubnets = [for s in c.subnet_ids : { identifier = s }]
          } : c.subnet_selector_tags == null ? {} : {
          loadBalancerSubnetsSelector = c.subnet_selector_tags
        },

        length(c.load_balancer_attributes) == 0 ? {} : {
          loadBalancerAttributes = [
            for k in sort(keys(c.load_balancer_attributes)) : {
              key   = k
              value = c.load_balancer_attributes[k]
            }
          ]
        },

        length(c.listeners) == 0 ? {} : {
          listenerConfigurations = [
            for l in c.listeners : merge(
              { protocolPort = l.protocol_port },
              l.certificate_arn == null ? {} : { defaultCertificate = l.certificate_arn },
              l.additional_cert_arns == null ? {} : { certificates = l.additional_cert_arns },
              l.ssl_policy == null ? {} : { sslPolicy = l.ssl_policy },
              l.alpn_policy == null ? {} : { alpnPolicy = l.alpn_policy },
              length(l.attributes) == 0 ? {} : {
                listenerAttributes = [
                  for k in sort(keys(l.attributes)) : {
                    key   = k
                    value = l.attributes[k]
                  }
                ]
              },
            )
          ]
        },
      )
    }
  }
}

resource "kubectl_manifest" "load_balancer_configuration" {
  for_each = local.lb_configs

  yaml_body = yamlencode({
    apiVersion = "gateway.k8s.aws/v1"
    kind       = "LoadBalancerConfiguration"
    metadata = {
      name      = each.key
      namespace = each.value.namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = each.value.spec
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.controller]
}

###############################################################################
# Gateways
###############################################################################

resource "kubectl_manifest" "gateway" {
  for_each = var.gateways

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name        = each.key
      namespace   = each.value.namespace
      annotations = each.value.annotations
      labels = merge(each.value.labels, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = merge(
      {
        gatewayClassName = each.value.gateway_class_name
        listeners = [
          for l in each.value.listeners : merge(
            {
              name     = l.name
              protocol = l.protocol
              port     = l.port
              allowedRoutes = {
                namespaces = {
                  from = l.allowed_routes_from
                }
              }
            },
            l.hostname == null ? {} : { hostname = l.hostname },
          )
        ]
      },
      # On a Gateway the parametersRef is not namespaced: the configuration must
      # live in the Gateway's own namespace.
      each.value.load_balancer_configuration == null ? {} : {
        infrastructure = {
          parametersRef = {
            group = "gateway.k8s.aws"
            kind  = "LoadBalancerConfiguration"
            name  = each.value.load_balancer_configuration
          }
        }
      },
    )
  })

  server_side_apply = true
  wait              = true

  depends_on = [
    kubectl_manifest.alb_gateway_class,
    kubectl_manifest.nlb_gateway_class,
    kubectl_manifest.load_balancer_configuration,
  ]
}
