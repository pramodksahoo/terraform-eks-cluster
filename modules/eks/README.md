# `eks`

An EKS cluster with the security posture already applied: private API endpoint,
envelope-encrypted Secrets, full audit logging, Access Entries instead of
`aws-auth`, EKS Pod Identity instead of IRSA, and IMDS locked down so a
compromised pod cannot steal node credentials.

It creates **no networking**. Give it a VPC and subnets — from
[`modules/networking`](../networking) or your own.

---

## Contents

- [What it creates](#what-it-creates)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Security defaults](#security-defaults)
- [Compute model](#compute-model)
- [Access control](#access-control)
- [Pod Identity](#pod-identity)
- [Add-ons](#add-ons)
- [Upgrading Kubernetes](#upgrading-kubernetes)
- [Integration](#integration)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)
- [Generated reference](#requirements)

---

## What it creates

| Resource | Notes |
|---|---|
| EKS cluster | `authentication_mode = "API"`, private endpoint by default |
| KMS key | Customer-managed, for Secrets envelope encryption |
| CloudWatch log group | All five control-plane log types |
| Baseline node group | Self-managed ASG on Bottlerocket, pinned AMI, tainted `CriticalAddonsOnly`, runs platform controllers only |
| Karpenter IAM + SQS | Controller role, node role, instance profile, interruption queue |
| Pod Identity associations | AWS LBC, cert-manager, external-dns, EBS CSI, EFS CSI |
| EKS add-ons | VPC CNI, CoreDNS, kube-proxy, EBS CSI, Pod Identity agent, metrics-server |

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | `>= 1.10.0` |
| AWS provider | `>= 6.59.0, < 7.0.0` |
| VPC | At least two private subnets in two different AZs, with outbound internet access |
| Subnet tags | See [networking → Discovery tags](../networking/README.md#discovery-tags) |
| IAM permissions | `eks:*`, `ec2:*` for ENIs/SGs/launch templates, `iam:*Role*`, `iam:*InstanceProfile*`, `kms:*`, `sqs:*`, `logs:*` |

---

## Quick start

```hcl
module "eks" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/eks?ref=eks-v1.0.0"

  cluster_name       = "platform-prod"
  kubernetes_version = "1.37"

  vpc_id                   = module.networking.vpc_id
  subnet_ids               = module.networking.private_subnet_ids
  control_plane_subnet_ids = module.networking.intra_subnet_ids
  public_subnet_ids        = module.networking.public_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = false

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    admins = {
      principal_arn = "arn:aws:iam::222222222222:role/platform-admin"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  enable_karpenter          = true
  enable_pod_identity_roles = true

  tags = { Environment = "prod" }
}
```

---

## Security defaults

Every item below is the **default**. You can relax them, but you have to do it
on purpose.

| Control | Default | Why |
|---|---|---|
| API endpoint | Private only | Removes the control plane from internet-wide scanning and credential stuffing |
| `endpoint_public_access_cidrs` | `0.0.0.0/0` **rejected by validation** | A public endpoint open to the world is the single most common EKS misconfiguration |
| Secrets encryption | On, customer-managed KMS key | Without it, Secrets are stored base64-encoded in etcd — not encrypted |
| Audit logging | All five log types | `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`. Audit logs are the only record of who did what |
| Authentication mode | `API` | `CONFIG_MAP` is rejected by validation. The `aws-auth` ConfigMap has no audit trail and one bad edit locks everyone out |
| IMDS hop limit | `1` | A pod cannot reach IMDS through the pod network, so it cannot mint node-role credentials |
| IMDS tokens | `required` (IMDSv2) | Blocks SSRF-based credential theft |
| AMI family | Bottlerocket | Immutable, container-only, no shell and no package manager. A far smaller attack surface than a general-purpose distribution |
| AMI version | Pinned, not `latest` | A `check` block rejects `latest`: an unpinned AMI rolls every baseline node whenever AWS publishes a release |
| Kubernetes version | `>= 1.34` | Older versions are in extended support (surcharge) or EOL |
| Node EBS volumes | Encrypted | |
| Identity for add-ons | Pod Identity, not IRSA | No OIDC trust policy to maintain; associations are cleaned up with the cluster |

---

## Compute model

Two tiers, with a hard division of responsibility:

```
┌──────────────────────────────────────────────────────────────┐
│ Baseline: self-managed ASG      (this module)                │
│  • Bottlerocket, pinned AMI version                          │
│  • fixed size, 100% on-demand, never Spot                    │
│  • taint CriticalAddonsOnly=true:NoSchedule                  │
│  • label node.kubernetes.io/role=system                      │
│  • runs: Karpenter, AWS LBC, CoreDNS, cert-manager, ...      │
│  • scaled by NOTHING — no Cluster Autoscaler, no Karpenter   │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ Elastic: Karpenter              (modules/eks-addons)         │
│  • dynamic, Spot-capable, consolidating                      │
│  • instance types chosen per pod                             │
│  • runs: everything else                                     │
└──────────────────────────────────────────────────────────────┘
```

**Karpenter cannot provision the node it runs on.** If Karpenter is the only
source of capacity and every node is lost, nothing can bring the cluster back.
The baseline ASG exists solely to break that circular dependency, and the taint
keeps application workloads off it.

Set `system_node_group_taint_system_workloads = false` only if you accept that
application pods will then compete with the platform controllers.

### Why self-managed, not an EKS managed node group

There is no managed node group here at all. With Karpenter owning elastic
capacity, the managed node group API only adds a second control loop over
capacity that is deliberately fixed — along with its own upgrade semantics and
its own label and taint restrictions. A plain ASG that nothing resizes is both
simpler and more predictable. Full reasoning in
[ADR-004](../../docs/adr/004-self-managed-asg-plus-karpenter.md).

### No Cluster Autoscaler

This ASG carries **no** `k8s.io/cluster-autoscaler/*` discovery tags, and
`system_node_group_autoscaling_group_tags` documents that you should not add
them. Two controllers resizing one ASG produces thrash, orphaned nodes and
scale-down fights. Karpenter is the only thing that adds capacity.

### Sizing

```hcl
system_node_group_instance_types = ["m7i.large", "m7a.large", "m6i.large"]
system_node_group_min_size       = 2   # dev;  4 in prod
system_node_group_max_size       = 4   # dev;  8 in prod
system_node_group_desired_size   = 2
```

Two things that catch people out:

- **`min_size` is what holds the floor.** The upstream ASG hardcodes
  `ignore_changes = [desired_capacity]`, so editing `desired_size` after
  creation does nothing. Change `min_size`.
- **`max_size` is not autoscaling headroom.** Nothing scales this group. The
  gap above `min_size` exists only so an instance refresh can surge while
  rolling a new AMI.

More than one instance type switches on a mixed instances policy pinned to
**100% on-demand**. That is capacity diversification, not cost optimisation: a
single-type ASG is one Insufficient Capacity Exception away from having no
baseline. Spot belongs to Karpenter, never to the baseline.

---

## Bottlerocket

### Pinning the AMI

The AMI is resolved from an SSM public parameter:

```
/aws/service/bottlerocket/aws-k8s-<kubernetes_version>/<arch>/<bottlerocket_version>/image_id
```

`bottlerocket_version` is a bare semver with no leading `v`. Verify it resolves
before you pin it — not every Bottlerocket release publishes AMIs for every
Kubernetes variant:

```bash
aws ssm get-parameter --region eu-central-1 \
  --name /aws/service/bottlerocket/aws-k8s-1.37/x86_64/1.68.1/image_id
```

The upstream module's own lookup is hardcoded to `latest`, which is why this
module resolves the parameter itself. `latest` is accepted but a `check` block
will tell you off: with `latest`, AWS publishing a new release silently
replaces every baseline node on your next apply, at a time you did not choose.

Bumping `bottlerocket_version` triggers a rolling instance refresh. That is the
intended upgrade path.

### Labels and taints are TOML

Self-managed node groups have no `labels` or `taints` argument — there is no
EKS node group API to apply them. The kubelet self-registers with them instead,
configured through Bottlerocket's TOML:

```toml
[settings.kubernetes.node-labels]
"node.kubernetes.io/role" = "system"

[settings.kubernetes.node-taints]
"CriticalAddonsOnly" = ["true:NoSchedule"]
```

The module renders this for the baseline group. For your own groups, pass
`bootstrap_extra_args`.

> **The label namespace matters.** These are self-set by the kubelet, so the
> **NodeRestriction** admission plugin applies. `node.kubernetes.io/*` is an
> explicitly allowed namespace, which is why that key is used. The more
> familiar `node-role.kubernetes.io/*` is **rejected** and the kubelet will
> refuse to start. Unprefixed keys are always safe.

### Two volumes, both must be declared

| Device | Holds | Default |
|---|---|---|
| `/dev/xvda` | A/B partition sets, bootloader, dm-verity hash tree, API datastore | `node_os_disk_size`, 10 GiB |
| `/dev/xvdb` | Container images, writable layers, ephemeral storage | `node_data_disk_size`, 100 GiB |

Mapping only one leaves the other at the AMI default — unencrypted and
undersized. The module always declares both. Bottlerocket grows the data
partition to fill its device at boot, so sizing `/dev/xvdb` is how you size
node ephemeral storage.

### Operating a node with no shell

Bottlerocket has no SSH, no shell and no package manager. Access is through the
admin container over SSM Session Manager, which is why
`AmazonSSMManagedInstanceCore` is attached by default:

```bash
aws ssm start-session --target i-0123456789abcdef0
# then, inside:
enter-admin-container
```

> **Upstream note.** EKS module v21 removed both `eks_managed_node_group_defaults`
> and `self_managed_node_group_defaults`. This module keeps a
> `node_group_defaults` variable and merges it into each group itself, so the
> familiar authoring experience survives.

---

## Access control

`aws-auth` is gone — the submodule was removed in EKS module v21. Use
`access_entries`:

```hcl
access_entries = {
  platform_admins = {
    principal_arn = "arn:aws:iam::222222222222:role/platform-admin"
    type          = "STANDARD"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }

  app_team_a = {
    principal_arn = "arn:aws:iam::222222222222:role/app-team-a"
    policy_associations = {
      edit = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
        access_scope = {
          type       = "namespace"
          namespaces = ["team-a"]
        }
      }
    }
  }
}
```

Common policies:

| Policy ARN suffix | Grants |
|---|---|
| `AmazonEKSClusterAdminPolicy` | `cluster-admin` |
| `AmazonEKSAdminPolicy` | Admin within a namespace scope |
| `AmazonEKSEditPolicy` | Read/write, no RBAC changes |
| `AmazonEKSViewPolicy` | Read-only |

In production set `enable_cluster_creator_admin_permissions = false`, otherwise
cluster administration is tied to whichever principal the pipeline happens to
run as.

---

## Pod Identity

`enable_pod_identity_roles = true` creates an IAM role per controller and
associates it with a specific namespace and service account:

| Controller | Namespace | Service account | Permissions |
|---|---|---|---|
| AWS Load Balancer Controller | `kube-system` | `aws-load-balancer-controller` | ELB, EC2 describe, ACM, WAF |
| cert-manager | `cert-manager` | `cert-manager` | Route 53, scoped by `cert_manager_hosted_zone_arns` |
| external-dns | `external-dns` | `external-dns` | Route 53, scoped by `external_dns_hosted_zone_arns` |
| EBS CSI driver | `kube-system` | `ebs-csi-controller-sa` | EC2 volumes, KMS |
| EFS CSI driver | `kube-system` | `efs-csi-controller-sa` | EFS access points |

> **Do not also annotate these service accounts with
> `eks.amazonaws.com/role-arn`.** An IRSA annotation takes precedence over Pod
> Identity, and the controller will silently use the wrong credential source.
> [`modules/eks-gateway`](../eks-gateway) creates the LBC service account
> itself for exactly this reason.

Scope the Route 53 variables to real hosted zone ARNs. The default
`arn:aws:route53:::hostedzone/*` is convenient for a first apply and far too
broad for production.

---

## Add-ons

Managed by EKS rather than Helm, so AWS handles compatibility with the control
plane version:

`vpc-cni` · `coredns` · `kube-proxy` · `aws-ebs-csi-driver` ·
`eks-pod-identity-agent` · `metrics-server` · optionally `aws-efs-csi-driver`
and `aws-mountpoint-s3-csi-driver`.

Add more with `additional_addons`. Tune the CNI through
`vpc_cni_configuration` — prefix delegation, for instance, raises pod density
per node substantially:

```hcl
vpc_cni_configuration = {
  ENABLE_PREFIX_DELEGATION = "true"
  WARM_PREFIX_TARGET       = "1"
}
```

---

## Upgrading Kubernetes

1. Read the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
   for removed APIs. Run `kubectl` deprecation checks against your workloads.
2. Bump `kubernetes_version` by **one minor version**. EKS does not support
   skipping versions.
3. Apply. The control plane upgrades first, then the ASG rolls via instance refresh.
4. Bump `karpenter_chart_version` in `modules/eks-addons` to a release that
   supports the new version, and let the NodePool's `expireAfter` replace the
   dynamic nodes.

Expect 20–40 minutes for the control plane, plus node rollout time. Managed
instance refresh respects PodDisruptionBudgets, so make sure yours are not so strict
that the roll cannot complete.

---

## Integration

```hcl
# Feeds the kubernetes / helm / kubectl providers
module.eks.cluster_connection

# Feeds modules/eks-gateway and modules/eks-addons
module.eks.addons_input
```

Consuming from another repository:

```hcl
source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/eks?ref=eks-v1.0.0"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Nodes never become `Ready` | Private subnets have no outbound route | Add a NAT Gateway, or the full VPC endpoint set |
| `could not find any suitable subnets` | Missing `kubernetes.io/role/elb` tags | See [networking → Discovery tags](../networking/README.md#discovery-tags) |
| Karpenter NodeClaims stay `Pending` | Missing `karpenter.sh/discovery` on subnets or security group | Tag them, then delete the stuck NodeClaims |
| `error: You must be logged in to the server` | No access entry for your principal | Add one under `access_entries` |
| `connection refused` on the API | Private endpoint, and you are outside the VPC | Use a VPN, bastion, or an in-VPC runner |
| Terraform cannot reach the API on destroy | Provider configured from a resource in the same state | Use the two-layer split in `layers/` |

---

## Examples

| Example | Description |
|---|---|
| [`complete`](examples/complete) | Networking plus cluster, production shape |
| [`existing-vpc`](examples/existing-vpc) | Cluster only, into a VPC you already own |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.59.0, < 7.0.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.9.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | >= 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.59.0, < 7.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 21.29 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | ~> 21.29 |
| <a name="module_pod_identity_aws_lb_controller"></a> [pod\_identity\_aws\_lb\_controller](#module\_pod\_identity\_aws\_lb\_controller) | terraform-aws-modules/eks-pod-identity/aws | ~> 2.10 |
| <a name="module_pod_identity_cert_manager"></a> [pod\_identity\_cert\_manager](#module\_pod\_identity\_cert\_manager) | terraform-aws-modules/eks-pod-identity/aws | ~> 2.10 |
| <a name="module_pod_identity_ebs_csi"></a> [pod\_identity\_ebs\_csi](#module\_pod\_identity\_ebs\_csi) | terraform-aws-modules/eks-pod-identity/aws | ~> 2.10 |
| <a name="module_pod_identity_efs_csi"></a> [pod\_identity\_efs\_csi](#module\_pod\_identity\_efs\_csi) | terraform-aws-modules/eks-pod-identity/aws | ~> 2.10 |
| <a name="module_pod_identity_external_dns"></a> [pod\_identity\_external\_dns](#module\_pod\_identity\_external\_dns) | terraform-aws-modules/eks-pod-identity/aws | ~> 2.10 |

## Resources

| Name | Type |
|------|------|
| [aws_eks_pod_identity_association.aws_lb_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.cert_manager](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.efs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.external_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_kms_alias.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.secrets_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.bottlerocket_ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster. Also used as the Karpenter and load-balancer discovery tag value. | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Subnet IDs for worker nodes. Must be private subnets with a route to the internet<br/>(NAT Gateway) or a complete set of VPC endpoints. At least two subnets in two<br/>different Availability Zones are required by EKS. | `list(string)` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the cluster is deployed into. | `string` | n/a | yes |
| <a name="input_access_entries"></a> [access\_entries](#input\_access\_entries) | EKS Access Entries, keyed by a friendly name. This replaces the deprecated aws-auth<br/>ConfigMap. Map IAM roles (ideally SSO permission-set roles) to EKS access policies.<br/><br/>Example:<pre>access_entries = {<br/>  platform_admins = {<br/>    principal_arn = "arn:aws:iam::111122223333:role/AWSReservedSSO_PlatformAdmin_abc"<br/>    policy_associations = {<br/>      admin = {<br/>        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"<br/>        access_scope = { type = "cluster" }<br/>      }<br/>    }<br/>  }<br/>  app_team_a = {<br/>    principal_arn = "arn:aws:iam::111122223333:role/AppTeamA"<br/>    policy_associations = {<br/>      edit = {<br/>        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"<br/>        access_scope = { type = "namespace", namespaces = ["team-a"] }<br/>      }<br/>    }<br/>  }<br/>}</pre> | `any` | `{}` | no |
| <a name="input_additional_addons"></a> [additional\_addons](#input\_additional\_addons) | Extra EKS add-ons to install, keyed by add-on name. Merged over the module's baseline add-on set. | `any` | `{}` | no |
| <a name="input_ami_type"></a> [ami\_type](#input\_ami\_type) | AMI family for the self-managed node groups.<br/><br/>Bottlerocket is the default and the only family this module generates bootstrap<br/>settings for: it is a minimal, immutable, container-only OS with no shell and no<br/>package manager, which is a materially smaller attack surface than a general<br/>purpose distribution.<br/><br/>Node labels and taints are rendered as Bottlerocket TOML, so a non-Bottlerocket<br/>value means you must supply your own `bootstrap_extra_args` or<br/>`cloudinit_pre_nodeadm` per group. | `string` | `"BOTTLEROCKET_x86_64"` | no |
| <a name="input_authentication_mode"></a> [authentication\_mode](#input\_authentication\_mode) | Cluster authentication mode. `API` uses EKS Access Entries exclusively and is the<br/>recommended setting; the aws-auth ConfigMap is not created at all.<br/>`API_AND_CONFIG_MAP` is provided only to support migrating an existing cluster.<br/><br/>WARNING: moving from CONFIG\_MAP towards API is one-way. You cannot move back. | `string` | `"API"` | no |
| <a name="input_bottlerocket_extra_settings"></a> [bottlerocket\_extra\_settings](#input\_bottlerocket\_extra\_settings) | Additional Bottlerocket TOML appended to the baseline ASG's user data. Each entry<br/>must open its own table, because the module renders this directly beneath the<br/>`[settings.kubernetes]` table it generates.<br/><br/>Example, for VPC CNI prefix delegation:<pre>bottlerocket_extra_settings = <<-TOML<br/>  [settings.kubernetes]<br/>  max-pods = 110<br/>TOML</pre> | `string` | `""` | no |
| <a name="input_bottlerocket_version"></a> [bottlerocket\_version](#input\_bottlerocket\_version) | Bottlerocket OS version to pin the baseline AMI to, resolved through the SSM<br/>public parameter:<br/><br/>  /aws/service/bottlerocket/aws-k8s-<kubernetes\_version>/<arch>/<version>/image\_id<br/><br/>A bare semver with no leading `v`. `latest` is accepted but tripped by a `check`<br/>block: with `latest`, AWS publishing a new AMI silently rolls every baseline node<br/>on the next apply, at a time you did not choose.<br/><br/>Verify a version resolves before pinning it:<pre>aws ssm get-parameter --region eu-central-1 \<br/>  --name /aws/service/bottlerocket/aws-k8s-1.37/x86_64/1.68.1/image_id</pre> | `string` | `"1.68.1"` | no |
| <a name="input_cert_manager_hosted_zone_arns"></a> [cert\_manager\_hosted\_zone\_arns](#input\_cert\_manager\_hosted\_zone\_arns) | Route 53 hosted zone ARNs cert-manager may use for DNS-01 ACME challenges. | `list(string)` | <pre>[<br/>  "arn:aws:route53:::hostedzone/*"<br/>]</pre> | no |
| <a name="input_cloudwatch_log_group_kms_key_id"></a> [cloudwatch\_log\_group\_kms\_key\_id](#input\_cloudwatch\_log\_group\_kms\_key\_id) | KMS key ARN used to encrypt the control-plane log group. Leave empty for the AWS-managed CloudWatch Logs key. | `string` | `""` | no |
| <a name="input_cloudwatch_log_group_retention_in_days"></a> [cloudwatch\_log\_group\_retention\_in\_days](#input\_cloudwatch\_log\_group\_retention\_in\_days) | Retention for the control-plane CloudWatch log group. | `number` | `90` | no |
| <a name="input_cluster_security_group_additional_rules"></a> [cluster\_security\_group\_additional\_rules](#input\_cluster\_security\_group\_additional\_rules) | Additional rules added to the cluster (control plane) security group. | `any` | `{}` | no |
| <a name="input_control_plane_subnet_ids"></a> [control\_plane\_subnet\_ids](#input\_control\_plane\_subnet\_ids) | Subnet IDs for the EKS control-plane cross-account ENIs. Defaults to `subnet_ids`<br/>when empty. Supplying dedicated isolated (intra) subnets keeps the control plane<br/>independent of NAT Gateway availability. | `list(string)` | `[]` | no |
| <a name="input_coredns_replica_count"></a> [coredns\_replica\_count](#input\_coredns\_replica\_count) | Number of CoreDNS replicas. Two is the minimum for availability during node rotation. | `number` | `2` | no |
| <a name="input_create_system_node_group"></a> [create\_system\_node\_group](#input\_create\_system\_node\_group) | Create the baseline self-managed ASG that hosts cluster-critical controllers<br/>(CoreDNS, Karpenter, the load balancer controller).<br/><br/>Karpenter cannot provision the nodes it runs on, so this ASG is the bootstrap<br/>floor for the whole cluster. Disable it only if you are supplying an equivalent<br/>group through `self_managed_node_groups`. | `bool` | `true` | no |
| <a name="input_enable_cluster_creator_admin_permissions"></a> [enable\_cluster\_creator\_admin\_permissions](#input\_enable\_cluster\_creator\_admin\_permissions) | Grant cluster-admin to the IAM principal that runs `terraform apply`. Convenient for<br/>bootstrapping but means the CI role is a permanent cluster admin. Prefer false in<br/>production and grant access explicitly through `access_entries`. | `bool` | `false` | no |
| <a name="input_enable_efs_csi_driver"></a> [enable\_efs\_csi\_driver](#input\_enable\_efs\_csi\_driver) | Install the EFS CSI driver add-on. Only needed when workloads require ReadWriteMany volumes. | `bool` | `false` | no |
| <a name="input_enable_irsa"></a> [enable\_irsa](#input\_enable\_irsa) | Create the IAM OIDC provider for the cluster. Pod Identity is the preferred<br/>mechanism, but IRSA remains necessary for third-party controllers that do not yet<br/>support Pod Identity, and for cross-account role assumption from pods. | `bool` | `true` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Provision the AWS-side resources Karpenter needs: the node IAM role and its access<br/>entry, the controller IAM role with a Pod Identity association, the SQS interruption<br/>queue and the EventBridge rules that feed it.<br/><br/>The Karpenter controller itself is installed by the eks-addons module via Helm. | `bool` | `true` | no |
| <a name="input_enable_mountpoint_s3_csi_driver"></a> [enable\_mountpoint\_s3\_csi\_driver](#input\_enable\_mountpoint\_s3\_csi\_driver) | Install the Mountpoint for Amazon S3 CSI driver add-on. | `bool` | `false` | no |
| <a name="input_enable_pod_identity_roles"></a> [enable\_pod\_identity\_roles](#input\_enable\_pod\_identity\_roles) | Create EKS Pod Identity roles and associations for the platform add-ons installed by<br/>the eks-gateway and eks-addons modules: the AWS Load Balancer Controller, cert-manager,<br/>external-dns and the EBS/EFS CSI drivers.<br/><br/>Pod Identity is preferred over IRSA: no OIDC provider trust to manage, roles are<br/>reusable across clusters, and credentials are brokered per pod rather than per node. | `bool` | `true` | no |
| <a name="input_enable_secrets_encryption"></a> [enable\_secrets\_encryption](#input\_enable\_secrets\_encryption) | Enable envelope encryption of Kubernetes Secrets with a customer-managed KMS key.<br/>Without this, Secrets are stored in etcd with AWS-managed encryption only.<br/>Required by most compliance regimes and by CIS EKS Benchmark 2.x. | `bool` | `true` | no |
| <a name="input_enabled_log_types"></a> [enabled\_log\_types](#input\_enabled\_log\_types) | Control-plane log types shipped to CloudWatch Logs. `audit` and `authenticator` are<br/>the two that matter for security investigations; omitting them leaves no record of<br/>who did what in the cluster. | `list(string)` | <pre>[<br/>  "api",<br/>  "audit",<br/>  "authenticator",<br/>  "controllerManager",<br/>  "scheduler"<br/>]</pre> | no |
| <a name="input_endpoint_private_access"></a> [endpoint\_private\_access](#input\_endpoint\_private\_access) | Enable the private Kubernetes API endpoint. Should always be true. | `bool` | `true` | no |
| <a name="input_endpoint_public_access"></a> [endpoint\_public\_access](#input\_endpoint\_public\_access) | Expose the Kubernetes API server publicly. Set to false for a fully private cluster<br/>reachable only from inside the VPC or over VPN/Direct Connect. When true you must<br/>supply `endpoint_public_access_cidrs`. | `bool` | `false` | no |
| <a name="input_endpoint_public_access_cidrs"></a> [endpoint\_public\_access\_cidrs](#input\_endpoint\_public\_access\_cidrs) | CIDR blocks permitted to reach the public API endpoint. Leaving this at 0.0.0.0/0<br/>exposes the Kubernetes API to the entire internet and is rejected by a validation<br/>rule below. Supply office ranges, VPN egress IPs or CI runner ranges. | `list(string)` | `[]` | no |
| <a name="input_external_dns_hosted_zone_arns"></a> [external\_dns\_hosted\_zone\_arns](#input\_external\_dns\_hosted\_zone\_arns) | Route 53 hosted zone ARNs external-dns may modify. Defaults to all zones in the account, which should be narrowed in production. | `list(string)` | <pre>[<br/>  "arn:aws:route53:::hostedzone/*"<br/>]</pre> | no |
| <a name="input_ip_family"></a> [ip\_family](#input\_ip\_family) | IP family for the cluster: `ipv4` or `ipv6`. | `string` | `"ipv4"` | no |
| <a name="input_karpenter_namespace"></a> [karpenter\_namespace](#input\_karpenter\_namespace) | Namespace the Karpenter controller runs in. Must match the eks-addons module. | `string` | `"kube-system"` | no |
| <a name="input_karpenter_service_account"></a> [karpenter\_service\_account](#input\_karpenter\_service\_account) | Service account name used by the Karpenter controller. | `string` | `"karpenter"` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of an existing KMS key to use for Secrets envelope encryption. Leave empty to have the module create and manage a dedicated key. | `string` | `""` | no |
| <a name="input_kms_key_deletion_window_in_days"></a> [kms\_key\_deletion\_window\_in\_days](#input\_kms\_key\_deletion\_window\_in\_days) | Waiting period before a module-created KMS key is deleted. Deleting the key makes every Secret in the cluster permanently unreadable, so a long window is deliberate. | `number` | `30` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes minor version for the control plane, e.g. "1.37". Only versions in EKS<br/>standard support should be used; extended support incurs a significant per-cluster<br/>hourly surcharge and eventually forces an automatic upgrade. | `string` | `"1.37"` | no |
| <a name="input_node_additional_iam_policies"></a> [node\_additional\_iam\_policies](#input\_node\_additional\_iam\_policies) | Extra IAM policy ARNs attached to the node role, keyed by a friendly name.<br/><br/>Do not grant broad data-plane permissions here. Anything a specific workload needs<br/>must be granted with EKS Pod Identity so it is scoped to that one service account,<br/>not to every pod on the node. | `map(string)` | `{}` | no |
| <a name="input_node_data_disk_size"></a> [node\_data\_disk\_size](#input\_node\_data\_disk\_size) | Size in GiB of the Bottlerocket data volume (`/dev/xvdb`), which holds container<br/>images, writable layers and ephemeral storage. Size this against your image<br/>footprint; Bottlerocket grows the partition to fill the device at boot.<br/><br/>On a non-Bottlerocket AMI this sizes the single root volume instead. | `number` | `100` | no |
| <a name="input_node_ebs_kms_key_arn"></a> [node\_ebs\_kms\_key\_arn](#input\_node\_ebs\_kms\_key\_arn) | KMS key ARN for node volume encryption. Leave empty to use the AWS-managed EBS<br/>key. Volumes are always encrypted.<br/><br/>A customer-managed key must grant the Auto Scaling service-linked role<br/>`kms:CreateGrant` and `kms:GenerateDataKeyWithoutPlaintext`, or instances fail to<br/>launch with an opaque client error. | `string` | `""` | no |
| <a name="input_node_group_defaults"></a> [node\_group\_defaults](#input\_node\_group\_defaults) | Defaults merged into every self-managed node group, including the baseline system ASG. Overridden by per-group settings. | `any` | `{}` | no |
| <a name="input_node_os_disk_size"></a> [node\_os\_disk\_size](#input\_node\_os\_disk\_size) | Size in GiB of the Bottlerocket OS volume (`/dev/xvda`), which holds the A/B<br/>partition sets, bootloader, dm-verity hash tree and API datastore. Container data<br/>does not live here, so this rarely needs enlarging. | `number` | `10` | no |
| <a name="input_node_security_group_additional_rules"></a> [node\_security\_group\_additional\_rules](#input\_node\_security\_group\_additional\_rules) | Additional rules added to the shared node security group. | `any` | `{}` | no |
| <a name="input_node_security_group_tags"></a> [node\_security\_group\_tags](#input\_node\_security\_group\_tags) | Extra tags for the node security group. The Karpenter discovery tag is added automatically. | `map(string)` | `{}` | no |
| <a name="input_node_volume_type"></a> [node\_volume\_type](#input\_node\_volume\_type) | EBS volume type for node volumes. gp3 is cheaper and faster than gp2 and should always be preferred. | `string` | `"gp3"` | no |
| <a name="input_public_subnet_ids"></a> [public\_subnet\_ids](#input\_public\_subnet\_ids) | Public subnet IDs. Not used by the cluster itself; exposed as an output so the gateway module can place internet-facing load balancers. | `list(string)` | `[]` | no |
| <a name="input_self_managed_node_groups"></a> [self\_managed\_node\_groups](#input\_self\_managed\_node\_groups) | Additional self-managed node group (ASG) definitions, keyed by name. Merged over<br/>`node_group_defaults`. The baseline system ASG is created separately and does not<br/>need to be listed here.<br/><br/>These become `self_managed_node_groups` on the upstream EKS module, whose type is<br/>strongly typed: an unrecognised key is a hard error, not a silent no-op. Note<br/>`instance_type` is singular; use `use_mixed_instances_policy` for several types.<br/><br/>There is no `labels` or `taints` argument, because there is no EKS node group API<br/>to apply them. Pass them as Bottlerocket TOML in `bootstrap_extra_args`.<br/><br/>Example:<pre>self_managed_node_groups = {<br/>  memory = {<br/>    instance_type = "r7i.xlarge"<br/>    min_size      = 2<br/>    max_size      = 4<br/>    desired_size  = 2<br/><br/>    bootstrap_extra_args = <<-TOML<br/>      [settings.kubernetes.node-labels]<br/>      "workload-class" = "memory"<br/>    TOML<br/>  }<br/>}</pre> | `any` | `{}` | no |
| <a name="input_service_ipv4_cidr"></a> [service\_ipv4\_cidr](#input\_service\_ipv4\_cidr) | CIDR block for Kubernetes Service IPs. Must not overlap the VPC CIDR. Leave empty for the EKS default (172.20.0.0/16). | `string` | `""` | no |
| <a name="input_system_node_group_autoscaling_group_tags"></a> [system\_node\_group\_autoscaling\_group\_tags](#input\_system\_node\_group\_autoscaling\_group\_tags) | Extra tags applied to the baseline ASG itself, not propagated to instances.<br/><br/>Do not add Cluster Autoscaler discovery tags (`k8s.io/cluster-autoscaler/*`).<br/>This ASG is fixed baseline capacity and Karpenter owns elastic scaling; two<br/>controllers resizing one ASG produces thrash and orphaned nodes. | `map(string)` | `{}` | no |
| <a name="input_system_node_group_desired_size"></a> [system\_node\_group\_desired\_size](#input\_system\_node\_group\_desired\_size) | Desired size of the baseline ASG at creation time. Ignored on subsequent applies<br/>because the upstream ASG ignores `desired_capacity`; change `min_size` instead. | `number` | `2` | no |
| <a name="input_system_node_group_instance_types"></a> [system\_node\_group\_instance\_types](#input\_system\_node\_group\_instance\_types) | Instance types for the baseline system ASG, in order of preference. Keep them<br/>small; only controllers run here.<br/><br/>Listing more than one enables a mixed instances policy pinned to 100% on-demand,<br/>so a single Insufficient Capacity Exception cannot leave the cluster with no<br/>baseline. Spot is never used for baseline capacity — that is Karpenter's job. | `list(string)` | <pre>[<br/>  "m7i.large",<br/>  "m7a.large",<br/>  "m6i.large"<br/>]</pre> | no |
| <a name="input_system_node_group_labels"></a> [system\_node\_group\_labels](#input\_system\_node\_group\_labels) | Extra Kubernetes node labels for the baseline ASG, merged over the default<br/>`node.kubernetes.io/role = system`.<br/><br/>These are self-set by the kubelet at registration, so the NodeRestriction<br/>admission plugin applies: a key in the `kubernetes.io` or `k8s.io` namespaces<br/>that is not explicitly allowed (`node-role.kubernetes.io/*`, for instance) will<br/>stop the kubelet starting. Unprefixed keys are always safe. | `map(string)` | `{}` | no |
| <a name="input_system_node_group_max_size"></a> [system\_node\_group\_max\_size](#input\_system\_node\_group\_max\_size) | Maximum size of the baseline ASG. Nothing scales this group, so the only reason<br/>to set it above `min_size` is to give instance refresh room to surge during an<br/>AMI roll. Twice the minimum is a reasonable default. | `number` | `4` | no |
| <a name="input_system_node_group_min_size"></a> [system\_node\_group\_min\_size](#input\_system\_node\_group\_min\_size) | Minimum size of the baseline ASG, and in practice its steady-state size.<br/><br/>The upstream module hardcodes `ignore_changes = [desired_capacity]` on the ASG,<br/>so after creation this value is what actually holds the floor. Two is the minimum<br/>for a highly available controller layout. | `number` | `2` | no |
| <a name="input_system_node_group_taint_system_workloads"></a> [system\_node\_group\_taint\_system\_workloads](#input\_system\_node\_group\_taint\_system\_workloads) | Apply the `CriticalAddonsOnly=true:NoSchedule` taint to the baseline ASG so that<br/>application pods are forced onto Karpenter-managed capacity. Add-ons installed by<br/>the eks-addons, eks-gateway and istio modules tolerate this taint automatically. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource created by this module. | `map(string)` | `{}` | no |
| <a name="input_vpc_cni_configuration"></a> [vpc\_cni\_configuration](#input\_vpc\_cni\_configuration) | Configuration passed to the vpc-cni add-on. Prefix delegation is enabled by default<br/>because it raises the pod-per-node density ceiling substantially and reduces ENI<br/>churn. Network policy support is enabled so Kubernetes NetworkPolicy objects are<br/>actually enforced. | `any` | <pre>{<br/>  "enableNetworkPolicy": "true",<br/>  "env": {<br/>    "AWS_VPC_K8S_CNI_LOGLEVEL": "INFO",<br/>    "ENABLE_POD_ENI": "false",<br/>    "ENABLE_PREFIX_DELEGATION": "true",<br/>    "WARM_PREFIX_TARGET": "1"<br/>  }<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_addons_input"></a> [addons\_input](#output\_addons\_input) | Pre-assembled inputs for the eks-gateway and eks-addons modules, so the bootstrap layer does not have to rewire every value. |
| <a name="output_bottlerocket_ssm_parameter"></a> [bottlerocket\_ssm\_parameter](#output\_bottlerocket\_ssm\_parameter) | SSM public parameter the baseline AMI was resolved from. Useful for confirming the pin. |
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | ARN of the EKS cluster. |
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Base64-encoded certificate authority data for the cluster. Required to configure the kubernetes, helm and kubectl providers. |
| <a name="output_cluster_connection"></a> [cluster\_connection](#output\_cluster\_connection) | Everything the kubernetes, helm and kubectl providers need in a single object. Pass straight into the bootstrap layer. |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Endpoint of the Kubernetes API server. |
| <a name="output_cluster_iam_role_arn"></a> [cluster\_iam\_role\_arn](#output\_cluster\_iam\_role\_arn) | ARN of the IAM role assumed by the EKS control plane. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the EKS cluster. |
| <a name="output_cluster_oidc_issuer_url"></a> [cluster\_oidc\_issuer\_url](#output\_cluster\_oidc\_issuer\_url) | OIDC issuer URL of the cluster, used by IRSA. |
| <a name="output_cluster_platform_version"></a> [cluster\_platform\_version](#output\_cluster\_platform\_version) | EKS platform version of the cluster. |
| <a name="output_cluster_primary_security_group_id"></a> [cluster\_primary\_security\_group\_id](#output\_cluster\_primary\_security\_group\_id) | ID of the cluster primary security group created by EKS itself. |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | ID of the EKS-managed cluster security group attached to the control-plane ENIs. |
| <a name="output_cluster_status"></a> [cluster\_status](#output\_cluster\_status) | Status of the EKS cluster. |
| <a name="output_cluster_version"></a> [cluster\_version](#output\_cluster\_version) | Kubernetes version running on the control plane. |
| <a name="output_karpenter_controller_iam_role_arn"></a> [karpenter\_controller\_iam\_role\_arn](#output\_karpenter\_controller\_iam\_role\_arn) | ARN of the Karpenter controller IAM role. |
| <a name="output_karpenter_namespace"></a> [karpenter\_namespace](#output\_karpenter\_namespace) | Namespace the Karpenter controller must run in. |
| <a name="output_karpenter_node_iam_role_arn"></a> [karpenter\_node\_iam\_role\_arn](#output\_karpenter\_node\_iam\_role\_arn) | ARN of the IAM role Karpenter-provisioned nodes assume. |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | Name of the Karpenter node IAM role. Reference this in the EC2NodeClass `role` field. |
| <a name="output_karpenter_queue_name"></a> [karpenter\_queue\_name](#output\_karpenter\_queue\_name) | Name of the SQS queue receiving spot interruption notices. Pass to the Karpenter Helm chart as `settings.interruptionQueue`. |
| <a name="output_karpenter_service_account"></a> [karpenter\_service\_account](#output\_karpenter\_service\_account) | Service account name the Karpenter controller must use to pick up its Pod Identity association. |
| <a name="output_kubeconfig_command"></a> [kubeconfig\_command](#output\_kubeconfig\_command) | AWS CLI command that writes a kubeconfig entry for this cluster. |
| <a name="output_node_iam_role_arn"></a> [node\_iam\_role\_arn](#output\_node\_iam\_role\_arn) | ARN of the IAM role attached to node instances. |
| <a name="output_node_iam_role_name"></a> [node\_iam\_role\_name](#output\_node\_iam\_role\_name) | Name of the IAM role attached to node instances. |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | ID of the shared node security group. Carries the karpenter.sh/discovery tag. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the IAM OIDC provider, or null when enable\_irsa is false. |
| <a name="output_pod_identity_role_arns"></a> [pod\_identity\_role\_arns](#output\_pod\_identity\_role\_arns) | Map of platform add-on name to the IAM role ARN associated with its service account. |
| <a name="output_secrets_kms_key_arn"></a> [secrets\_kms\_key\_arn](#output\_secrets\_kms\_key\_arn) | ARN of the KMS key encrypting Kubernetes Secrets, or null when encryption is disabled. |
| <a name="output_self_managed_node_group_names"></a> [self\_managed\_node\_group\_names](#output\_self\_managed\_node\_group\_names) | Names of the self-managed node groups. |
| <a name="output_self_managed_node_groups"></a> [self\_managed\_node\_groups](#output\_self\_managed\_node\_groups) | Attributes of the self-managed node groups (ASGs), keyed by name. |
| <a name="output_system_node_group_ami_id"></a> [system\_node\_group\_ami\_id](#output\_system\_node\_group\_ami\_id) | AMI ID the baseline system ASG is pinned to. Changes here replace every baseline node. |
<!-- END_TF_DOCS -->
