# `layers/infrastructure`

The AWS layer. Creates the VPC (optionally) and the EKS cluster, and nothing
that talks to the Kubernetes API.

Apply this **first**. [`layers/bootstrap`](../bootstrap) reads its state.

---

## What it creates

| | |
|---|---|
| Networking | VPC, four subnet tiers, IGW, NAT, route tables, optional VPC endpoints and flow logs — **only when `create_networking = true`** |
| Cluster | EKS 1.37 control plane, KMS CMK, audit logging, access entries |
| Compute | Baseline self-managed Bottlerocket ASG, pinned AMI, tainted `CriticalAddonsOnly` — Karpenter supplies everything else |
| Add-ons | VPC CNI, kube-proxy, CoreDNS, EBS CSI, Pod Identity agent |
| IAM | Pod Identity roles for the LBC, Karpenter, cert-manager, external-dns, EBS CSI |

Declares **only** the `aws` provider. That is the point —
see [ADR-002](../../docs/adr/002-two-layer-state-split.md).

---

## Prerequisites

An S3 bucket and DynamoDB table for state, created once per account **outside**
this repository. A state backend managed by the state it holds cannot be
destroyed or recovered.

```bash
aws s3api create-bucket --bucket my-tfstate-dev \
  --region eu-central-1 --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api put-bucket-versioning --bucket my-tfstate-dev \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket my-tfstate-dev \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws dynamodb create-table --table-name my-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region eu-central-1
```

Then fill in the `CHANGE-ME` values in
[`environments/dev/infrastructure.backend.hcl`](../../environments/dev/infrastructure.backend.hcl).

---

## Usage

```bash
terraform init -backend-config=../../environments/dev/infrastructure.backend.hcl
terraform plan  -var-file=../../environments/dev/infrastructure.tfvars
terraform apply -var-file=../../environments/dev/infrastructure.tfvars
```

Connect:

```bash
eval "$(terraform output -raw kubeconfig_command)"
kubectl get nodes
```

The baseline ASG is tainted, so `kubectl get nodes` showing two
`NotReady`-free nodes with no application pods on them is the expected state.

---

## New VPC or existing VPC

### New (default)

```hcl
create_networking  = true
vpc_cidr           = "10.0.0.0/16"
az_count           = 3
single_nat_gateway = false    # true only in dev
```

All subnet tagging for the Load Balancer Controller and Karpenter is handled
for you.

### Existing

```hcl
create_networking = false

existing_vpc_id                   = "vpc-0123456789abcdef0"
existing_private_subnet_ids       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
existing_public_subnet_ids        = ["subnet-ddd", "subnet-eee", "subnet-fff"]
existing_control_plane_subnet_ids = []   # optional; defaults to private
```

Start from
[`infrastructure.existing-vpc.tfvars.example`](../../environments/dev/infrastructure.existing-vpc.tfvars.example).

Three `check` blocks fail the plan if the VPC ID is unset or either subnet list
is empty. What they **cannot** check is your subnet tags — AWS will happily
create the cluster and then fail at runtime:

```bash
terraform output tag_requirements_for_existing_subnets
```

| Tag | On | Failure if missing |
|---|---|---|
| `kubernetes.io/role/elb = 1` | public | `could not find any suitable subnets for creating the ALB` |
| `kubernetes.io/role/internal-elb = 1` | private | the same, on an internal Gateway |
| `karpenter.sh/discovery = <cluster_name>` | private | NodeClaims stay `Pending` with no events |

Your subnets also need enough free IP space. The VPC CNI assigns a pod an IP
from the subnet, so a `/24` private subnet caps you at roughly 250 pods *and*
nodes in that AZ.

---

## Multi-account

```hcl
assume_role_arn     = "arn:aws:iam::111122223333:role/terraform-deploy"
allowed_account_ids = ["111122223333"]
```

`allowed_account_ids` is the guard that matters: if the credentials in your
shell resolve to a different account, Terraform refuses before it plans.
Set it in every environment, including dev.

---

## Key outputs

