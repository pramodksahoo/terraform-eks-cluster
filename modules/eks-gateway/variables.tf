###############################################################################
# Cluster context
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. The AWS Load Balancer Controller uses it for resource tagging and for discovering subnets and security groups."
  type        = string
}

variable "region" {
  description = "AWS region the cluster runs in."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster runs in. Supplying it explicitly saves the controller an EC2 describe call on every start and removes a failure mode on restricted IAM policies."
  type        = string
}

variable "tags" {
  description = "Tags applied to the AWS load balancers the controller provisions."
  type        = map(string)
  default     = {}
}

###############################################################################
# Scheduling
###############################################################################

variable "node_selector" {
  description = "Node selector for the controller. It belongs on the statically provisioned system node group: it is in the path of every load balancer reconcile."
  type        = map(string)
  default     = { "node.kubernetes.io/role" = "system" }
}

variable "tolerations" {
  description = "Tolerations for the controller. Must match the taint on the baseline system ASG."
  type = list(object({
    key      = optional(string)
    operator = optional(string)
    value    = optional(string)
    effect   = optional(string)
  }))
  default = [{
    key      = "CriticalAddonsOnly"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]
}

variable "helm_timeout" {
  description = "Seconds to wait for the controller release to become ready."
  type        = number
  default     = 600
}

###############################################################################
# AWS Load Balancer Controller
###############################################################################

variable "chart_version" {
  description = "aws-load-balancer-controller chart version. Chart and app version are aligned from 3.x onwards."
  type        = string
  default     = "3.6.2"
}

variable "chart_repository" {
  description = "Helm repository serving the AWS Load Balancer Controller chart."
  type        = string
  default     = "https://aws.github.io/eks-charts"
}

variable "namespace" {
  description = "Namespace for the controller. Must match the Pod Identity association created in modules/eks."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = <<-EOT
    Service account the controller runs as. Must match the Pod Identity association
    created in modules/eks.

    The service account is created by this module rather than the chart so that no
    IRSA eks.amazonaws.com/role-arn annotation is ever attached: an IRSA annotation
    takes precedence over Pod Identity and would silently route the controller to the
    wrong credential source.
  EOT
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "replica_count" {
  description = "Controller replicas. The controller is active/passive via leader election, so more than one buys failover rather than throughput."
  type        = number
  default     = 2
}

variable "enable_waf" {
  description = "Allow the controller to manage WAFv2 and Shield associations on the load balancers it creates. Requires the matching IAM permissions; leave off if they are not granted."
  type        = bool
  default     = false
}

variable "controller_values" {
  description = "Additional values merged over the computed controller chart values."
  type        = any
  default     = {}
}

###############################################################################
# CRDs
###############################################################################

variable "manage_crds" {
  description = <<-EOT
    Install and manage the Gateway API and AWS Load Balancer Controller CRDs from this
    module.

    This is strongly recommended. Helm installs a chart's bundled CRDs on first install
    and then never touches them again, so a chart version bump leaves the old CRD
    schemas in place and new fields are silently dropped. Managing them as explicit
    resources means upgrades actually apply.

    Set to false only when CRDs are owned by a separate cluster-bootstrap process.
  EOT
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = <<-EOT
    Gateway API release whose CRDs are installed, e.g. "v1.6.0".

    Pin this to the version the controller is built against rather than to the newest
    release. AWS Load Balancer Controller 3.6.x is built and conformance-tested against
    Gateway API v1.6.0.
  EOT
  type        = string
  default     = "v1.6.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.gateway_api_version))
    error_message = "gateway_api_version must be a tagged release with a leading \"v\", e.g. v1.6.0."
  }
}

variable "gateway_api_channel" {
  description = <<-EOT
    Which Gateway API CRD channel to install.

      "standard"     - the stable surface. From v1.6.0 this includes TCPRoute and
                       UDPRoute, so L4 routing no longer needs the experimental channel.
      "experimental" - adds alpha resources such as BackendTLSPolicy. Expect breaking
                       changes between releases.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "experimental"], var.gateway_api_channel)
    error_message = "gateway_api_channel must be \"standard\" or \"experimental\"."
  }
}

