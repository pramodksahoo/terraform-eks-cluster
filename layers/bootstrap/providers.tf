###############################################################################
# Providers
#
# This layer exists specifically so that the kubernetes, helm and kubectl
# providers can be configured from values that are already known before the
# apply starts. They are read out of the infrastructure layer's state rather
# than from a resource in this configuration, which is what makes plan and
# destroy behave predictably.
#
# Authentication uses the AWS CLI exec plugin rather than a token data source.
# A token data source writes a short-lived bearer token into state in plaintext,
# where it both leaks and expires; the exec plugin fetches a fresh token at
# apply time and stores nothing.
###############################################################################

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [1]

    content {
      role_arn     = var.assume_role_arn
      session_name = "terraform-bootstrap-${var.environment}"
      external_id  = var.assume_role_external_id
    }
  }

  allowed_account_ids = var.allowed_account_ids
}

locals {
  cluster = data.terraform_remote_state.infrastructure.outputs.cluster_connection

  # Arguments for `aws eks get-token`. When the infrastructure layer assumes a
  # role to reach the target account, the token must be minted with that same
  # role, or the resulting credentials will not match any access entry.
  exec_args = concat(
    [
      "eks",
      "get-token",
      "--cluster-name", local.cluster.cluster_name,
      "--region", local.cluster.region,
      "--output", "json",
    ],
    var.assume_role_arn == null ? [] : ["--role-arn", var.assume_role_arn],
  )
}

provider "kubernetes" {
  host                   = local.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)
  load_config_file       = false
  apply_retry_count      = 3

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}
