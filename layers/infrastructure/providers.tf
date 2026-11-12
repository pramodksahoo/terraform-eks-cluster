###############################################################################
# Provider
#
# Multi-account is handled with assume_role rather than with per-account
# credentials: the pipeline authenticates once, as a single identity, and
# crosses into the target account through a role. No long-lived access keys
# exist anywhere in this configuration.
###############################################################################

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [1]

    content {
      role_arn     = var.assume_role_arn
      session_name = "terraform-${var.environment}-${var.name}"

      # The external ID defends the target role against the confused-deputy
      # problem: knowing the role ARN is not enough to assume it.
      external_id = var.assume_role_external_id
    }
  }

  default_tags {
    tags = local.default_tags
  }

  # Guards against pointing a pipeline at the wrong account. The apply fails
  # before touching anything rather than creating a VPC in production because a
  # variable file was stale.
  allowed_account_ids = var.allowed_account_ids
}
