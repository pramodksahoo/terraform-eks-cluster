# eks — complete example

A VPC and an EKS cluster in one configuration: Kubernetes 1.37 in
`eu-central-1`, private API endpoint, a tainted baseline ASG for the
platform controllers, and the IAM groundwork Karpenter and EKS Pod Identity
need. This is the shape [`layers/infrastructure`](../../../../layers/infrastructure)
uses, and the fastest way to see how the networking and EKS modules fit
together.

## What this creates

| Component | Detail |
|---|---|
| VPC | `modules/networking`, `10.2.0.0/16`, three AZs, intra subnets and VPC endpoints enabled |
| EKS control plane | Version 1.37, private endpoint only, Secrets encrypted with a dedicated KMS key, audit logging on |
| Access control | `authentication_mode = "API"` (Access Entries, not `aws-auth`), caller granted cluster admin |
| Baseline node group | Self-managed ASG on Bottlerocket (pinned AMI), `m7i.large`, min 2 / desired 2 / max 4, tainted `CriticalAddonsOnly=true:NoSchedule`, labelled `node.kubernetes.io/role=system`. No Cluster Autoscaler tags |
| Karpenter IAM | Controller role, node role, instance profile and SQS interruption queue |
| Pod Identity | Roles and associations for the platform add-ons; no IRSA, no static keys |

Outputs: `cluster_connection` (feeds the kubernetes, helm and kubectl
providers), `addons_input` (feeds [`modules/eks-gateway`](../../../eks-gateway/README.md)
and [`modules/eks-addons`](../../../eks-addons/README.md)), and
`kubeconfig_command`.

## Usage

```bash
terraform init
terraform plan
terraform apply
```

Then configure kubectl with the printed command:

```bash
aws eks update-kubeconfig --region eu-central-1 --name example-complete
```

The API endpoint is private, so that command and every subsequent `kubectl` call
must run from inside the VPC, or over a VPN or Direct Connect link that reaches
it. Set `endpoint_public_access = true` only if you accept a publicly reachable
API server, and pair it with CIDR restrictions.

Both modules are referenced by local relative path. Consumers should pin to
release tags instead:

```hcl
module "eks" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/eks?ref=eks-v1.0.0"
  # ...
}
```

## Notes

| Decision | Why |
|---|---|
| Control-plane ENIs in the intra tier | No internet route, so they are unaffected by a NAT Gateway failure and cannot serve as an egress path |
| Baseline ASG plus Karpenter | Karpenter cannot provision the node it runs on. The statically sized, tainted ASG hosts Karpenter, CoreDNS and the other controllers; Karpenter provisions everything else. Nothing autoscales the ASG — `min_size` is the floor, and `desired_size` is only honoured at creation |
| The taint | Only tolerating workloads land on the system group. Application pods are pushed onto Karpenter-managed capacity by design |
| `enable_karpenter = true` | Creates IAM and the interruption queue only. The Karpenter controller itself is installed by `modules/eks-addons` in the bootstrap layer |
| `authentication_mode = "API"` | The `aws-auth` ConfigMap path was removed in v21 of the upstream EKS module |

Gotchas:

- This example stops at the AWS boundary. There is no CNI policy, no Karpenter
  controller, no ingress until you apply the bootstrap layer modules against the
  cluster. A freshly applied cluster has the baseline ASG and nothing else.
- `enable_cluster_creator_admin_permissions = true` binds admin to the identity
  that ran `apply`. If that is a CI role, humans need their own access entries.
- Cost: the EKS control plane is about USD 0.10 per hour, plus two `m7i.large`
  instances, plus the VPC from the networking module. Budget roughly USD 250–300
  per month for the whole example.
- Apply takes 15–20 minutes; most of it is the control plane.

## Cleanup

```bash
terraform destroy
```

If you installed bootstrap-layer components (gateway, add-ons, Istio) against
this cluster, destroy them first. Load balancers and Karpenter nodes created
outside this state hold ENIs in the subnets and will block the VPC teardown. If
the destroy hangs on the VPC, look for an orphaned ALB or a running Karpenter
node and delete it.
