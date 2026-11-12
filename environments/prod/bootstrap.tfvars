###############################################################################
# prod - bootstrap layer
#
#   terraform -chdir=layers/bootstrap init \
#     -backend-config=../../environments/prod/bootstrap.backend.hcl
#   terraform -chdir=layers/bootstrap apply \
#     -var-file=../../environments/prod/bootstrap.tfvars
###############################################################################

environment         = "prod"
region              = "eu-central-1"
allowed_account_ids = ["222222222222"]

# assume_role_arn = "arn:aws:iam::222222222222:role/terraform-deploy"

infrastructure_state_bucket = "CHANGE-ME-terraform-state-prod"
infrastructure_state_key    = "eks-platform/prod/infrastructure.tfstate"
infrastructure_state_region = "eu-central-1"

###############################################################################
# Gateway API
###############################################################################

enable_gateway      = true
gateway_api_version = "v1.6.0"

gateway_default_scheme          = "internal"
gateway_default_certificate_arn = "arn:aws:acm:eu-central-1:222222222222:certificate/CHANGE-ME"

# Access logs are the only record of who reached the cluster from outside.
gateway_enable_access_logs = true
gateway_access_logs_bucket = "CHANGE-ME-elb-access-logs-prod"

###############################################################################
# Platform add-ons
###############################################################################

enable_karpenter = true

# Production workloads run on on-demand capacity by default. Move individual
# workloads onto spot with their own NodePool once they tolerate interruption.
karpenter_node_pool_capacity_types = ["on-demand"]
karpenter_node_pool_cpu_limit      = 2000

enable_cert_manager   = true
enable_metrics_server = true

enable_external_dns         = true
external_dns_domain_filters = ["example.com"]

# upsert-only never deletes a record. Move to "sync" only once this cluster is
# the sole writer of its hosted zone.
external_dns_policy = "upsert-only"

enable_argocd     = true
enable_monitoring = true

###############################################################################
# Istio
###############################################################################

enable_istio        = true
istio_mesh_mode     = "ambient"
istio_chart_version = "1.30.8"

# Start PERMISSIVE so existing plaintext traffic keeps working while workloads
# are onboarded, then switch to STRICT once every caller is in the mesh.
istio_mtls_mode = "PERMISSIVE"

istio_ambient_namespaces = []

tags = {
  CostCentre = "platform-engineering"
  Owner      = "platform-team"
}
