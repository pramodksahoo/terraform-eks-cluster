###############################################################################
# dev - infrastructure layer
#
#   terraform -chdir=layers/infrastructure init \
#     -backend-config=../../environments/dev/infrastructure.backend.hcl
#   terraform -chdir=layers/infrastructure apply \
#     -var-file=../../environments/dev/infrastructure.tfvars
###############################################################################

name        = "platform"
environment = "dev"
region      = "eu-central-1"

# Replace with the development account ID. Terraform refuses to plan against
# any other account, which is the cheapest guard against a stale variable file
# pointing this pipeline at production.
allowed_account_ids = ["111111111111"]

# Multi-account: uncomment to have the pipeline cross into the dev account
# through a role rather than holding credentials for it.
# assume_role_arn = "arn:aws:iam::111111111111:role/terraform-deploy"

###############################################################################
# Networking
#
# create_networking = true builds the VPC here. Set it to false and fill in the
# existing_* variables to deploy into a VPC another team owns; see
# environments/dev/infrastructure.existing-vpc.tfvars.example.
###############################################################################

create_networking = true

vpc_cidr = "10.10.0.0/16"
az_count = 3

# One NAT Gateway for the whole VPC. Saves roughly two thirds of the NAT hourly
# cost, at the price of a single point of failure and cross-AZ data charges.
# Acceptable in dev, not in production.
single_nat_gateway = true

enable_vpc_endpoints     = true
enable_flow_logs         = true
flow_logs_retention_days = 30

###############################################################################
# Cluster
###############################################################################

kubernetes_version = "1.37"

# Private API endpoint. Reach it from a bastion, a VPN, or a CI runner inside
# the VPC. To open it temporarily, set endpoint_public_access = true AND narrow
# endpoint_public_access_cidrs — an unrestricted 0.0.0.0/0 is rejected.
endpoint_public_access       = false
endpoint_public_access_cidrs = []

enable_cluster_creator_admin_permissions = true

# --- Baseline compute -------------------------------------------------------
# A fixed self-managed ASG on Bottlerocket carries the platform controllers.
# Karpenter adds spot and on-demand capacity as pods demand it. Cluster
# Autoscaler is not used, and this ASG carries no CA discovery tags.
#
# min_size is what holds the floor: the ASG ignores desired_capacity after
# creation, so changing desired_size alone has no effect.
system_node_group_instance_types = ["m7i.large", "m7a.large"]
system_node_group_min_size       = 2
system_node_group_max_size       = 4
system_node_group_desired_size   = 2

# Pinned, not "latest": an unpinned AMI would roll every baseline node whenever
# AWS publishes a new Bottlerocket release. Confirm a version resolves first:
#   aws ssm get-parameter --region eu-central-1 \
#     --name /aws/service/bottlerocket/aws-k8s-1.37/x86_64/1.68.1/image_id
ami_type             = "BOTTLEROCKET_x86_64"
bottlerocket_version = "1.68.1"

node_os_disk_size   = 10
node_data_disk_size = 100

enable_karpenter = true

tags = {
  CostCentre = "platform-engineering"
  Owner      = "platform-team"
}
