###############################################################################
# Cluster context
#
# These are produced by modules/eks as the `addons_input` output object, so the
# bootstrap layer can pass them through without rewiring every value by hand.
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster these add-ons are installed into."
  type        = string
}

variable "region" {
  description = "AWS region the cluster runs in. Passed to controllers that need to call regional AWS APIs."
  type        = string
}

variable "tags" {
  description = "Tags applied to AWS resources created by this module. Not applied to Kubernetes objects, which have stricter key syntax."
  type        = map(string)
  default     = {}
}

###############################################################################
# Scheduling
#
# Every controller in this module is cluster infrastructure. It must run on the
# managed node group rather than on Karpenter-provisioned capacity, because
# Karpenter cannot provision the node it is itself scheduled on, and a spot
# reclaim of the node running the controllers takes the cluster's self-healing
# ability down with it.
###############################################################################

variable "critical_addons_node_selector" {
  description = "Node selector applied to every controller installed by this module."
  type        = map(string)
  default     = { "node.kubernetes.io/role" = "system" }
}

variable "critical_addons_tolerations" {
  description = "Tolerations applied to every controller installed by this module. Must match the taint on the baseline system ASG."
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
  description = "Seconds to wait for each Helm release to become ready."
  type        = number
  default     = 900
}

###############################################################################
# Karpenter
###############################################################################

variable "enable_karpenter" {
  description = "Install the Karpenter controller. The IAM roles, instance profile and interruption queue are created by modules/eks; this installs the workload that uses them."
  type        = bool
  default     = true
}

variable "karpenter_chart_version" {
  description = <<-EOT
    Karpenter chart version. Must be compatible with the cluster's Kubernetes minor
    version — Karpenter supports a narrow window and a mismatch surfaces as nodes that
    are launched but never become Ready.
  EOT
  type        = string
  default     = "1.15.1"
}

variable "karpenter_chart_repository" {
  description = "OCI registry serving the Karpenter chart. Note there is no leading \"v\" on the chart version in this registry."
  type        = string
  default     = "oci://public.ecr.aws/karpenter"
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in. Must match the namespace used for its Pod Identity association in modules/eks."
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Service account name for the Karpenter controller. Must match the Pod Identity association created in modules/eks, otherwise the controller runs with no AWS permissions."
  type        = string
  default     = "karpenter"
}

variable "karpenter_queue_name" {
  description = "Name of the SQS queue carrying spot interruption and instance health events. From the karpenter_queue_name output of modules/eks."
  type        = string
  default     = null
}

variable "karpenter_node_iam_role_name" {
  description = "Name of the IAM role Karpenter-provisioned nodes assume. From the karpenter_node_iam_role_name output of modules/eks. Referenced by the default EC2NodeClass."
  type        = string
  default     = null
}

variable "karpenter_replicas" {
  description = "Karpenter controller replicas. Two gives leader-election failover; Karpenter is active/passive so this does not increase throughput."
  type        = number
  default     = 2
}

variable "karpenter_values" {
  description = "Additional values merged over the computed Karpenter chart values."
  type        = any
  default     = {}
}

###############################################################################
# Karpenter default provisioning configuration
###############################################################################

variable "create_default_node_pool" {
  description = <<-EOT
    Create a default EC2NodeClass and NodePool so the cluster can scale out
    immediately after bootstrap. Set to false when node pools are owned by a separate
    GitOps repository, which is the better end state for most platform teams.
  EOT
  type        = bool
  default     = true
}

variable "node_pool_subnet_selector_tags" {
  description = "Tags used by the default EC2NodeClass to discover subnets for new nodes. The networking module applies karpenter.sh/discovery to the private subnets."
  type        = map(string)
  default     = null
}

variable "node_pool_security_group_selector_tags" {
  description = "Tags used by the default EC2NodeClass to discover security groups for new nodes. modules/eks applies karpenter.sh/discovery to the shared node security group."
  type        = map(string)
  default     = null
}

variable "node_pool_ami_alias" {
  description = <<-EOT
    AMI alias for the default EC2NodeClass, e.g. "al2023@latest" or a pinned
    "al2023@v20260501". Amazon Linux 2 is end-of-life and must not be used.

    "@latest" keeps nodes patched automatically but means the AMI can change without a
    Terraform diff. Pin the alias in production and roll it deliberately.
  EOT
  type        = string
  default     = "al2023@latest"

  validation {
    condition     = can(regex("^(al2023|bottlerocket|windows2019|windows2022)@", var.node_pool_ami_alias))
    error_message = "node_pool_ami_alias must start with a supported AMI family followed by @, e.g. al2023@latest. Amazon Linux 2 is end-of-life."
  }
}

