output "karpenter_installed" {
  description = "Whether the Karpenter controller was installed."
  value       = var.enable_karpenter
}

output "karpenter_chart_version" {
  description = "Karpenter chart version installed."
  value       = var.enable_karpenter ? var.karpenter_chart_version : null
}

output "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in."
  value       = var.enable_karpenter ? var.karpenter_namespace : null
}

output "default_node_pool_name" {
  description = "Name of the default Karpenter NodePool, or null when node pools are managed elsewhere."
  value       = local.create_node_pool ? "default" : null
}

output "default_ec2_node_class_name" {
  description = "Name of the default Karpenter EC2NodeClass."
  value       = local.create_node_pool ? "default" : null
}

output "cert_manager_namespace" {
  description = "Namespace cert-manager runs in."
  value       = var.enable_cert_manager ? var.cert_manager_namespace : null
}

output "external_dns_namespace" {
  description = "Namespace external-dns runs in."
  value       = var.enable_external_dns ? var.external_dns_namespace : null
}

output "argocd_namespace" {
  description = "Namespace Argo CD runs in."
  value       = var.enable_argocd ? var.argocd_namespace : null
}

output "argocd_initial_password_command" {
  description = <<-EOT
    Command that reads the generated Argo CD admin password.

    The password is not set from Terraform on purpose: any value passed to the chart
    would be stored in plaintext in state. Read it once, then configure SSO and
    disable the local admin account.
  EOT
  value = var.enable_argocd ? join(" ", [
    "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret",
    "-o jsonpath='{.data.password}' | base64 -d",
  ]) : null
}

output "monitoring_namespace" {
  description = "Namespace the monitoring stack runs in."
  value       = var.enable_monitoring ? var.monitoring_namespace : null
}

output "grafana_initial_password_command" {
  description = "Command that reads the generated Grafana admin password. Not managed from Terraform, for the same reason as Argo CD."
  value = var.enable_monitoring ? join(" ", [
    "kubectl -n ${var.monitoring_namespace} get secret kube-prometheus-stack-grafana",
    "-o jsonpath='{.data.admin-password}' | base64 -d",
  ]) : null
}

output "default_storage_class_name" {
  description = "StorageClass used by PersistentVolumeClaims that do not name one."
  value       = var.create_gp3_storage_class ? "gp3" : "gp2"
}
