# `networking`

A VPC purpose-built for Amazon EKS: four subnet tiers, per-AZ NAT, interface
VPC endpoints, flow logs, and — critically — the discovery tags that EKS, the
AWS Load Balancer Controller and Karpenter rely on.

Use it when you are building a new environment. If your network team already
owns a VPC, skip this module entirely and pass your subnet IDs straight to
[`modules/eks`](../eks) — see
[Using an existing VPC](#using-an-existing-vpc) for the tags you will need.

---

## Contents

- [Why this module exists](#why-this-module-exists)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Subnet tiers](#subnet-tiers)
- [Address planning](#address-planning)
- [Discovery tags](#discovery-tags)
- [Cost controls](#cost-controls)
- [Using an existing VPC](#using-an-existing-vpc)
- [Integration](#integration)
- [Security notes](#security-notes)
- [Examples](#examples)
- [Generated reference](#requirements)

---

## Why this module exists

A generic VPC module gets you subnets. It does not get you a working EKS
cluster, because EKS, the load balancer controller and the autoscaler all
discover infrastructure by **tag**, and the failure mode when a tag is missing
is an error message that points nowhere near the cause:

| Missing tag | What actually breaks | Error you see |
|---|---|---|
| `kubernetes.io/role/elb` | Internet-facing load balancers | `could not find any suitable subnets for creating the ALB` |
| `kubernetes.io/role/internal-elb` | Internal load balancers | the same message, on an internal Gateway |
| `karpenter.sh/discovery` | Every Karpenter node launch | NodeClaims stay `Pending` forever with no events |

This module applies them from the cluster names you give it, so the class of
bug above cannot happen.

---

## Architecture

```
                         ┌──────────────── Internet ────────────────┐
                         │                                          │
                   ┌─────┴─────┐                             ┌──────┴──────┐
                   │    IGW    │                             │  Egress-only│
                   └─────┬─────┘                             │     IGW     │  (IPv6)
                         │                                   └──────┬──────┘
  ╔══════════════════════╪══════════════════════════════════════════╪═══════════════╗
  ║  VPC 10.0.0.0/16     │                                          │               ║
  ║                      │                                          │               ║
  ║   ┌──────────────────┴───────────┐  ┌───────────────┐  ┌────────┴────────┐      ║
  ║   │ public     (per AZ)          │  │               │  │                 │      ║
  ║   │  • NAT Gateway + EIP         │  │               │  │                 │      ║
  ║   │  • internet-facing ALB/NLB   │  │               │  │                 │      ║
  ║   │  kubernetes.io/role/elb=1    │  │               │  │                 │      ║
  ║   └──────────────┬───────────────┘  │               │  │                 │      ║
  ║                  │ 0.0.0.0/0        │               │  │                 │      ║
  ║   ┌──────────────┴───────────────┐  │               │  │                 │      ║
  ║   │ private    (per AZ)          │──┘               │  │                 │      ║
  ║   │  • worker nodes              │                  │  │                 │      ║
  ║   │  • Karpenter capacity        │                  │  │                 │      ║
  ║   │  • internal ALB/NLB          │                  │  │                 │      ║
  ║   │  karpenter.sh/discovery      │                  │  │                 │      ║
  ║   └──────────────────────────────┘                  │  │                 │      ║
  ║                                                     │  │                 │      ║
  ║   ┌──────────────────────────────┐  ┌───────────────┴──┴─────────────────┐      ║
  ║   │ database   (per AZ)          │  │ intra      (per AZ)                │      ║
  ║   │  • RDS / ElastiCache         │  │  • EKS control-plane ENIs          │      ║
  ║   │  • NO route off the VPC      │  │  • interface VPC endpoints         │      ║
  ║   └──────────────────────────────┘  │  • NO route off the VPC            │      ║
  ║                                     └────────────────────────────────────┘      ║
  ╚═══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | `>= 1.10.0` — the module uses `check` blocks and `optional()` object attributes |
| AWS provider | `>= 6.28.0, < 7.0.0` |
| IAM permissions | `ec2:*Vpc*`, `ec2:*Subnet*`, `ec2:*RouteTable*`, `ec2:*NatGateway*`, `ec2:*InternetGateway*`, `ec2:*Address*`, `ec2:*VpcEndpoint*`, `ec2:*FlowLogs*`, `ec2:*Tags*`, plus `logs:*` and `iam:*Role*` when flow logs are enabled |
| Service quotas | Default limits are 5 VPCs, 5 Elastic IPs and 5 NAT Gateways per region. Three AZs with per-AZ NAT uses 3 of each |

---

## Quick start

```hcl
module "networking" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/networking?ref=networking-v1.0.0"

  name     = "platform-prod"
  vpc_cidr = "10.0.0.0/16"
  az_count = 3

  create_intra_subnets    = true
  create_database_subnets = true

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_vpc_endpoints = true
  enable_flow_logs     = true

  # Applies every discovery tag the cluster and its controllers need.
  eks_cluster_names         = ["platform-prod"]
  karpenter_discovery_value = "platform-prod"

  tags = {
    Environment = "prod"
    Owner       = "platform-team"
  }
}
```

---

## Subnet tiers

| Tier | Default route | Purpose | Why separate |
|---|---|---|---|
| `public` | IGW | NAT Gateways, internet-facing load balancers | The only tier with a path from the internet |
| `private` | NAT Gateway | Worker nodes, Karpenter capacity, internal load balancers | Egress without ingress |
| `database` | none | RDS, ElastiCache | A compromised database cannot call out, which removes the exfiltration path |
| `intra` | none | EKS control-plane ENIs, interface VPC endpoints | Survives a NAT Gateway failure and cannot be used as an egress path |

The `intra` tier is the one most VPC designs omit. Putting the control-plane
ENIs and the VPC endpoints there means that when a NAT Gateway fails, the
cluster API and the endpoint-served AWS APIs keep working — only outbound
internet access is lost.

Set `create_database_subnets = false` or `create_intra_subnets = false` to skip
a tier. The address plan still reserves its space, so enabling it later does not
renumber the other tiers.

---

## Address planning

CIDRs are derived automatically. With the defaults — a `/16` VPC,
`subnet_newbits = 4` and three AZs — the layout is:

| Tier | AZ a | AZ b | AZ c |
|---|---|---|---|
| public | `10.0.0.0/20` | `10.0.16.0/20` | `10.0.32.0/20` |
| private | `10.0.48.0/20` | `10.0.64.0/20` | `10.0.80.0/20` |
| database | `10.0.96.0/20` | `10.0.112.0/20` | `10.0.128.0/20` |
| intra | `10.0.144.0/20` | `10.0.160.0/20` | `10.0.176.0/20` |

Four tiers × `az_count` subnets must fit in `2^subnet_newbits`. A `check` block
asserts this and fails the plan with an explanatory message rather than
producing overlapping subnets.

Override any tier explicitly with `public_subnet_cidrs`,
`private_subnet_cidrs`, `database_subnet_cidrs` or `intra_subnet_cidrs` when you
are fitting into an existing address plan.

> **Sizing note.** With the AWS VPC CNI, every pod consumes a VPC address. A
> `/20` private subnet holds roughly 4 000 addresses; at ~30 pods per node that
> is around 130 nodes per AZ. If you expect more, widen `vpc_cidr` or reduce
> `subnet_newbits` — this is very hard to change once workloads are running.

---

## Discovery tags

Applied automatically from `eks_cluster_names` and `karpenter_discovery_value`:

| Tag | Applied to | Consumer |
|---|---|---|
| `kubernetes.io/cluster/<name>` = `shared` | all subnets | EKS |
| `kubernetes.io/role/elb` = `1` | public subnets | AWS Load Balancer Controller |
| `kubernetes.io/role/internal-elb` = `1` | private subnets | AWS Load Balancer Controller |
| `karpenter.sh/discovery` = `<value>` | private subnets | Karpenter |

Pass **every** cluster name that will live in the VPC. Tags are additive, so
multiple clusters can share subnets.

---

## Cost controls

NAT Gateways usually dominate the bill for a VPC of this shape.

| Setting | Monthly order of magnitude (eu-central-1, 3 AZ) | Trade-off |
|---|---|---|
| `single_nat_gateway = true` | ~1× NAT hourly | Single point of failure; every byte of egress crosses an AZ boundary and is charged |
| `single_nat_gateway = false` | ~3× NAT hourly | No SPOF, no cross-AZ egress charge |
| `enable_vpc_endpoints = true` | ~13 endpoints × 3 AZ hourly | Removes ECR, S3, STS and CloudWatch traffic from NAT data charges entirely, and keeps it off the public internet |

The S3 and DynamoDB **gateway** endpoints are free and always worth enabling —
container image layer pulls from ECR go to S3, which is frequently the single
largest NAT data line item.

For a development VPC, `single_nat_gateway = true` with
`enable_vpc_endpoints = false` is the cheapest sensible combination. For
production, invert both.

---

## Using an existing VPC

If you do not use this module, the cluster still needs the tags it would have
applied. Apply them to your own subnets before creating the cluster:

```bash
CLUSTER=platform-prod

# Every subnet handed to the cluster
aws ec2 create-tags --resources subnet-aaa subnet-bbb subnet-ccc \
  --tags Key=kubernetes.io/cluster/$CLUSTER,Value=shared

# Public subnets
aws ec2 create-tags --resources subnet-pub-a subnet-pub-b \
  --tags Key=kubernetes.io/role/elb,Value=1

# Private subnets
aws ec2 create-tags --resources subnet-prv-a subnet-prv-b \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 \
         Key=karpenter.sh/discovery,Value=$CLUSTER
```

Your subnets must also:

- span **at least two** Availability Zones;
- have **outbound internet access** from the private tier, through a NAT
  Gateway or a complete set of VPC endpoints — nodes cannot join without it;
- have `enableDnsSupport` and `enableDnsHostnames` set on the VPC.

Then set `create_networking = false` in `layers/infrastructure`. See
[`environments/dev/infrastructure.existing-vpc.tfvars.example`](../../environments/dev/infrastructure.existing-vpc.tfvars.example).

---

## Integration

The `eks_network_config` output is a single object shaped for `modules/eks`:

```hcl
module "networking" {
  source = "../../modules/networking"
  # ...
}

module "eks" {
  source = "../../modules/eks"

  cluster_name = "platform-prod"

  vpc_id                   = module.networking.vpc_id
  subnet_ids               = module.networking.private_subnet_ids
  control_plane_subnet_ids = module.networking.intra_subnet_ids
  public_subnet_ids        = module.networking.public_subnet_ids
}
```

Consuming the module from another repository:

```hcl
source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/networking?ref=networking-v1.0.0"
```

Always pin `ref` to a tag. Tags are prefixed per module (`networking-v1.0.0`,
`eks-v1.0.0`), so each module versions independently inside the monorepo.

---

## Security notes

- **Default security group is emptied.** `manage_default_security_group`
  removes every ingress and egress rule from the VPC's default SG (CIS AWS
  Foundations 5.4). Anything that lands on it by accident has no connectivity,
  which is a far better failure mode than inheriting an allow-all rule.
- **Default NACL is managed** so it cannot drift to something permissive.
- **VPC endpoints use a dedicated security group** that accepts HTTPS only,
  and only from the VPC CIDR.
- **Flow logs** are on by default with a scoped IAM role carrying
  `aws:SourceAccount` and `aws:SourceArn` conditions to prevent confused-deputy
  abuse.
- **Database and intra subnets have no default route**, so nothing in them can
  reach the internet even if a security group is misconfigured.

---

## Examples

| Example | Description |
|---|---|
| [`complete`](examples/complete) | Three AZs, four tiers, per-AZ NAT, endpoints, flow logs |
| [`minimal`](examples/minimal) | Two AZs, two tiers, one NAT — development only |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.28.0, < 7.0.0 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_default_network_acl.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_network_acl) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_egress_only_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/egress_only_internet_gateway) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_ipv6_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.private_nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_internet_ipv6](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_security_group.vpc_endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.dynamodb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_ipv4_cidr_block_association.secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_ipv4_cidr_block_association) | resource |
| [aws_vpc_security_group_ingress_rule.vpc_endpoints_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.vpc_endpoints_https_ipv6](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.vpc_endpoints_https_secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | Name prefix applied to every networking resource. Typically the platform or cluster name, e.g. `platform-dev`. | `string` | n/a | yes |
| <a name="input_az_count"></a> [az\_count](#input\_az\_count) | Number of Availability Zones to use when `azs` is not explicitly supplied. | `number` | `3` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | Availability Zone names to span, e.g. `["eu-central-1a", "eu-central-1b", "eu-central-1c"]`.<br/>Leave empty to automatically select the first `az_count` AZs that support EKS in the<br/>current region. Three AZs are strongly recommended for production. | `list(string)` | `[]` | no |
| <a name="input_create_database_subnets"></a> [create\_database\_subnets](#input\_create\_database\_subnets) | Create the isolated database subnet tier and an associated DB subnet group. | `bool` | `true` | no |
| <a name="input_create_intra_subnets"></a> [create\_intra\_subnets](#input\_create\_intra\_subnets) | Create the intra (fully isolated, no NAT) subnet tier used for EKS control-plane ENIs and interface endpoints. | `bool` | `true` | no |
| <a name="input_database_subnet_cidrs"></a> [database\_subnet\_cidrs](#input\_database\_subnet\_cidrs) | Explicit CIDR blocks for the isolated database subnet tier. Leave empty to derive automatically. Set `create_database_subnets = false` to skip this tier entirely. | `list(string)` | `[]` | no |
| <a name="input_eks_cluster_names"></a> [eks\_cluster\_names](#input\_eks\_cluster\_names) | Names of the EKS clusters that will consume these subnets. The module applies the<br/>`kubernetes.io/cluster/<name> = shared` tag for each entry so that the AWS Load Balancer<br/>Controller and the in-tree cloud provider can discover the subnets. Safe to leave empty<br/>and set later; the ELB role tags below are applied regardless. | `list(string)` | `[]` | no |
| <a name="input_enable_dns_hostnames"></a> [enable\_dns\_hostnames](#input\_enable\_dns\_hostnames) | Enable DNS hostnames in the VPC. Must remain true for EKS private endpoint resolution to work. | `bool` | `true` | no |
| <a name="input_enable_dns_support"></a> [enable\_dns\_support](#input\_enable\_dns\_support) | Enable DNS resolution in the VPC. Must remain true for EKS. | `bool` | `true` | no |
| <a name="input_enable_dynamodb_gateway_endpoint"></a> [enable\_dynamodb\_gateway\_endpoint](#input\_enable\_dynamodb\_gateway\_endpoint) | Create the free DynamoDB gateway VPC endpoint. | `bool` | `false` | no |
| <a name="input_enable_egress_only_internet_gateway"></a> [enable\_egress\_only\_internet\_gateway](#input\_enable\_egress\_only\_internet\_gateway) | Create an egress-only internet gateway so IPv6 workloads in private subnets can reach the internet. Only used when `enable_ipv6` is true. | `bool` | `true` | no |
| <a name="input_enable_flow_logs"></a> [enable\_flow\_logs](#input\_enable\_flow\_logs) | Enable VPC Flow Logs. Required by CIS AWS Foundations Benchmark control 3.9 and by most audit regimes. | `bool` | `true` | no |
| <a name="input_enable_ipv6"></a> [enable\_ipv6](#input\_enable\_ipv6) | Associate an Amazon-provided /56 IPv6 CIDR with the VPC and assign /64 blocks to each subnet. | `bool` | `false` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Provision NAT Gateways so that private subnets can reach the internet for image pulls and API calls. | `bool` | `true` | no |
| <a name="input_enable_s3_gateway_endpoint"></a> [enable\_s3\_gateway\_endpoint](#input\_enable\_s3\_gateway\_endpoint) | Create the free S3 gateway VPC endpoint. Strongly recommended: ECR image layers are stored in S3. | `bool` | `true` | no |
| <a name="input_enable_vpc_endpoints"></a> [enable\_vpc\_endpoints](#input\_enable\_vpc\_endpoints) | Create VPC endpoints for the AWS services an EKS cluster depends on. This keeps traffic<br/>on the AWS backbone, removes the NAT data-processing charge for those calls, and is a<br/>hard requirement for fully private clusters. | `bool` | `true` | no |
| <a name="input_flow_logs_destination_arn"></a> [flow\_logs\_destination\_arn](#input\_flow\_logs\_destination\_arn) | ARN of an existing S3 bucket or CloudWatch log group to deliver flow logs to. Leave empty to have the module create a CloudWatch log group. | `string` | `""` | no |
| <a name="input_flow_logs_destination_type"></a> [flow\_logs\_destination\_type](#input\_flow\_logs\_destination\_type) | Where to deliver VPC Flow Logs. `s3` is substantially cheaper for high-volume VPCs; `cloud-watch-logs` is easier to query interactively. | `string` | `"cloud-watch-logs"` | no |
| <a name="input_flow_logs_kms_key_arn"></a> [flow\_logs\_kms\_key\_arn](#input\_flow\_logs\_kms\_key\_arn) | KMS key ARN used to encrypt the module-created CloudWatch flow log group. Leave empty to use the AWS-managed CloudWatch Logs key. | `string` | `""` | no |
| <a name="input_flow_logs_retention_days"></a> [flow\_logs\_retention\_days](#input\_flow\_logs\_retention\_days) | Retention in days for the module-created CloudWatch flow log group. | `number` | `90` | no |
| <a name="input_flow_logs_traffic_type"></a> [flow\_logs\_traffic\_type](#input\_flow\_logs\_traffic\_type) | Which traffic to capture in flow logs: ACCEPT, REJECT or ALL. | `string` | `"ALL"` | no |
| <a name="input_intra_subnet_cidrs"></a> [intra\_subnet\_cidrs](#input\_intra\_subnet\_cidrs) | Explicit CIDR blocks for the intra subnet tier. Intra subnets have no route to the<br/>internet at all and are used for EKS control-plane cross-account ENIs and VPC<br/>endpoints. Leave empty to derive automatically. | `list(string)` | `[]` | no |
| <a name="input_karpenter_discovery_value"></a> [karpenter\_discovery\_value](#input\_karpenter\_discovery\_value) | Value for the `karpenter.sh/discovery` tag applied to private subnets. Karpenter<br/>EC2NodeClass `subnetSelectorTerms` match on this tag. Conventionally the cluster name.<br/>Leave empty to skip Karpenter subnet tagging. | `string` | `""` | no |
| <a name="input_manage_default_network_acl"></a> [manage\_default\_network\_acl](#input\_manage\_default\_network\_acl) | Take ownership of the VPC default network ACL and apply a documented baseline rule set. | `bool` | `true` | no |
| <a name="input_manage_default_security_group"></a> [manage\_default\_security\_group](#input\_manage\_default\_security\_group) | Take ownership of the VPC default security group and strip every ingress and egress<br/>rule from it. Required by CIS AWS Foundations Benchmark control 5.4. | `bool` | `true` | no |
| <a name="input_map_public_ip_on_launch"></a> [map\_public\_ip\_on\_launch](#input\_map\_public\_ip\_on\_launch) | Auto-assign public IPv4 addresses to instances launched in public subnets. Keep false unless you knowingly run public-facing EC2 instances. | `bool` | `false` | no |
| <a name="input_private_subnet_cidrs"></a> [private\_subnet\_cidrs](#input\_private\_subnet\_cidrs) | Explicit CIDR blocks for the private application subnet tier (where EKS nodes and pods run). Leave empty to derive automatically. | `list(string)` | `[]` | no |
| <a name="input_private_subnet_tags"></a> [private\_subnet\_tags](#input\_private\_subnet\_tags) | Extra tags merged onto private subnets, in addition to the internal-ELB and Karpenter discovery tags the module always applies. | `map(string)` | `{}` | no |
| <a name="input_public_subnet_cidrs"></a> [public\_subnet\_cidrs](#input\_public\_subnet\_cidrs) | Explicit CIDR blocks for the public subnet tier. Leave empty to derive them automatically from `vpc_cidr`. | `list(string)` | `[]` | no |
| <a name="input_public_subnet_tags"></a> [public\_subnet\_tags](#input\_public\_subnet\_tags) | Extra tags merged onto public subnets, in addition to the ELB discovery tags the module always applies. | `map(string)` | `{}` | no |
| <a name="input_secondary_cidr_blocks"></a> [secondary\_cidr\_blocks](#input\_secondary\_cidr\_blocks) | Additional IPv4 CIDR blocks to associate with the VPC. Commonly used with the<br/>AWS VPC CNI custom networking feature to place pods in a non-routable<br/>100.64.0.0/10 range, preserving RFC1918 space for nodes and load balancers.<br/>Leave empty to disable. | `list(string)` | `[]` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Deploy exactly one NAT Gateway shared by every private subnet instead of one per AZ.<br/>Saves roughly two thirds of the NAT hourly cost but creates a single point of failure<br/>and cross-AZ data transfer charges. Acceptable for dev, never for production. | `bool` | `false` | no |
| <a name="input_subnet_newbits"></a> [subnet\_newbits](#input\_subnet\_newbits) | Number of additional bits used when automatically carving subnets out of `vpc_cidr`<br/>via `cidrsubnet`. With a /16 VPC and the default of 4 you get /20 subnets<br/>(4091 usable IPs each). Ignored for any tier where an explicit CIDR list is supplied. | `number` | `4` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource created by this module. | `map(string)` | `{}` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | Primary IPv4 CIDR block for the VPC. A /16 is recommended so that pod IP exhaustion is not hit when using the AWS VPC CNI. | `string` | `"10.0.0.0/16"` | no |
| <a name="input_vpc_endpoint_services"></a> [vpc\_endpoint\_services](#input\_vpc\_endpoint\_services) | Interface endpoint service short names to create when `enable_vpc_endpoints` is true.<br/>`eks-auth` is required for EKS Pod Identity to work on nodes in private subnets.<br/>S3 and DynamoDB are always created as free gateway endpoints and must not be listed here. | `list(string)` | <pre>[<br/>  "ec2",<br/>  "ecr.api",<br/>  "ecr.dkr",<br/>  "eks",<br/>  "eks-auth",<br/>  "elasticloadbalancing",<br/>  "sts",<br/>  "logs",<br/>  "ssm",<br/>  "ssmmessages",<br/>  "ec2messages",<br/>  "kms",<br/>  "autoscaling",<br/>  "sqs"<br/>]</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_azs"></a> [azs](#output\_azs) | Availability Zones the VPC spans. |
| <a name="output_database_route_table_id"></a> [database\_route\_table\_id](#output\_database\_route\_table\_id) | ID of the database route table, or null when database subnets are disabled. |
| <a name="output_database_subnet_group_name"></a> [database\_subnet\_group\_name](#output\_database\_subnet\_group\_name) | Name of the RDS DB subnet group, or null when database subnets are disabled. |
| <a name="output_database_subnet_ids"></a> [database\_subnet\_ids](#output\_database\_subnet\_ids) | IDs of the isolated database subnets. Empty when create\_database\_subnets is false. |
| <a name="output_default_security_group_id"></a> [default\_security\_group\_id](#output\_default\_security\_group\_id) | ID of the VPC default security group. It has no rules and must not be used. |
| <a name="output_eks_network_config"></a> [eks\_network\_config](#output\_eks\_network\_config) | Pre-assembled networking inputs for the eks module. Pass as `var.network` or splat into individual arguments. |
| <a name="output_flow_log_group_name"></a> [flow\_log\_group\_name](#output\_flow\_log\_group\_name) | Name of the CloudWatch log group created for flow logs, or null. |
| <a name="output_flow_log_id"></a> [flow\_log\_id](#output\_flow\_log\_id) | ID of the VPC flow log, or null when disabled. |
| <a name="output_interface_vpc_endpoint_ids"></a> [interface\_vpc\_endpoint\_ids](#output\_interface\_vpc\_endpoint\_ids) | Map of interface endpoint service short name to endpoint ID. |
| <a name="output_internet_gateway_id"></a> [internet\_gateway\_id](#output\_internet\_gateway\_id) | ID of the internet gateway. |
| <a name="output_intra_route_table_id"></a> [intra\_route\_table\_id](#output\_intra\_route\_table\_id) | ID of the intra route table, or null when intra subnets are disabled. |
| <a name="output_intra_subnet_ids"></a> [intra\_subnet\_ids](#output\_intra\_subnet\_ids) | IDs of the fully isolated intra subnets. Pass these to the EKS module as control\_plane\_subnet\_ids. |
| <a name="output_nat_gateway_ids"></a> [nat\_gateway\_ids](#output\_nat\_gateway\_ids) | IDs of the NAT Gateways. |
| <a name="output_nat_public_ips"></a> [nat\_public\_ips](#output\_nat\_public\_ips) | Elastic IPs of the NAT Gateways. Add these to partner allow-lists for outbound traffic. |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | IDs of the per-AZ private route tables. |
| <a name="output_private_subnet_arns"></a> [private\_subnet\_arns](#output\_private\_subnet\_arns) | ARNs of the private application subnets. |
| <a name="output_private_subnet_cidr_blocks"></a> [private\_subnet\_cidr\_blocks](#output\_private\_subnet\_cidr\_blocks) | CIDR blocks of the private application subnets. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | IDs of the private application subnets. Pass these to the EKS module as the node and cluster subnets. |
| <a name="output_public_route_table_id"></a> [public\_route\_table\_id](#output\_public\_route\_table\_id) | ID of the shared public route table. |
| <a name="output_public_subnet_arns"></a> [public\_subnet\_arns](#output\_public\_subnet\_arns) | ARNs of the public subnets. |
| <a name="output_public_subnet_cidr_blocks"></a> [public\_subnet\_cidr\_blocks](#output\_public\_subnet\_cidr\_blocks) | CIDR blocks of the public subnets. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | IDs of the public subnets. Use for internet-facing load balancers. |
| <a name="output_s3_vpc_endpoint_id"></a> [s3\_vpc\_endpoint\_id](#output\_s3\_vpc\_endpoint\_id) | ID of the S3 gateway endpoint, or null when disabled. |
| <a name="output_vpc_arn"></a> [vpc\_arn](#output\_vpc\_arn) | ARN of the VPC. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | Primary IPv4 CIDR block of the VPC. |
| <a name="output_vpc_endpoint_security_group_id"></a> [vpc\_endpoint\_security\_group\_id](#output\_vpc\_endpoint\_security\_group\_id) | ID of the security group attached to the interface VPC endpoints. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC. |
| <a name="output_vpc_ipv6_cidr_block"></a> [vpc\_ipv6\_cidr\_block](#output\_vpc\_ipv6\_cidr\_block) | IPv6 CIDR block of the VPC, or null when IPv6 is disabled. |
| <a name="output_vpc_secondary_cidr_blocks"></a> [vpc\_secondary\_cidr\_blocks](#output\_vpc\_secondary\_cidr\_blocks) | Secondary IPv4 CIDR blocks associated with the VPC. |
<!-- END_TF_DOCS -->
