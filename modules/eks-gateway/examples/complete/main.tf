###############################################################################
# eks-gateway module - complete example
#
# Installs the Gateway API CRDs, the AWS Load Balancer Controller, ALB and NLB
# GatewayClasses, and one public Gateway terminating TLS on an ACM certificate.
#
# Run this against an existing cluster. modules/eks must already have created
# the Pod Identity association for the controller's service account.
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

variable "vpc_id" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener."
  type        = string
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

# The exec plugin fetches a fresh token at apply time. A token data source would
# write a short-lived bearer token into state in plaintext.
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

module "gateway" {
  source = "../../"

  cluster_name = var.cluster_name
  region       = var.region
  vpc_id       = var.vpc_id

  # Pinned to the version the controller is built against, not to the newest
  # Gateway API release.
  gateway_api_version = "v1.6.0"

  create_default_gateway_classes = true

  # Public entry point. The default is "internal"; making a Gateway reachable
  # from the internet should always be an explicit decision.
  default_scheme          = "internet-facing"
  default_certificate_arn = var.certificate_arn
  default_ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  # A shared Gateway owned by the platform team. Application teams attach to it
  # with HTTPRoute objects from their own namespaces and never need to create a
  # load balancer themselves.
  gateways = {
    public = {
      namespace          = "kube-system"
      gateway_class_name = "aws-alb"

      listeners = [{
        name     = "https"
        protocol = "HTTPS"
        port     = 443
        # Routes may attach from any namespace. Tighten to "Same" if each team
        # should own its own Gateway instead.
        allowed_routes_from = "All"
      }]
    }
  }

  tags = {
    Environment = "example"
  }
}

output "alb_gateway_class_name" {
  description = "Put this in spec.gatewayClassName on a Gateway."
  value       = module.gateway.alb_gateway_class_name
}

output "nlb_gateway_class_name" {
  value = module.gateway.nlb_gateway_class_name
}
