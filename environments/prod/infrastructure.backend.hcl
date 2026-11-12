# Backend configuration for the prod infrastructure layer.
#
#   terraform init -backend-config=../../environments/prod/infrastructure.backend.hcl

bucket = "CHANGE-ME-terraform-state-prod"
key    = "eks-platform/prod/infrastructure.tfstate"
region = "eu-central-1"

use_lockfile = true
encrypt      = true

# Uncomment when state lives in a shared tooling account.
# role_arn = "arn:aws:iam::222222222222:role/terraform-state-access"
