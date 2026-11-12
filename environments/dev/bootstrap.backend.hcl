# Backend configuration for the dev bootstrap layer.
#
#   terraform init -backend-config=../../environments/dev/bootstrap.backend.hcl

bucket = "CHANGE-ME-terraform-state-dev"
key    = "eks-platform/dev/bootstrap.tfstate"
region = "eu-central-1"

use_lockfile = true
encrypt      = true