| Output | Consumed by |
|---|---|
| `cluster_connection` | `layers/bootstrap` provider configuration |
| `addons_input` | `layers/bootstrap` module inputs — role ARNs, cluster metadata |
| `kubeconfig_command` | `eval "$(terraform output -raw kubeconfig_command)"` |
| `tag_requirements_for_existing_subnets` | What to tag when `create_networking = false` |

`cluster_connection` and `addons_input` are deliberately **bundles** rather
than two dozen individual outputs: adding a field is non-breaking, and the
consumer changes in one place.

---

## Production notes

| Setting | Dev | Prod |
|---|---|---|
| `single_nat_gateway` | `true` | `false` — a single NAT is an AZ-wide SPOF |
| `endpoint_public_access` | `false` | `false` |
| `enable_flow_logs` | `false` | `true` |
| `enable_vpc_endpoints` | `false` | `true` — cuts NAT data charges on image pulls |
| `enable_cluster_creator_admin_permissions` | `true` | `false` — use explicit `access_entries` |

`endpoint_public_access = true` requires `endpoint_public_access_cidrs`, and
`0.0.0.0/0` is rejected by variable validation. Reach a private endpoint over a
VPN, Direct Connect, or SSM port-forwarding through a bastion.

---

## Destroy

Destroy [`layers/bootstrap`](../bootstrap) **first**. Destroying this layer
while bootstrap state still exists leaves that state pointing at a cluster that
is gone, and the only way out is `terraform state rm`.

```bash
cd ../bootstrap && terraform destroy -var-file=../../environments/dev/bootstrap.tfvars
cd ../infrastructure && terraform destroy -var-file=../../environments/dev/infrastructure.tfvars
```

