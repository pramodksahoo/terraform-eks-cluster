
# Terraform Configuration
terraform {
  # note: s3 bucket and dynamodb table need to exist
  # on first run, uncomment the whole backend block and initialize with local state and lock,
  # rerun `terraform init` again after creating the resources to switch to remote state and locking

  backend "s3" {
    profile        = "example-s3-terraform" # change to your profile
    bucket         = "example-terraform-state" # change to your bucket
    key            = "example-example-cluster-tfstate/terraform.tfstate" # change to your key
    region         = "eu-central-1" # terraform does not allow for variables in backend
    dynamodb_table = "terraform-eks-dev-state-locking" # change to your dynamodb table
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.99.0"
    }
    null = {
      source = "hashicorp/null"
    }
    local = {
      source = "hashicorp/local"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
      version = "1.19.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "2.17.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
  }
}

# Local values for conditional aws-auth role configuration
locals {
  karpenter_manifest_full_path = "${path.module}/${var.karpenter_manifest_dir}"
  karpenter_yaml_files         = fileset(local.karpenter_manifest_full_path, "*.yaml")
  alb_ingress_manifest_full_path = "${path.module}/${var.alb_ingress_manifest_dir}"
  alb_ingress_yaml_files       = fileset(local.alb_ingress_manifest_full_path, "*.yaml")
  
  # Base aws-auth roles (pre-EKS)
  base_aws_auth_roles = var.enable_iam_roles ? [
    {
      rolearn  = aws_iam_role.karpenter_node_role[0].arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    },
    {
      rolearn  = aws_iam_role.prometheus_role[0].arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }
  ] : []

  # Post-EKS aws-auth roles (created after EKS cluster)
  post_eks_aws_auth_roles = var.enable_iam_roles ? [
    {
      rolearn  = aws_iam_role.karpenter_controller_role[0].arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }
  ] : []

  # Combined aws-auth roles
  all_aws_auth_roles = concat(var.aws_auth_roles, local.base_aws_auth_roles, local.post_eks_aws_auth_roles)
}