###############################################################################
# eks-addons module - complete example
#
# Karpenter plus the platform controllers. Run against an existing cluster
# whose IAM roles and Pod Identity associations were created by modules/eks.
###############################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59.0, < 7.0.0"
    }
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

variable "karpenter_queue_name" {
  description = "From the karpenter_queue_name output of modules/eks."
  type        = string
}

variable "karpenter_node_iam_role_name" {
  description = "From the karpenter_node_iam_role_name output of modules/eks."
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

module "addons" {
  source = "../../"

  cluster_name = var.cluster_name
  region       = var.region

  enable_karpenter             = true
  karpenter_queue_name         = var.karpenter_queue_name
  karpenter_node_iam_role_name = var.karpenter_node_iam_role_name

  # A starter NodePool so the cluster can scale out immediately. Set this false
  # once node pools are owned by a GitOps repository.
  create_default_node_pool = true

  node_pool_capacity_types = ["spot", "on-demand"]

  # The hard ceiling on scale-out, and the main cost guardrail.
  node_pool_cpu_limit = 200

  # "@latest" keeps nodes patched but changes without a Terraform diff. Pin to
  # a dated alias in production and roll it deliberately.
  node_pool_ami_alias = "al2023@latest"

  enable_cert_manager   = true
  enable_metrics_server = true

  enable_external_dns = true
  # Never leave this empty: an unfiltered external-dns acts on every hosted zone
  # its IAM role can reach.
  external_dns_domain_filters = ["example.com"]
  external_dns_policy         = "upsert-only"

  enable_argocd     = false
  enable_monitoring = false

  # Replaces the gp2 default with an encrypted gp3 class.
  create_gp3_storage_class = true

  tags = {
    Environment = "example"
  }
}

output "default_storage_class_name" {
  value = module.addons.default_storage_class_name
}

output "default_node_pool_name" {
  value = module.addons.default_node_pool_name
}
