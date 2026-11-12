terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59.0, < 7.0.0"
    }
  }

  # Backend configuration is deliberately left partial. Supply it at init time
  # so the same code can target a different account, region or bucket per
  # environment without editing tracked files:
  #
  #   terraform init -backend-config=../../environments/dev/backend.hcl
  #
  # S3 native locking (use_lockfile) replaces the DynamoDB lock table, which is
  # deprecated. Do not reintroduce dynamodb_table.
  backend "s3" {}
}