If a destroy hangs on the VPC, something outside Terraform is holding an ENI —
usually a load balancer created by a `Gateway` that was not destroyed with
bootstrap.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied` on init | Backend bucket or role wrong | Check the backend HCL and `assume_role_arn` |
| Plan refuses with an account mismatch | `allowed_account_ids` | Working as intended. Check which profile you are using |
| `check` block fails on subnet lists | `create_networking = false` with empty lists | Supply the subnet IDs |
| Nodes never join | Private subnets have no NAT and no VPC endpoints | Nodes must reach ECR, STS and the EKS API |
| `InvalidParameterException: unsupported Kubernetes version` | Version outside EKS standard support | Check the supported range |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.59.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.59.0, < 7.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_eks"></a> [eks](#module\_eks) | ../../modules/eks | n/a |
| <a name="module_networking"></a> [networking](#module\_networking) | ../../modules/networking | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_subnet.existing_private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_environment"></a> [environment](#input\_environment) | Environment this stack belongs to. Becomes part of resource names and tags, and is used to pick safer defaults in production. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Base name for the platform. Used to derive the VPC name and the cluster name. | `string` | n/a | yes |
| <a name="input_access_entries"></a> [access\_entries](#input\_access\_entries) | EKS access entries granting IAM principals access to the cluster. This replaces the aws-auth ConfigMap, which was removed in EKS module v21. | `any` | `{}` | no |
| <a name="input_allowed_account_ids"></a> [allowed\_account\_ids](#input\_allowed\_account\_ids) | AWS account IDs this stack is permitted to run against. Terraform refuses to plan<br/>if the resolved identity is in any other account.<br/><br/>Set this. It is the cheapest possible guard against a stale variable file pointing<br/>a development pipeline at the production account. | `list(string)` | `[]` | no |
| <a name="input_ami_type"></a> [ami\_type](#input\_ami\_type) | AMI family for the self-managed node groups. Bottlerocket is a minimal, immutable, container-only OS with no shell or package manager. | `string` | `"BOTTLEROCKET_x86_64"` | no |
| <a name="input_assume_role_arn"></a> [assume\_role\_arn](#input\_assume\_role\_arn) | IAM role assumed in the target account before creating anything. This is the<br/>multi-account mechanism: the pipeline holds one identity and crosses an account<br/>boundary through a role rather than holding credentials per account.<br/><br/>Null runs against whatever identity the environment already has, which is<br/>appropriate for a single-account setup or local development. | `string` | `null` | no |
| <a name="input_assume_role_external_id"></a> [assume\_role\_external\_id](#input\_assume\_role\_external\_id) | External ID required when assuming assume\_role\_arn. Protects the target role against the confused-deputy problem. | `string` | `null` | no |
| <a name="input_az_count"></a> [az\_count](#input\_az\_count) | Number of Availability Zones to spread the VPC across. Three is the minimum for a production control plane that tolerates an AZ failure without losing quorum. | `number` | `3` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | Explicit Availability Zone names. Empty selects the first az\_count zones in the region that actually support EKS. | `list(string)` | `[]` | no |
| <a name="input_bottlerocket_version"></a> [bottlerocket\_version](#input\_bottlerocket\_version) | Bottlerocket OS version pinned for the baseline AMI, as a bare semver. Resolved<br/>from `/aws/service/bottlerocket/aws-k8s-<version>/<arch>/<this>/image_id`.<br/><br/>Pinning is deliberate: with `latest`, a new AWS AMI publication would roll every<br/>baseline node on the next apply. | `string` | `"1.68.1"` | no |
| <a name="input_cert_manager_hosted_zone_arns"></a> [cert\_manager\_hosted\_zone\_arns](#input\_cert\_manager\_hosted\_zone\_arns) | Route 53 hosted zone ARNs cert-manager may use for DNS-01 challenges. | `list(string)` | <pre>[<br/>  "arn:aws:route53:::hostedzone/*"<br/>]</pre> | no |
| <a name="input_cluster_tags"></a> [cluster\_tags](#input\_cluster\_tags) | Additional tags applied to cluster resources only. | `map(string)` | `{}` | no |
| <a name="input_create_networking"></a> [create\_networking](#input\_create\_networking) | Whether this stack provisions its own networking.<br/><br/>  true  - a VPC, subnets, route tables, NAT and Internet Gateways, VPC endpoints<br/>          and flow logs are created, correctly tagged for EKS, ELB and Karpenter<br/>          discovery. Use this for a greenfield environment.<br/><br/>  false - no networking resources are created. The cluster is built inside the VPC<br/>          and subnets supplied through the existing\_* variables. Use this when a<br/>          platform or network team already owns the VPC.<br/><br/>When false, the existing subnets must carry the discovery tags EKS and the AWS Load<br/>Balancer Controller rely on. See `tag_requirements_for_existing_subnets` in the<br/>outputs for the exact set, and the module README for the rationale. | `bool` | `true` | no |
| <a name="input_enable_cluster_creator_admin_permissions"></a> [enable\_cluster\_creator\_admin\_permissions](#input\_enable\_cluster\_creator\_admin\_permissions) | Grant the identity running Terraform cluster-admin through an access entry.<br/><br/>Convenient for bootstrapping, but it ties cluster administration to whatever<br/>principal the pipeline happens to use. In production, set this false and grant<br/>access explicitly through access\_entries to named roles. | `bool` | `true` | no |
| <a name="input_enable_efs_csi_driver"></a> [enable\_efs\_csi\_driver](#input\_enable\_efs\_csi\_driver) | Install the EFS CSI driver addon and its IAM role. Needed only for ReadWriteMany volumes; EBS covers ReadWriteOnce. | `bool` | `false` | no |
| <a name="input_enable_flow_logs"></a> [enable\_flow\_logs](#input\_enable\_flow\_logs) | Capture VPC flow logs. Effectively mandatory for incident investigation and for most compliance baselines. | `bool` | `true` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Create the Karpenter IAM roles, instance profile and interruption queue. The controller workload itself is installed by the bootstrap layer. | `bool` | `true` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Create NAT Gateways. Set to false only for a fully private VPC that reaches AWS services exclusively through VPC endpoints. | `bool` | `true` | no |
| <a name="input_enable_vpc_endpoints"></a> [enable\_vpc\_endpoints](#input\_enable\_vpc\_endpoints) | Create interface VPC endpoints for the AWS services the cluster depends on. Keeps control-plane and add-on traffic off the NAT Gateway, which improves both security posture and NAT data cost. | `bool` | `true` | no |
| <a name="input_endpoint_public_access"></a> [endpoint\_public\_access](#input\_endpoint\_public\_access) | Expose the Kubernetes API endpoint to the internet.<br/><br/>Defaults to false. A private endpoint means the API server is reachable only from<br/>inside the VPC or across a VPN or Direct Connect link, which removes the cluster's<br/>control plane from internet-wide credential-stuffing and CVE scanning entirely.<br/><br/>If this is turned on, endpoint\_public\_access\_cidrs must be narrowed. | `bool` | `false` | no |
| <a name="input_endpoint_public_access_cidrs"></a> [endpoint\_public\_access\_cidrs](#input\_endpoint\_public\_access\_cidrs) | CIDR blocks permitted to reach the public API endpoint. 0.0.0.0/0 is rejected by the EKS module in this repository. | `list(string)` | `[]` | no |
| <a name="input_existing_control_plane_subnet_ids"></a> [existing\_control\_plane\_subnet\_ids](#input\_existing\_control\_plane\_subnet\_ids) | Subnets for the EKS control-plane ENIs. Optional; defaults to the private subnets. Dedicated subnets keep control-plane ENIs isolated from workload IP exhaustion. | `list(string)` | `[]` | no |
| <a name="input_existing_private_subnet_ids"></a> [existing\_private\_subnet\_ids](#input\_existing\_private\_subnet\_ids) | Private subnet IDs for worker nodes. Required when create\_networking is false. Must span at least two Availability Zones. | `list(string)` | `[]` | no |
| <a name="input_existing_public_subnet_ids"></a> [existing\_public\_subnet\_ids](#input\_existing\_public\_subnet\_ids) | Public subnet IDs for internet-facing load balancers. Optional; omit for a fully private cluster with no public ingress. | `list(string)` | `[]` | no |
| <a name="input_existing_vpc_id"></a> [existing\_vpc\_id](#input\_existing\_vpc\_id) | ID of an existing VPC. Required when create\_networking is false. | `string` | `null` | no |
| <a name="input_external_dns_hosted_zone_arns"></a> [external\_dns\_hosted\_zone\_arns](#input\_external\_dns\_hosted\_zone\_arns) | Route 53 hosted zone ARNs external-dns may write to. Scoping this to specific zones is what stops one cluster from editing another's DNS. | `list(string)` | <pre>[<br/>  "arn:aws:route53:::hostedzone/*"<br/>]</pre> | no |
| <a name="input_flow_logs_retention_days"></a> [flow\_logs\_retention\_days](#input\_flow\_logs\_retention\_days) | Retention for the flow log group. | `number` | `90` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes minor version for the control plane. | `string` | `"1.37"` | no |
| <a name="input_networking_tags"></a> [networking\_tags](#input\_networking\_tags) | Additional tags applied to networking resources only. | `map(string)` | `{}` | no |
| <a name="input_node_data_disk_size"></a> [node\_data\_disk\_size](#input\_node\_data\_disk\_size) | Size in GiB of the Bottlerocket data volume (`/dev/xvdb`), holding container images, writable layers and ephemeral storage. | `number` | `100` | no |
| <a name="input_node_os_disk_size"></a> [node\_os\_disk\_size](#input\_node\_os\_disk\_size) | Size in GiB of the Bottlerocket OS volume (`/dev/xvda`). Container data does not live here. | `number` | `10` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region. Kept as a variable rather than hardcoded so the same stack can be stood up in a second region when multi-region becomes a requirement. | `string` | `"eu-central-1"` | no |
| <a name="input_self_managed_node_groups"></a> [self\_managed\_node\_groups](#input\_self\_managed\_node\_groups) | Additional self-managed node groups beyond the baseline. Most workloads should run<br/>on Karpenter instead; use this for capacity that genuinely cannot be dynamically<br/>provisioned, such as licence-bound or GPU-reserved nodes.<br/><br/>Note `instance_type` is singular, and labels and taints are passed as Bottlerocket<br/>TOML through `bootstrap_extra_args`. | `any` | `{}` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Route all private subnets through one NAT Gateway instead of one per AZ.<br/><br/>This saves roughly two thirds of the NAT hourly cost and is reasonable for<br/>development. In production it creates both a single point of failure and<br/>cross-AZ data charges on every byte of egress — leave it false. | `bool` | `false` | no |
| <a name="input_system_node_group_desired_size"></a> [system\_node\_group\_desired\_size](#input\_system\_node\_group\_desired\_size) | Initial size of the baseline ASG. Ignored on later applies; change `system_node_group_min_size` instead. | `number` | `2` | no |
| <a name="input_system_node_group_instance_types"></a> [system\_node\_group\_instance\_types](#input\_system\_node\_group\_instance\_types) | Instance types for the baseline self-managed ASG, in order of preference. This<br/>group runs only the platform controllers; application capacity comes from<br/>Karpenter.<br/><br/>More than one type enables a mixed instances policy pinned to 100% on-demand, so<br/>a single Insufficient Capacity Exception cannot leave the cluster without its<br/>baseline. | `list(string)` | <pre>[<br/>  "m7i.large",<br/>  "m7a.large",<br/>  "m6i.large"<br/>]</pre> | no |
| <a name="input_system_node_group_max_size"></a> [system\_node\_group\_max\_size](#input\_system\_node\_group\_max\_size) | Maximum size of the baseline ASG. Nothing autoscales this group; headroom exists only so instance refresh can surge during an AMI roll. | `number` | `4` | no |
| <a name="input_system_node_group_min_size"></a> [system\_node\_group\_min\_size](#input\_system\_node\_group\_min\_size) | Minimum size of the baseline ASG, and in practice its steady-state size — the<br/>underlying ASG ignores `desired_capacity` after creation. Two is the floor for a<br/>highly available controller set. | `number` | `2` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource through the provider's default\_tags. | `map(string)` | `{}` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | CIDR block for the VPC. Size it for the pod IP density you expect: with the VPC CNI every pod consumes a VPC address. | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_addons_input"></a> [addons\_input](#output\_addons\_input) | Pre-assembled inputs for the eks-gateway and eks-addons modules. |
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Cluster CA bundle, base64 encoded. |
| <a name="output_cluster_connection"></a> [cluster\_connection](#output\_cluster\_connection) | Everything the kubernetes, helm and kubectl providers need. Read from the bootstrap layer through terraform\_remote\_state. |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Kubernetes API endpoint. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the EKS cluster. |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Cluster security group attached to the control-plane ENIs. |
| <a name="output_cluster_version"></a> [cluster\_version](#output\_cluster\_version) | Kubernetes version running on the control plane. |
| <a name="output_control_plane_subnet_ids"></a> [control\_plane\_subnet\_ids](#output\_control\_plane\_subnet\_ids) | Subnets holding the EKS control-plane ENIs. |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | IAM role Karpenter-provisioned nodes assume. Referenced by the default EC2NodeClass in the bootstrap layer. |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | SQS queue carrying spot interruption notices. |
| <a name="output_kubeconfig_command"></a> [kubeconfig\_command](#output\_kubeconfig\_command) | Command that writes a kubeconfig entry for this cluster. |
| <a name="output_nat_public_ips"></a> [nat\_public\_ips](#output\_nat\_public\_ips) | Public IPs of the NAT Gateways. These are the cluster's egress addresses — give them to anyone who needs to allow-list outbound traffic from the cluster. |
| <a name="output_networking_created_here"></a> [networking\_created\_here](#output\_networking\_created\_here) | Whether this stack owns the networking resources. False means they belong to another team and must not be modified from here. |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | Shared node security group. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | IAM OIDC provider ARN for the cluster. |
| <a name="output_pod_identity_role_arns"></a> [pod\_identity\_role\_arns](#output\_pod\_identity\_role\_arns) | IAM role ARNs associated with each platform add-on's service account. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnets carrying the worker nodes. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | Public subnets used for internet-facing load balancers. |
| <a name="output_tag_requirements_for_existing_subnets"></a> [tag\_requirements\_for\_existing\_subnets](#output\_tag\_requirements\_for\_existing\_subnets) | Tags that must already be present on subnets supplied through the existing\_*<br/>variables when create\_networking is false.<br/><br/>These are not cosmetic. The AWS Load Balancer Controller and Karpenter discover<br/>subnets exclusively by tag; without them, load balancer provisioning and node<br/>launches fail with errors that give no hint about the real cause. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | CIDR block of the VPC. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC the cluster runs in, whether created here or supplied. |
<!-- END_TF_DOCS -->
