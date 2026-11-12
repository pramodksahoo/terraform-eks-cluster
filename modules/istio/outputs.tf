output "namespace" {
  description = "Namespace the Istio control plane is installed in."
  value       = var.namespace
}

output "mesh_mode" {
  description = "Data-plane mode the mesh was installed with."
  value       = var.mesh_mode
}

output "mesh_id" {
  description = "Mesh identifier. Every cluster joining this mesh must use the same value."
  value       = local.mesh_id
}

output "trust_domain" {
  description = "SPIFFE trust domain issued to workloads in this mesh."
  value       = var.trust_domain
}

output "revision" {
  description = "Control-plane revision, or null for an unrevisioned install."
  value       = var.revision
}

output "chart_version" {
  description = "Istio chart version installed across all components."
  value       = var.chart_version
}

output "istio_gateway_class_name" {
  description = <<-EOT
    Name of the GatewayClass istiod reconciles. Use this on a Gateway resource to have
    Istio terminate traffic itself, as opposed to the AWS Load Balancer Controller
    classes which terminate on an ALB or NLB.
  EOT
  value       = "istio"
}

output "gateway_release_names" {
  description = "Helm release names of the Istio gateway deployments created by this module."
  value       = keys(helm_release.gateway)
}

output "ambient_enrolled_namespaces" {
  description = "Namespaces labelled for ambient mesh enrolment by this module."
  value       = local.is_ambient ? var.ambient_namespaces : []
}

output "namespace_label_sidecar" {
  description = "Label a namespace with this key/value to enable sidecar injection for it. Empty in ambient mode."
  value = var.mesh_mode == "sidecar" ? (
    var.revision == null
    ? { "istio-injection" = "enabled" }
    : { "istio.io/rev" = var.revision }
  ) : {}
}

output "namespace_label_ambient" {
  description = "Label a namespace with this key/value to enrol it into the ambient mesh. Empty in sidecar mode."
  value       = local.is_ambient ? { "istio.io/dataplane-mode" = "ambient" } : {}
}
