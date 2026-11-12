# eks — existing VPC example

An EKS cluster deployed into networking that another team owns. No VPC, subnet,
route table or NAT Gateway is created, and nothing in the supplied VPC is
modified. Use this when your network team hands you subnet IDs rather than
letting you build a VPC.

## What this creates

| Component | Detail |
|---|---|
| EKS control plane | Version 1.37 in `eu-central-1`, private endpoint only, Access Entries, encrypted Secrets |
| Baseline node group | Self-managed ASG on Bottlerocket (pinned AMI), `m7i.large`, tainted `CriticalAddonsOnly=true:NoSchedule`, labelled `node.kubernetes.io/role=system` |
| Karpenter IAM | Controller role, node role, instance profile, interruption queue |
| Pod Identity | Roles and associations for the platform add-ons |

Inputs you must supply: `vpc_id`, `private_subnet_ids` (at least two, in
different AZs) and optionally `public_subnet_ids` (omit for a cluster with no
public ingress). `control_plane_subnet_ids` is deliberately not set, so the
control-plane ENIs are placed in the private subnets; pass it if the VPC has
dedicated subnets for them.

## Usage

Tag the subnets first. This is a prerequisite, not a suggestion:

| Scope | Tag |
|---|---|
| All subnets used by the cluster | `kubernetes.io/cluster/example-existing-vpc = shared` |
| Public subnets | `kubernetes.io/role/elb = 1` |
| Private subnets | `kubernetes.io/role/internal-elb = 1` |
| Private subnets | `karpenter.sh/discovery = example-existing-vpc` |

Then:

```bash
terraform init
terraform plan \
  -var 'vpc_id=vpc-0123456789abcdef0' \
  -var 'private_subnet_ids=["subnet-aaa","subnet-bbb"]'
terraform apply \
  -var 'vpc_id=vpc-0123456789abcdef0' \
  -var 'private_subnet_ids=["subnet-aaa","subnet-bbb"]'
```

Configure kubectl afterwards with the `kubeconfig_command` output. The endpoint
is private, so run it from inside the VPC or over a VPN.

Pin the module to a release tag in real use rather than the local `../../` path:

```hcl
module "eks" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/eks?ref=eks-v1.0.0"
  # ...
}
```

## Notes

The single biggest gotcha: **missing subnet tags do not fail the apply**. The
cluster comes up, Terraform reports success, and the failure surfaces later and
somewhere else.

| Missing tag | Symptom |
|---|---|
| `karpenter.sh/discovery` on private subnets | Karpenter never provisions a node; NodeClaims stay pending with a subnet discovery error |
| `kubernetes.io/role/internal-elb` on private subnets | Internal load balancers are never created; the Gateway has no address |
| `kubernetes.io/role/elb` on public subnets | Internet-facing load balancers are never created |

Other requirements and decisions:

- The private subnets need outbound internet access, through a NAT Gateway or a
  complete set of VPC interface endpoints. Nodes that cannot reach the EKS API
  and ECR will not join the cluster.
- At least two subnets in different AZs are required by EKS itself.
- Enough free address space matters: pods consume VPC addresses through the VPC
  CNI, so a tier of `/27` subnets will exhaust long before the node limit.
- The baseline ASG exists because Karpenter cannot provision the node it
  runs on. Everything beyond the platform controllers should come from
  Karpenter.
- Cost: control plane about USD 0.10 per hour plus the baseline ASG. The VPC is
  somebody else's bill.

If you control the VPC, use [`modules/networking`](../../../networking/README.md)
instead — it applies all of these tags for you.

## Cleanup

```bash
terraform destroy \
  -var 'vpc_id=vpc-0123456789abcdef0' \
  -var 'private_subnet_ids=["subnet-aaa","subnet-bbb"]'
```

Destroy bootstrap-layer components first. Any load balancer or Karpenter node
created in the cluster lives in someone else's VPC; if it is left behind, the
network team inherits an orphaned ALB and the ENIs it holds.
