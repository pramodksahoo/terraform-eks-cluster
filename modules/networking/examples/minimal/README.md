# networking — minimal example

The cheapest VPC that still runs a development EKS cluster: two availability
zones, public and private subnets only, one shared NAT Gateway, no interface
endpoints. For sandboxes and short-lived test environments, not for production.

## What this creates

| Component | Detail |
|---|---|
| VPC | `10.1.0.0/16`, two AZs |
| Public subnets | The NAT Gateway and any internet-facing load balancer, tagged `kubernetes.io/role/elb=1` |
| Private subnets | Worker nodes, tagged `kubernetes.io/role/internal-elb=1` |
| NAT Gateway | One, shared by both AZs |
| Flow logs | CloudWatch Logs, 14-day retention |

Not created: intra subnets, database subnets, interface VPC endpoints.

Outputs: `vpc_id` and `private_subnet_ids`, which is everything
[`modules/eks`](../../../eks/README.md) needs for a basic cluster.

## Usage

```bash
terraform init
terraform plan
terraform apply
```

Only AWS credentials are required. This is an infrastructure-layer example: AWS
resources only, no Kubernetes provider involved.

The source here is the local path `../../`. In your own configuration, pin the
module to a release tag:

```hcl
module "networking" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/networking?ref=networking-v1.0.0"
  # ...
}
```

## Notes

| Decision | Why | Production consequence |
|---|---|---|
| `single_nat_gateway = true` | One gateway instead of two halves the hourly charge | AZ-wide single point of failure, and every byte from the other AZ crosses an AZ boundary at cross-AZ data rates |
| `create_intra_subnets = false` | Fewer subnets to reason about | Control-plane ENIs land in the same subnets as the workload, so they share the NAT path and the blast radius |
| `create_database_subnets = false` | Nothing stateful is expected here | No isolated tier for RDS or ElastiCache |
| `enable_vpc_endpoints = false` | Interface endpoints bill per AZ per service, which dominates the cost of a low-traffic dev VPC | ECR pulls, STS calls and CloudWatch writes all traverse the NAT Gateway and are charged as NAT data processing |
| `az_count = 2` | The minimum EKS accepts | No tolerance for the loss of one AZ |
| `flow_logs_retention_days = 14` | Dev-grade retention | Too short for most audit requirements |

Gotchas:

- `karpenter_discovery_value` is not set, so the private subnets carry no
  `karpenter.sh/discovery` tag. Set it before pointing Karpenter at this VPC, or
  node provisioning fails with a subnet discovery error that does not name the
  missing tag.
- Moving from `single_nat_gateway = true` to `false` later replaces route table
  associations and briefly interrupts egress. Decide early if the environment is
  going to outlive its "dev" label.
- Cost is low but not zero: one NAT Gateway is roughly USD 35 per month in
  `eu-central-1`, plus data processing.

For the production shape — three AZs, per-AZ NAT, intra and database tiers,
interface endpoints — see [the complete example](../complete/README.md).

## Cleanup

```bash
terraform destroy
```

Delete any EKS cluster or load balancer in this VPC first. Leftover ENIs from
nodes or ALBs keep the subnets in use and stall the destroy.
