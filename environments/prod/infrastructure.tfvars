###############################################################################
# prod - infrastructure layer
#
#   terraform -chdir=layers/infrastructure init \
#     -backend-config=../../environments/prod/infrastructure.backend.hcl
#   terraform -chdir=layers/infrastructure apply \
#     -var-file=../../environments/prod/infrastructure.tfvars
#
# Differences from dev are deliberate and listed in docs/architecture.md.
###############################################################################

name        = "platform"
environment = "prod"
region      = "eu-central-1"

allowed_account_ids = ["222222222222"]

# assume_role_arn = "arn:aws:iam::222222222222:role/terraform-deploy"

###############################################################################
# Networking
###############################################################################

create_networking = true

vpc_cidr = "10.20.0.0/16"
az_count = 3

# One NAT Gateway per AZ. Costs more than a single gateway but removes both the
# single point of failure and the cross-AZ data charge on all egress.
single_nat_gateway = false

enable_vpc_endpoints     = true
enable_flow_logs         = true
flow_logs_retention_days = 365

###############################################################################
# Cluster
###############################################################################

kubernetes_version = "1.37"

# Private endpoint only. The API server is unreachable from the internet.
endpoint_public_access       = false
endpoint_public_access_cidrs = []

# Cluster administration must not be tied to whichever principal the pipeline
# happens to run as. Grant access explicitly to named roles instead.
enable_cluster_creator_admin_permissions = false

access_entries = {
  platform_admins = {
    principal_arn = "arn:aws:iam::222222222222:role/CHANGE-ME-platform-admin"
    type          = "STANDARD"

    policy_associations = {
      admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  }

  # Read-only access for on-call engineers. Enough to diagnose an incident,
  # not enough to change anything during one.
  oncall_viewers = {
    principal_arn = "arn:aws:iam::222222222222:role/CHANGE-ME-oncall"
    type          = "STANDARD"

    policy_associations = {
      view = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  }
}

# --- Baseline compute -------------------------------------------------------
# Four on-demand Bottlerocket nodes of fixed baseline capacity for the platform
# controllers; Karpenter supplies everything elastic. Cluster Autoscaler is not
# used and this ASG carries no CA discovery tags.
#
# Three instance types enable a mixed instances policy pinned to 100% on-demand,
# so a single Insufficient Capacity Exception cannot strand the control plane's
# add-on layer. Baseline capacity is never Spot.
#
# min_size holds the floor: the ASG ignores desired_capacity after creation.
# max_size is headroom for instance refresh during an AMI roll, not autoscaling.
system_node_group_instance_types = ["m7i.large", "m7a.large", "m6i.large"]
system_node_group_min_size       = 4
system_node_group_max_size       = 8
system_node_group_desired_size   = 4

# Pinned to an exact Bottlerocket release. Bumping this value rolls the baseline
# nodes through an instance refresh, which is the intended upgrade path.
# Verify the AMI exists before changing it:
#   aws ssm get-parameter --region eu-central-1 \
#     --name /aws/service/bottlerocket/aws-k8s-1.37/x86_64/1.68.1/image_id
ami_type             = "BOTTLEROCKET_x86_64"
bottlerocket_version = "1.68.1"

node_os_disk_size   = 10
node_data_disk_size = 200

enable_karpenter = true

# Scope the DNS permissions to the zones this cluster actually owns.
external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/CHANGE-ME"]
cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/CHANGE-ME"]

tags = {
  CostCentre = "platform-engineering"
  Owner      = "platform-team"
  Compliance = "in-scope"
  DataClass  = "confidential"
}
