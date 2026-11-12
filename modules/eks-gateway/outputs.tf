output "gateway_api_version" {
  description = "Gateway API release whose CRDs were installed."
  value       = var.manage_crds ? var.gateway_api_version : null
}

output "controller_chart_version" {
  description = "AWS Load Balancer Controller chart version installed."
  value       = var.chart_version
}

output "controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in."
  value       = var.namespace
}

output "controller_service_account_name" {
  description = "Service account the controller runs as. Must match the Pod Identity association in modules/eks."
  value       = kubernetes_service_account_v1.controller.metadata[0].name
}

output "alb_gateway_class_name" {
  description = "Name of the ALB-backed GatewayClass. Reference from spec.gatewayClassName on a Gateway carrying HTTPRoute or GRPCRoute."
  value       = var.create_default_gateway_classes ? var.alb_gateway_class_name : null
}

output "nlb_gateway_class_name" {
  description = "Name of the NLB-backed GatewayClass. Reference from spec.gatewayClassName on a Gateway carrying TCPRoute, UDPRoute or TLSRoute."
  value       = var.create_default_gateway_classes ? var.nlb_gateway_class_name : null
}

output "alb_controller_name" {
  description = "GatewayClass controllerName implemented by the ALB controller."
  value       = "gateway.k8s.aws/alb"
}

output "nlb_controller_name" {
  description = "GatewayClass controllerName implemented by the NLB controller."
  value       = "gateway.k8s.aws/nlb"
}

output "gateway_class_defaults_namespace" {
  description = "Namespace holding the LoadBalancerConfiguration objects referenced by the default GatewayClasses."
  value       = var.gateway_class_defaults_namespace
}

output "load_balancer_configuration_names" {
  description = "Names of the caller-defined LoadBalancerConfiguration objects created by this module."
  value       = keys(var.load_balancer_configurations)
}

output "gateway_names" {
  description = "Names of the Gateway objects created by this module."
  value       = keys(var.gateways)
}
