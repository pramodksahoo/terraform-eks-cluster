###############################################################################
# dev - bootstrap layer
#
#   terraform -chdir=layers/bootstrap init \
#     -backend-config=../../environments/dev/bootstrap.backend.hcl
#   terraform -chdir=layers/bootstrap apply \
#     -var-file=../../environments/dev/bootstrap.tfvars
#
# Apply this only after the infrastructure layer has succeeded: it reads that
# layer's state to configure the Kubernetes providers.
###############################################################################

environment         = "dev"
region              = "eu-central-1"
allowed_account_ids = ["111111111111"]

# Must match the infrastructure layer, or the EKS token will be minted for a
# different principal and every Kubernetes call will be denied.
# assume_role_arn = "arn:aws:iam::111111111111:role/terraform-deploy"

###############################################################################
# Remote state
###############################################################################

infrastructure_state_bucket = "CHANGE-ME-terraform-state-dev"
infrastructure_state_key    = "eks-platform/dev/infrastructure.tfstate"
infrastructure_state_region = "eu-central-1"

###############################################################################
# Gateway API
###############################################################################

enable_gateway      = true
gateway_api_version = "v1.6.0"

# Internal load balancers by default. Making a Gateway public should be a
# deliberate act, not the result of an omitted field.
gateway_default_scheme = "internal"

# ACM certificate for HTTPS listeners. The AWS Load Balancer Controller does not
# read certificates from a Gateway listener's certificateRefs.
# gateway_default_certificate_arn = "arn:aws:acm:eu-central-1:111111111111:certificate/CHANGE-ME"

###############################################################################
# Platform add-ons
###############################################################################

enable_karpenter                   = true
karpenter_node_pool_capacity_types = ["spot", "on-demand"]
karpenter_node_pool_cpu_limit      = 200

enable_cert_manager   = true
enable_metrics_server = true

enable_external_dns = true
# Always scope this. An unfiltered external-dns acts on every hosted zone its
# IAM role can reach, which is how one cluster deletes another's records.
external_dns_domain_filters = ["dev.example.com"]
external_dns_policy         = "upsert-only"

enable_argocd     = false
enable_monitoring = false

###############################################################################
# Istio
###############################################################################

enable_istio        = false
istio_mesh_mode     = "ambient"
istio_chart_version = "1.30.8"
istio_mtls_mode     = "PERMISSIVE"
