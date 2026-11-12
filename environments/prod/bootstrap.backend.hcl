# Backend configuration for the prod bootstrap layer.
#
#   terraform init -backend-config=../../environments/prod/bootstrap.backend.hcl

bucket = "CHANGE-ME-terraform-state-prod"
key    = "eks-platform/prod/bootstrap.tfstate"
region = "eu-central-1"

use_lockfile = true
encrypt      = true
