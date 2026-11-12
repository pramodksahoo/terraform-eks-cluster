# networking — complete example

A production-shaped VPC in `eu-central-1`: three availability zones, four subnet
tiers, one NAT Gateway per AZ, interface VPC endpoints, flow logs, and the
discovery tags EKS, the AWS Load Balancer Controller and Karpenter depend on.
Use this as the starting point for a new environment that will host an EKS
cluster.

## What this creates

| Component | Detail |
|---|---|
| VPC | `10.0.0.0/16`, three AZs |
| Public subnets | NAT Gateways and internet-facing load balancers, tagged `kubernetes.io/role/elb=1` |
| Private subnets | Worker nodes, tagged `kubernetes.io/role/internal-elb=1` and `karpenter.sh/discovery=example-complete-eks` |
| Intra subnets | Control-plane ENIs and interface VPC endpoints, no NAT route |
| Database subnets | RDS and ElastiCache, plus a DB subnet group, no route off the VPC |
| NAT Gateways | One per AZ (`single_nat_gateway = false`) |
| VPC endpoints | S3 gateway endpoint plus interface endpoints for ECR, STS, CloudWatch and friends |
| Flow logs | CloudWatch Logs, `ALL` traffic, 365-day retention |

Outputs: `eks_network_config` (pass straight into [`modules/eks`](../../../eks/README.md)),
`vpc_id`, and `nat_public_ips` — the cluster's stable egress addresses, which is
what you hand to anyone allow-listing outbound traffic.

## Usage

```bash
terraform init
terraform plan
terraform apply
```

No prerequisites beyond AWS credentials with VPC, EC2 and CloudWatch Logs
permissions. This example provisions AWS resources only, so it belongs to the
infrastructure layer; nothing here touches a Kubernetes API.

The module source is the local relative path `../../`. When consuming the module
from your own configuration, use the tagged git source instead so you get a
pinned, immutable version:

```hcl
module "networking" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/networking?ref=networking-v1.0.0"
  # ...
}
```

## Notes

| Decision | Why |
|---|---|
| `az_count = 3` | The smallest spread that survives the loss of one AZ without losing quorum for anything that needs a majority. |
| `single_nat_gateway = false` | Egress stays inside its AZ: no cross-AZ data charges, and one gateway failure does not remove egress for the whole VPC. |
| `create_intra_subnets = true` | Control-plane ENIs and interface endpoints have no internet route, so they survive a NAT outage and cannot be used as an egress path. |
| `create_database_subnets = true` | Data stores sit in a tier with no route off the VPC at all. |
| `enable_vpc_endpoints = true` | Keeps ECR, S3, STS and CloudWatch traffic off the NAT Gateways — better posture and a materially smaller NAT data bill. |
| `eks_cluster_names` / `karpenter_discovery_value` | Subnet discovery is tag-driven. List every cluster that will live in this VPC. |

Gotchas:

- The discovery tags are the part people get wrong. Missing tags do not fail
  `terraform apply`; they fail later, when a Gateway never gets an ALB or
  Karpenter reports that it found no subnets.
- This example is not free. Three NAT Gateways plus a set of interface endpoints
  carry an hourly charge per AZ before a single byte moves. Expect roughly
  USD 150–200 per month for the network alone in `eu-central-1`.
- `vpc_cidr` and `subnet_newbits` cannot be changed in place without replacing
  subnets. Size the address space before the first apply; see
  [the module README](../../README.md) for the address planning table.
- If a network team already owns the VPC, skip this module and go to
  [`modules/eks/examples/existing-vpc`](../../../eks/examples/existing-vpc/README.md).

## Cleanup

```bash
terraform destroy
```

Destroy any EKS cluster, load balancer or RDS instance that was placed into this
VPC first. Resources created outside Terraform — an ALB from a Gateway, an ENI
from a Karpenter node — hold the subnets and security groups and will make the
VPC deletion hang until they are gone.