variable "crd_manifest_urls" {
  description = <<-EOT
    Override the URLs the CRD manifests are fetched from, as a list.

    By default the module derives immutable, tag-pinned GitHub release URLs from
    gateway_api_version and chart_version. Override this to serve the manifests from an
    internal mirror, which is required in an air-gapped environment and is good
    practice anywhere that an external fetch during plan is unacceptable.

    Never point these at a branch such as `main`: the content would change underneath
    the configuration with no version bump and no diff.
  EOT
  type        = list(string)
  default     = null
}

###############################################################################
# GatewayClasses
###############################################################################

variable "create_default_gateway_classes" {
  description = <<-EOT
    Create the `aws-alb` and `aws-nlb` GatewayClasses.

    GatewayClasses are cluster-scoped and are the platform team's contract with
    application teams: the application team writes a Gateway referencing a class name
    and never needs to know the controller name or the AWS wiring behind it.
  EOT
  type        = bool
  default     = true
}

variable "alb_gateway_class_name" {
  description = "Name of the ALB-backed GatewayClass. Application teams reference this from spec.gatewayClassName."
  type        = string
  default     = "aws-alb"
}

variable "nlb_gateway_class_name" {
  description = "Name of the NLB-backed GatewayClass."
  type        = string
  default     = "aws-nlb"
}

variable "gateway_class_defaults_namespace" {
  description = "Namespace holding the LoadBalancerConfiguration objects that the default GatewayClasses point at. A platform-owned namespace keeps application teams from editing cluster-wide load balancer defaults."
  type        = string
  default     = "kube-system"
}

###############################################################################
# Load balancer defaults applied through the GatewayClasses
###############################################################################

variable "default_scheme" {
  description = <<-EOT
    Default scheme for load balancers created through the default GatewayClasses.

      "internal"        - reachable only from inside the VPC and peered networks.
      "internet-facing" - public.

    "internal" is the default here and in the controller itself. Making a Gateway
    public should be a deliberate, reviewable act, not something that happens because
    a field was omitted.
  EOT
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "internet-facing"], var.default_scheme)
    error_message = "default_scheme must be \"internal\" or \"internet-facing\"."
  }
}

variable "default_ip_address_type" {
  description = "IP address type for load balancers created through the default GatewayClasses."
  type        = string
  default     = "ipv4"

  validation {
    condition     = contains(["ipv4", "dualstack", "dualstack-without-public-ipv4"], var.default_ip_address_type)
    error_message = "default_ip_address_type must be \"ipv4\", \"dualstack\" or \"dualstack-without-public-ipv4\"."
  }
}

variable "default_subnet_selector_tags" {
  description = <<-EOT
    Tags used to discover the subnets load balancers are placed in. Null falls back to
    the controller's built-in discovery, which relies on the kubernetes.io/role/elb and
    kubernetes.io/role/internal-elb subnet tags applied by the networking module.
  EOT
  type        = map(string)
  default     = null
}

variable "default_ssl_policy" {
  description = <<-EOT
    TLS security policy for HTTPS listeners.

    The default permits TLS 1.2 and 1.3 only. Policies including TLS 1.0 and 1.1 fail
    most compliance baselines and should not be reintroduced without a specific,
    documented legacy client.
  EOT
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "default_certificate_arn" {
  description = <<-EOT
    ACM certificate ARN used as the default certificate on HTTPS listeners created
    through the default GatewayClasses.

    Note that the AWS Load Balancer Controller does not read certificates from a Gateway
    listener's certificateRefs — ACM certificates are referenced here, on the
    LoadBalancerConfiguration, instead.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.default_certificate_arn == null || can(regex("^arn:aws[a-zA-Z-]*:acm:", coalesce(var.default_certificate_arn, "arn:aws:acm:")))
    error_message = "default_certificate_arn must be an ACM certificate ARN."
  }
}

