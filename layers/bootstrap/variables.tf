###############################################################################
# Account targeting
###############################################################################

variable "environment" {
  description = "Environment this stack belongs to. Must match the infrastructure layer."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "assume_role_arn" {
  description = "IAM role assumed in the target account. Must be the same role the infrastructure layer used, otherwise the EKS token will not match any access entry and every Kubernetes call will be denied."
  type        = string
  default     = null
}

variable "assume_role_external_id" {
  description = "External ID required when assuming assume_role_arn."
  type        = string
  default     = null
  sensitive   = true
}

variable "allowed_account_ids" {
  description = "AWS account IDs this stack is permitted to run against."
  type        = list(string)
  default     = []
}

###############################################################################
# Remote state
###############################################################################

variable "infrastructure_state_bucket" {
  description = "S3 bucket holding the infrastructure layer's state."
  type        = string
}

variable "infrastructure_state_key" {
  description = "Key of the infrastructure layer's state object within the bucket."
  type        = string
}

variable "infrastructure_state_region" {
  description = "Region of the state bucket. Defaults to the deployment region."
  type        = string
  default     = null
}

variable "infrastructure_state_role_arn" {
  description = "IAM role assumed to read the infrastructure state. Needed when state lives in a shared tooling account rather than the workload account."
  type        = string
  default     = null
}

###############################################################################
# Gateway API
###############################################################################

variable "enable_gateway" {
  description = "Install the AWS Load Balancer Controller and the Gateway API implementation. This is the supported replacement for the retired ingress-nginx controller."
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = "Gateway API release whose CRDs are installed. Pin to the version the controller is built against, not to the newest release."
  type        = string
  default     = "v1.6.0"
}

variable "gateway_default_scheme" {
  description = "Default scheme for load balancers created through the default GatewayClasses. Keep \"internal\" unless the cluster genuinely serves public traffic."
  type        = string
  default     = "internal"
}

variable "gateway_default_certificate_arn" {
  description = <<-EOT
    ACM certificate used as the default on HTTPS listeners.

    The AWS Load Balancer Controller does not read certificates from a Gateway
    listener's certificateRefs; ACM certificates attach through the
    LoadBalancerConfiguration instead. This is the TLS termination point.
  EOT
  type        = string
  default     = null
}

variable "gateway_enable_access_logs" {
  description = "Write load balancer access logs to S3."
  type        = bool
  default     = false
}

variable "gateway_access_logs_bucket" {
  description = "S3 bucket receiving load balancer access logs."
  type        = string
  default     = null
}

variable "gateways" {
  description = "Platform-owned Gateway objects to create. Application teams normally create their own from their own repositories."
  type        = any
  default     = {}
}

###############################################################################
# Platform add-ons
###############################################################################

variable "enable_karpenter" {
  description = "Install the Karpenter controller. The IAM roles and interruption queue come from the infrastructure layer."
  type        = bool
  default     = true
}

variable "karpenter_node_pool_capacity_types" {
  description = "Capacity types the default Karpenter NodePool may use."
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "karpenter_node_pool_cpu_limit" {
  description = "Maximum total vCPU Karpenter may provision. The primary cost guardrail."
  type        = number
  default     = 1000
}

variable "enable_cert_manager" {
  description = "Install cert-manager."
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Install external-dns."
  type        = bool
  default     = true
}

variable "external_dns_domain_filters" {
  description = "Domains external-dns may manage. Always set this — an unfiltered controller acts on every zone its IAM role can reach."
  type        = list(string)
  default     = []
}

variable "external_dns_policy" {
  description = "How external-dns reconciles records. \"upsert-only\" never deletes."
  type        = string
  default     = "upsert-only"
}

variable "enable_metrics_server" {
  description = "Install metrics-server. Required by HorizontalPodAutoscaler."
  type        = bool
  default     = true
}

variable "enable_argocd" {
  description = "Install Argo CD."
  type        = bool
  default     = false
}

variable "enable_monitoring" {
  description = "Install kube-prometheus-stack."
  type        = bool
  default     = false
}

variable "addons_values" {
  description = "Per-add-on Helm value overrides, keyed by add-on name. Escape hatch for settings this layer does not expose explicitly."
  type        = any
  default     = {}
}

###############################################################################
# Istio
###############################################################################

variable "enable_istio" {
  description = "Install the Istio service mesh."
  type        = bool
  default     = false
}

variable "istio_mesh_mode" {
  description = "Istio data-plane mode. \"ambient\" avoids per-pod sidecars; \"sidecar\" is the classic model."
  type        = string
  default     = "ambient"
}

variable "istio_chart_version" {
  description = "Istio chart version applied to every Istio component."
  type        = string
  default     = "1.30.8"
}

variable "istio_mtls_mode" {
  description = "Mesh-wide PeerAuthentication mode. Start PERMISSIVE while onboarding, then move to STRICT."
  type        = string
  default     = "PERMISSIVE"
}

variable "istio_ambient_namespaces" {
  description = "Existing namespaces to enrol into the ambient mesh."
  type        = list(string)
  default     = []
}

###############################################################################
# Scheduling
###############################################################################

variable "system_node_selector" {
  description = "Node selector pinning platform controllers to the baseline system ASG. Must match the labels set by the infrastructure layer."
  type        = map(string)
  default     = { "node.kubernetes.io/role" = "system" }
}

variable "system_tolerations" {
  description = "Tolerations matching the system node group taint."
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

variable "tags" {
  description = "Tags applied to AWS resources created by the controllers, such as load balancers."
  type        = map(string)
  default     = {}
}
