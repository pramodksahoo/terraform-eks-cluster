output "cluster_name" {
  description = "Cluster these components were installed into."
  value       = local.infra.cluster_name
}

output "alb_gateway_class_name" {
  description = "GatewayClass name to put in spec.gatewayClassName for an ALB-backed Gateway carrying HTTPRoute or GRPCRoute."
  value       = try(module.gateway[0].alb_gateway_class_name, null)
}

output "nlb_gateway_class_name" {
  description = "GatewayClass name for an NLB-backed Gateway carrying TCPRoute, UDPRoute or TLSRoute."
  value       = try(module.gateway[0].nlb_gateway_class_name, null)
}

output "gateway_class_defaults_namespace" {
  description = "Namespace holding the platform-owned LoadBalancerConfiguration defaults."
  value       = try(module.gateway[0].gateway_class_defaults_namespace, null)
}

output "gateway_api_version" {
  description = "Gateway API release installed in the cluster."
  value       = try(module.gateway[0].gateway_api_version, null)
}

output "istio_namespace" {
  description = "Namespace the Istio control plane runs in."
  value       = try(module.istio[0].namespace, null)
}

output "istio_namespace_enrolment_label" {
  description = "Label to apply to an application namespace to put its workloads into the mesh."
  value = try(
    var.istio_mesh_mode == "ambient" ? module.istio[0].namespace_label_ambient : module.istio[0].namespace_label_sidecar,
    null,
  )
}

output "default_storage_class" {
  description = "Default StorageClass for PersistentVolumeClaims that do not name one."
  value       = module.addons.default_storage_class_name
}

output "next_steps" {
  description = "What to do once this layer has applied."
  value       = <<-EOT
    1. Point kubectl at the cluster:
         ${local.infra.kubeconfig_command}

    2. Confirm the Gateway API implementation is live:
         kubectl get gatewayclass

       Both classes should report ACCEPTED=True. If they are missing, the AWS Load
       Balancer Controller did not detect the CRDs at startup; restart it with
         kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller

    3. Confirm Karpenter can provision:
         kubectl get nodepool,ec2nodeclass
         kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter

    4. Create a Gateway and an HTTPRoute from your application repository. See
       docs/gateway-api-migration.md for the ingress-nginx equivalents.
  EOT
}