variable "default_load_balancer_attributes" {
  description = "Load balancer attributes applied through the default GatewayClasses, as a key/value map. Rendered into the controller's list-of-objects form by the module."
  type        = map(string)
  default = {
    "routing.http.drop_invalid_header_fields.enabled" = "true"
    "routing.http.xff_client_port.enabled"            = "true"
    "deletion_protection.enabled"                     = "false"
  }
}

variable "default_listener_attributes" {
  description = "Listener attributes applied to the default HTTPS listener, as a key/value map."
  type        = map(string)
  default = {
    # Do not advertise the load balancer type in responses.
    "routing.http.response.server.enabled" = "false"
  }
}

variable "enable_access_logs" {
  description = "Write load balancer access logs to S3. Access logs are the only record of who reached the cluster from outside and are usually a compliance requirement."
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "S3 bucket receiving load balancer access logs. Required when enable_access_logs is true. The bucket policy must already permit the regional ELB log delivery principal."
  type        = string
  default     = null
}

variable "access_logs_prefix" {
  description = "Key prefix for load balancer access logs."
  type        = string
  default     = null
}

###############################################################################
# Caller-defined resources
###############################################################################

variable "load_balancer_configurations" {
  description = <<-EOT
    Additional LoadBalancerConfiguration objects, keyed by name. Use these for Gateways
    that need settings different from the GatewayClass defaults, for example a public
    Gateway in an otherwise internal cluster.

    Each entry mirrors the controller's gateway.k8s.aws/v1 LoadBalancerConfiguration
    spec. Null fields are omitted from the manifest so the controller's own defaults
    apply.
  EOT
  type = map(object({
    namespace                = optional(string)
    scheme                   = optional(string)
    ip_address_type          = optional(string)
    load_balancer_name       = optional(string)
    subnet_ids               = optional(list(string))
    subnet_selector_tags     = optional(map(string))
    security_group_ids       = optional(list(string))
    security_group_prefixes  = optional(list(string))
    source_ranges            = optional(list(string))
    load_balancer_attributes = optional(map(string), {})
    merging_mode             = optional(string)
    tags                     = optional(map(string), {})
    listeners = optional(list(object({
      protocol_port        = string
      certificate_arn      = optional(string)
      additional_cert_arns = optional(list(string))
      ssl_policy           = optional(string)
      alpn_policy          = optional(string)
      attributes           = optional(map(string), {})
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for c in values(var.load_balancer_configurations) :
      c.scheme == null || contains(["internal", "internet-facing"], coalesce(c.scheme, "internal"))
    ])
    error_message = "load_balancer_configurations[*].scheme must be \"internal\" or \"internet-facing\"."
  }

  validation {
    condition = alltrue(flatten([
      for c in values(var.load_balancer_configurations) : [
        for l in c.listeners : can(regex("^(HTTP|HTTPS|TCP|TLS|UDP|TCP_UDP):[0-9]{1,5}$", l.protocol_port))
      ]
    ]))
    error_message = "listeners[*].protocol_port must be PROTOCOL:PORT, e.g. HTTPS:443."
  }
}

variable "gateways" {
  description = <<-EOT
    Gateway objects to create, keyed by name. Most teams will create Gateways from their
    own application repositories rather than from here; this exists for the shared,
    platform-owned entry points.
  EOT
  type = map(object({
    namespace                   = string
    gateway_class_name          = string
    load_balancer_configuration = optional(string)
    annotations                 = optional(map(string), {})
    labels                      = optional(map(string), {})
    listeners = list(object({
      name                = string
      protocol            = string
      port                = number
      hostname            = optional(string)
      allowed_routes_from = optional(string, "Same")
    }))
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for g in values(var.gateways) : [
        for l in g.listeners : contains(["Same", "All", "Selector"], l.allowed_routes_from)
      ]
    ]))
    error_message = "gateways[*].listeners[*].allowed_routes_from must be \"Same\", \"All\" or \"Selector\"."
  }
}
