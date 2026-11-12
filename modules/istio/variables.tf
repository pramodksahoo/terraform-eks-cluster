###############################################################################
# Cluster context
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster Istio is installed into. Used as the mesh's cluster identifier for multi-cluster meshes."
  type        = string
}

variable "mesh_id" {
  description = <<-EOT
    Identifier shared by every cluster that belongs to the same mesh. Clusters with the
    same mesh_id and a shared trust domain can federate. Defaults to the cluster name,
    which is correct for a single-cluster mesh but must be set explicitly before adding
    a second cluster — changing it later forces a full mesh restart.
  EOT
  type        = string
  default     = null
}

variable "network" {
  description = "Name of the network this cluster sits on. Only relevant for multi-network meshes; pods in different networks reach each other through east-west gateways."
  type        = string
  default     = null
}

variable "trust_domain" {
  description = "SPIFFE trust domain for workload identities. Defaults to cluster.local. Must be unique per mesh when federating."
  type        = string
  default     = "cluster.local"
}

###############################################################################
# Install profile
###############################################################################

variable "mesh_mode" {
  description = <<-EOT
    Data-plane mode for the mesh.

      "ambient"  - sidecar-less. ztunnel provides L4 mTLS for every pod in a labelled
                   namespace at near-zero per-pod cost; waypoint proxies are deployed
                   only where L7 policy is actually needed. Requires the CNI plugin.
                   Recommended for new installations.
      "sidecar"  - classic injected envoy sidecar per pod. Higher resource cost and
                   requires a pod restart to adopt, but has the longest track record
                   and full L7 features everywhere without waypoints.

    Switching modes on a live cluster is disruptive; pick one deliberately.
  EOT
  type        = string
  default     = "ambient"

  validation {
    condition     = contains(["ambient", "sidecar"], var.mesh_mode)
    error_message = "mesh_mode must be either \"ambient\" or \"sidecar\"."
  }
}

variable "chart_version" {
  description = <<-EOT
    Istio chart version applied to every Istio chart (base, istiod, cni, ztunnel,
    gateway). All Istio components must run the same minor version, so a single
    variable is deliberately used rather than one per chart.

    Note this is the *chart* version from the Helm index, which is not always
    published for every tagged GitHub release.
  EOT
  type        = string
  default     = "1.30.8"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.chart_version))
    error_message = "chart_version must be a bare semantic version with no leading \"v\", e.g. 1.30.8."
  }
}

variable "chart_repository" {
  description = "Helm repository serving the Istio charts."
  type        = string
  default     = "https://istio-release.storage.googleapis.com/charts"
}

variable "namespace" {
  description = "Namespace the Istio control plane runs in. istio-system is assumed by a large amount of tooling and documentation; change it only with good reason."
  type        = string
  default     = "istio-system"
}

variable "create_namespace" {
  description = "Create the control-plane namespace. Set to false when the namespace is managed elsewhere, for example by a namespace-as-code pipeline."
  type        = bool
  default     = true
}

variable "revision" {
  description = <<-EOT
    Control-plane revision name, used for revision-based (canary) upgrades. When set,
    istiod is installed as a revision and namespaces opt in with
    istio.io/rev=<revision> instead of istio-injection=enabled.

    Leave null for a default, unrevisioned install.
  EOT
  type        = string
  default     = null
}

###############################################################################
# CNI
###############################################################################

variable "enable_cni" {
  description = <<-EOT
    Install the Istio CNI node agent. Required for ambient mode. For sidecar mode it
    is optional but recommended: it removes the need for the NET_ADMIN capability on
    every injected pod by doing traffic redirection at CNI time instead of through an
    init container.
  EOT
  type        = bool
  default     = true
}

variable "cni_values" {
  description = "Additional values merged over the computed istio-cni chart values. Use for node-specific paths or resource tuning."
  type        = any
  default     = {}
}

###############################################################################
# Component values
###############################################################################

variable "base_values" {
  description = "Additional values merged over the computed istio base chart values."
  type        = any
  default     = {}
}

variable "istiod_values" {
  description = "Additional values merged over the computed istiod chart values. This is the main tuning surface: tracing, access logging, resource requests, HPA settings and mesh config all live here."
  type        = any
  default     = {}
}

variable "ztunnel_values" {
  description = "Additional values merged over the computed ztunnel chart values. Ignored unless mesh_mode is \"ambient\"."
  type        = any
  default     = {}
}

###############################################################################
# Gateways
###############################################################################