variable "node_pool_capacity_types" {
  description = "Capacity types the default NodePool may use. Listing spot first does not imply preference — Karpenter always price-optimises across the whole list."
  type        = list(string)
  default     = ["spot", "on-demand"]

  validation {
    condition     = length(setsubtract(toset(var.node_pool_capacity_types), toset(["spot", "on-demand"]))) == 0
    error_message = "node_pool_capacity_types may only contain \"spot\" and \"on-demand\"."
  }
}

variable "node_pool_instance_categories" {
  description = "EC2 instance categories the default NodePool may select from. A broad list materially improves spot availability and price."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "node_pool_instance_generations" {
  description = "Minimum EC2 instance generation. Restricting to recent generations avoids scheduling onto obsolete, poor price-performance hardware."
  type        = number
  default     = 6
}

variable "node_pool_cpu_limit" {
  description = "Maximum total vCPU the default NodePool may provision. This is the blast-radius control on runaway scale-out and the single most important cost guardrail."
  type        = number
  default     = 1000
}

variable "node_pool_consolidation_policy" {
  description = <<-EOT
    When Karpenter may consolidate nodes.

      "WhenEmptyOrUnderutilized" - also repacks underutilised nodes. Best cost result,
                                   but disrupts running pods, so workloads need
                                   PodDisruptionBudgets.
      "WhenEmpty"                - only removes nodes with no workload pods. Safer and
                                   much less disruptive, but leaves money on the table.
  EOT
  type        = string
  default     = "WhenEmptyOrUnderutilized"

  validation {
    condition     = contains(["WhenEmpty", "WhenEmptyOrUnderutilized"], var.node_pool_consolidation_policy)
    error_message = "node_pool_consolidation_policy must be \"WhenEmpty\" or \"WhenEmptyOrUnderutilized\"."
  }
}

variable "node_pool_expire_after" {
  description = "Maximum node lifetime before Karpenter proactively replaces it. Bounded node age forces regular AMI patching and prevents long-lived, drifted nodes."
  type        = string
  default     = "720h"
}

variable "node_pool_disruption_budgets" {
  description = "Disruption budgets limiting how much of the NodePool Karpenter may disrupt at once, and optionally during which windows."
  type = list(object({
    nodes    = string
    reasons  = optional(list(string))
    schedule = optional(string)
    duration = optional(string)
  }))
  default = [{ nodes = "10%" }]
}

variable "node_pool_volume_size" {
  description = "Root EBS volume size for Karpenter-provisioned nodes. Container image layers, not application data, usually drive this."
  type        = string
  default     = "100Gi"
}

variable "node_pool_kms_key_id" {
  description = "KMS key for encrypting Karpenter node root volumes. Null uses the account's default EBS key, which is still encrypted but not customer-managed."
  type        = string
  default     = null
}

###############################################################################
# cert-manager
###############################################################################

variable "enable_cert_manager" {
  description = "Install cert-manager. Required for Istio custom CAs, webhook certificates and any in-cluster TLS that does not terminate on an ACM-backed load balancer."
  type        = bool
  default     = true
}

variable "cert_manager_chart_version" {
  description = "cert-manager chart version. Note this chart keeps the leading \"v\"."
  type        = string
  default     = "v1.21.3"
}

variable "cert_manager_namespace" {
  description = "Namespace for cert-manager. Must match the Pod Identity association created in modules/eks."
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_enable_gateway_api" {
  description = <<-EOT
    Let cert-manager issue certificates for Gateway listeners annotated with
    cert-manager.io/issuer. Only useful when certificates are terminated inside the
    cluster — Gateways fronted by an ALB or NLB terminate on ACM instead and do not
    need this.
  EOT
  type        = bool
  default     = false
}

variable "cert_manager_values" {
  description = "Additional values merged over the computed cert-manager chart values."
  type        = any
  default     = {}
}

###############################################################################
# external-dns
###############################################################################

variable "enable_external_dns" {
  description = "Install external-dns to publish Route 53 records for Gateways, Services and Ingresses."
  type        = bool
  default     = true
}

variable "external_dns_chart_version" {
  description = "external-dns chart version."
  type        = string
  default     = "1.23.0"
}

variable "external_dns_namespace" {
  description = "Namespace for external-dns. Must match the Pod Identity association created in modules/eks."
  type        = string
  default     = "external-dns"
}

variable "external_dns_domain_filters" {
  description = <<-EOT
    Domains external-dns is allowed to manage. Leaving this empty lets the controller
    operate on every hosted zone its IAM role can reach, which is how one cluster ends
    up deleting another cluster's records. Always set it.
  EOT
  type        = list(string)
  default     = []
}

variable "external_dns_policy" {
  description = <<-EOT
    How external-dns reconciles records.

      "upsert-only" - creates and updates records but never deletes. Safe default; the
                      cost is orphaned records when a Gateway is removed.
      "sync"        - full reconciliation including deletion. Correct for a cluster that
                      exclusively owns its hosted zone, dangerous otherwise.
  EOT
  type        = string
  default     = "upsert-only"

  validation {
    condition     = contains(["sync", "upsert-only", "create-only"], var.external_dns_policy)
    error_message = "external_dns_policy must be \"sync\", \"upsert-only\" or \"create-only\"."
  }
}

variable "external_dns_sources" {
  description = "Kubernetes resources external-dns watches. The gateway-* sources are what make Gateway API hostnames resolvable."
  type        = list(string)
  default     = ["service", "ingress", "gateway-httproute", "gateway-grpcroute", "gateway-tlsroute"]
}

variable "external_dns_values" {
  description = "Additional values merged over the computed external-dns chart values."
  type        = any
  default     = {}
}

###############################################################################
# metrics-server
###############################################################################

variable "enable_metrics_server" {
  description = "Install metrics-server. Required by HorizontalPodAutoscaler and `kubectl top`; nothing else provides the resource metrics API."
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "metrics-server chart version."
  type        = string
  default     = "3.14.0"
}

variable "metrics_server_values" {
  description = "Additional values merged over the computed metrics-server chart values."
  type        = any
  default     = {}
}

###############################################################################
# Argo CD
###############################################################################

variable "enable_argocd" {
  description = "Install Argo CD. Installing it from Terraform and then letting it manage applications from Git is the usual hand-off point between infrastructure and application delivery."
  type        = bool
  default     = false
}

variable "argocd_chart_version" {
  description = "Argo CD chart version."
  type        = string
  default     = "10.18.0"
}

variable "argocd_namespace" {
  description = "Namespace for Argo CD."
  type        = string
  default     = "argocd"
}

variable "argocd_values" {
  description = <<-EOT
    Additional values merged over the computed Argo CD chart values.

    The module deliberately does not expose an admin password variable: a password set
    in Terraform ends up in plaintext in state. Leave the generated bootstrap secret in
    place, read it once with kubectl, then disable local accounts and wire SSO through
    this variable.
  EOT
  type        = any
  default     = {}
}

###############################################################################
# kube-prometheus-stack
###############################################################################

variable "enable_monitoring" {
  description = "Install kube-prometheus-stack (Prometheus, Alertmanager, Grafana and the standard Kubernetes dashboards and alerts)."
  type        = bool
  default     = false
}

variable "monitoring_chart_version" {
  description = "kube-prometheus-stack chart version."
  type        = string
  default     = "93.2.2"
}

variable "monitoring_namespace" {
  description = "Namespace for the monitoring stack."
  type        = string
  default     = "monitoring"
}

variable "monitoring_retention" {
  description = "How long Prometheus retains metrics locally. Longer retention needs a correspondingly larger volume."
  type        = string
  default     = "15d"
}

variable "monitoring_storage_size" {
  description = "Size of the Prometheus persistent volume."
  type        = string
  default     = "100Gi"
}

variable "monitoring_storage_class" {
  description = "StorageClass for the Prometheus volume. gp3 is cheaper and faster than gp2 and should be the cluster default."
  type        = string
  default     = "gp3"
}

variable "monitoring_values" {
  description = <<-EOT
    Additional values merged over the computed kube-prometheus-stack values.

    As with Argo CD, no Grafana password variable is exposed. Use the generated secret
    or configure SSO here.
  EOT
  type        = any
  default     = {}
}

###############################################################################
# Storage classes
###############################################################################

variable "create_gp3_storage_class" {
  description = <<-EOT
    Create an encrypted gp3 StorageClass and make it the cluster default.

    EKS ships a `gp2` default StorageClass that is slower, more expensive and not
    encrypted with a customer-managed key. This replaces it as the default so that any
    PersistentVolumeClaim without an explicit storageClassName lands on gp3.
  EOT
  type        = bool
  default     = true
}

variable "gp3_kms_key_id" {
  description = "KMS key for the gp3 StorageClass. Null uses the account default EBS key."
  type        = string
  default     = null
}
