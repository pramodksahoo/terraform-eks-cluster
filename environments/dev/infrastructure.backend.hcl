# Backend configuration for the dev infrastructure layer.
#
#   terraform init -backend-config=../../environments/dev/infrastructure.backend.hcl
#
# Kept out of versions.tf so the same code targets a different account, region
# or bucket per environment without editing tracked Terraform files.

bucket = "CHANGE-ME-terraform-state-dev"
key    = "eks-platform/dev/infrastructure.tfstate"
region = "eu-central-1"

# S3 native locking. Replaces the DynamoDB lock table, which is deprecated.
# Do not add a dynamodb_table argument.
use_lockfile = true

# The state bucket must have versioning enabled and default encryption turned
# on. State contains enough detail about the environment to be treated as
# sensitive even when no secret values are stored in it.
encrypt = true

# Uncomment when state lives in a shared tooling account.
# role_arn = "arn:aws:iam::111111111111:role/terraform-state-access"
