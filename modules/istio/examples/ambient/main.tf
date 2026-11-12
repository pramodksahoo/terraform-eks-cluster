###############################################################################
# istio module - ambient mesh example
#
# Ambient mode gives every pod in an enrolled namespace L4 mTLS and identity
# with no sidecar, so adoption costs nothing per pod and needs no restart.
# Waypoint proxies are added later, only where L7 policy is actually required.
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.3.0, < 4.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.5.0, < 4.0.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  exec_args = [
    "eks", "get-token",
    "--cluster-name", var.cluster_name,
    "--region", var.region,
    "--output", "json",
  ]
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

module "istio" {
  source = "../../"

  cluster_name = var.cluster_name

  mesh_mode     = "ambient"
  chart_version = "1.30.8"

  # Ambient requires the CNI node agent; without it, enrolled pods run outside
  # the mesh while appearing perfectly healthy.
  enable_cni = true

  # PERMISSIVE accepts both mTLS and plaintext while workloads are onboarded.
  # Move to STRICT once every caller is inside the mesh.
  mtls_mode = "PERMISSIVE"

  # Namespaces must already exist; this labels them, it does not create them.
  # Enrolment takes effect without restarting any pod.
  ambient_namespaces = ["apps"]

  # Keep the control plane on the statically provisioned system node group.
  node_selector = { "node.kubernetes.io/role" = "system" }
  tolerations = [{
    key      = "CriticalAddonsOnly"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]

  tags = {
    environment = "example"
  }
}

output "namespace_label_ambient" {
  description = "Apply this label to any other namespace to enrol it."
  value       = module.istio.namespace_label_ambient
}

output "istio_gateway_class_name" {
  description = "GatewayClass istiod reconciles, for Gateways terminated by Istio rather than by an ALB."
  value       = module.istio.istio_gateway_class_name
}