variable "gateways" {
  description = <<-EOT
    Istio ingress/egress gateway deployments to create from the `gateway` chart, keyed
    by Helm release name.

    A gateway is only needed when terminating traffic with Istio itself. When the
    AWS Load Balancer Controller fronts the cluster through the Gateway API, north-south
    traffic already terminates on an ALB or NLB and an Istio gateway is redundant for
    that path — leave this empty in that case.

    Each entry:
      namespace    - namespace to deploy into. Defaults to the control-plane namespace.
      service_type - Kubernetes Service type. "LoadBalancer" provisions an NLB through
                     the AWS Load Balancer Controller; "ClusterIP" is correct when an
                     ALB targets the gateway pods directly.
      annotations  - Service annotations, e.g. NLB tuning or ACM certificate ARNs.
      labels       - extra labels applied to the Service and Deployment.
      values       - arbitrary additional values merged over the computed values.
  EOT
  type = map(object({
    namespace    = optional(string)
    service_type = optional(string, "ClusterIP")
    annotations  = optional(map(string), {})
    labels       = optional(map(string), {})
    values       = optional(any, {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for g in values(var.gateways) :
      contains(["ClusterIP", "LoadBalancer", "NodePort"], g.service_type)
    ])
    error_message = "gateways[*].service_type must be one of ClusterIP, LoadBalancer or NodePort."
  }
}

###############################################################################
# Mesh behaviour
###############################################################################

variable "mtls_mode" {
  description = <<-EOT
    Mesh-wide default PeerAuthentication mode.

      "STRICT"     - workloads accept mTLS only. The correct end state, but it breaks
                     any traffic from outside the mesh that is not mTLS.
      "PERMISSIVE" - accept both mTLS and plaintext. Use while onboarding workloads,
                     then move to STRICT.
      null         - do not manage mesh-wide PeerAuthentication at all.
  EOT
  type        = string
  default     = "PERMISSIVE"

  validation {
    condition     = var.mtls_mode == null || contains(["STRICT", "PERMISSIVE"], coalesce(var.mtls_mode, "STRICT"))
    error_message = "mtls_mode must be \"STRICT\", \"PERMISSIVE\" or null."
  }
}

variable "outbound_traffic_policy" {
  description = <<-EOT
    How the mesh treats traffic to hosts that are not in its service registry.

      "ALLOW_ANY"    - pass unknown destinations through. Operationally easy.
      "REGISTRY_ONLY" - block anything without an explicit ServiceEntry. A meaningful
                       egress control and a common compliance requirement, but it will
                       break workloads that call undeclared external endpoints.
  EOT
  type        = string
  default     = "ALLOW_ANY"

  validation {
    condition     = contains(["ALLOW_ANY", "REGISTRY_ONLY"], var.outbound_traffic_policy)
    error_message = "outbound_traffic_policy must be \"ALLOW_ANY\" or \"REGISTRY_ONLY\"."
  }
}

variable "enable_access_logging" {
  description = "Emit Envoy/ztunnel access logs to stdout. Costs log ingest volume but is close to essential for debugging a mesh."
  type        = bool
  default     = true
}

variable "ambient_namespaces" {
  description = <<-EOT
    Namespaces to enrol into the ambient mesh by applying the
    istio.io/dataplane-mode=ambient label. Ignored unless mesh_mode is "ambient".

    The namespaces must already exist — this module labels them, it does not create
    them. Enrolment takes effect without restarting pods.
  EOT
  type        = list(string)
  default     = []
}

###############################################################################
# Scheduling
###############################################################################

variable "node_selector" {
  description = "Node selector applied to the Istio control-plane components. Pin the control plane to the baseline system ASG so it is never evicted onto a Karpenter spot node."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations applied to the Istio control-plane components. Required when the target nodes carry a taint such as CriticalAddonsOnly."
  type = list(object({
    key      = optional(string)
    operator = optional(string)
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "istiod_replicas" {
  description = "Number of istiod replicas. Two or more keeps the control plane available during a node replacement."
  type        = number
  default     = 2

  validation {
    condition     = var.istiod_replicas >= 1
    error_message = "istiod_replicas must be at least 1."
  }
}

variable "enable_pod_disruption_budget" {
  description = "Create a PodDisruptionBudget for istiod. Prevents a node drain from taking the whole control plane out at once."
  type        = bool
  default     = true
}

###############################################################################
# Operational
###############################################################################

variable "helm_timeout" {
  description = "Seconds to wait for each Helm release to become ready."
  type        = number
  default     = 600
}

variable "tags" {
  description = "Tags recorded as Helm release labels. Kubernetes label syntax applies, so keys and values must be alphanumeric plus -, _ and ."
  type        = map(string)
  default     = {}
}
