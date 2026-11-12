# `eks-addons`

The platform controllers that make an EKS cluster usable: Karpenter for
compute, cert-manager for certificates, external-dns for DNS, metrics-server
for autoscaling, an encrypted gp3 default StorageClass, and optionally Argo CD
and kube-prometheus-stack.

---

## Contents

- [What it installs](#what-it-installs)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Karpenter](#karpenter)
- [Storage](#storage)
- [external-dns](#external-dns)
- [cert-manager](#cert-manager)
- [Secrets](#secrets)
- [Scheduling](#scheduling)
- [Troubleshooting](#troubleshooting)
- [Generated reference](#requirements)

---

## What it installs

| Component | Chart | Default | Purpose |
|---|---|---|---|
| Karpenter | `1.15.1` | on | Dynamic node provisioning |
| cert-manager | `v1.21.3` | on | In-cluster certificate issuance |
| external-dns | `1.23.0` | on | Route 53 records from Gateways and Services |
| metrics-server | `3.14.0` | on | Resource metrics API for HPA |
| gp3 StorageClass | — | on | Encrypted default storage |
| Argo CD | `10.18.0` | off | GitOps application delivery |
| kube-prometheus-stack | `93.2.2` | off | Prometheus, Alertmanager, Grafana |

Chart versions are pinned, not floating. A floating version turns an unrelated
apply into an unplanned upgrade.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | `>= 1.10.0` |
| Providers | `aws >= 6.59`, `helm >= 3.3`, `kubernetes >= 3.5`, `kubectl (alekc) >= 3.0` |
| Cluster | EKS with Pod Identity associations from [`modules/eks`](../eks) |
| Karpenter inputs | `karpenter_queue_name` and `karpenter_node_iam_role_name` from `modules/eks` |
| Gateway CRDs | Install [`modules/eks-gateway`](../eks-gateway) **first** if `external_dns_sources` includes `gateway-*` |
| Route 53 | A hosted zone matching `external_dns_domain_filters` |

---

## Quick start

```hcl
module "addons" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/eks-addons?ref=eks-addons-v1.0.0"

  cluster_name = "platform-prod"
  region       = "eu-central-1"

  enable_karpenter             = true
  karpenter_queue_name         = module.eks.karpenter_queue_name
  karpenter_node_iam_role_name = module.eks.karpenter_node_iam_role_name

  create_default_node_pool = true
  node_pool_capacity_types = ["on-demand"]
  node_pool_cpu_limit      = 2000

  enable_cert_manager   = true
  enable_metrics_server = true

  enable_external_dns         = true
  external_dns_domain_filters = ["example.com"]
  external_dns_policy         = "upsert-only"

  tags = { Environment = "prod" }
}
```

---

## Karpenter

The IAM roles, instance profile and interruption SQS queue come from
[`modules/eks`](../eks). This module installs the controller and, optionally, a
starter `EC2NodeClass` and `NodePool`.

### CRDs are installed separately, on purpose

Helm installs a chart's bundled CRDs on first install and never upgrades them.
A Karpenter version bump would then leave the old `NodePool` schema in place,
and new fields would be silently ignored. This module installs the dedicated
`karpenter-crd` chart first and sets `skip_crds = true` on the main release, so
upgrades actually take effect.

### The default NodePool

```
capacity types   spot + on-demand   Karpenter price-optimises across the whole list
instance types   c / m / r, gen ≥6  A wide list materially improves spot availability
AMI              al2023@latest      AL2 is end-of-life
root volume      100Gi gp3, encrypted
IMDS             hop limit 1, tokens required
expireAfter      720h               Bounded node age is what delivers AMI patches
consolidation    WhenEmptyOrUnderutilized
budget           10% of nodes at once
limits           node_pool_cpu_limit vCPU
```

**`node_pool_cpu_limit` is the single most important setting here.** It is the
hard ceiling on scale-out and the only thing standing between a runaway
`ReplicaSet` and a five-figure bill.

**Consolidation is disruptive.** `WhenEmptyOrUnderutilized` repacks
underutilised nodes, so workloads need `PodDisruptionBudget`s. If yours do not
have them yet, start with `WhenEmpty`.

**`al2023@latest` changes without a Terraform diff.** That keeps nodes patched
automatically, but it also means the AMI can change under you. In production,
pin a dated alias such as `al2023@v20260501` and roll it deliberately.

Set `create_default_node_pool = false` once node pools are owned by a GitOps
repository — the better end state for most platform teams.

---

## Storage

EKS ships a `gp2` StorageClass marked default. gp3 is cheaper per GiB, has
baseline performance decoupled from volume size, and is the right default for
essentially every workload. `create_gp3_storage_class = true`:

- creates an **encrypted** gp3 class and marks it default;
- demotes `gp2` — two defaults at once is an error condition for the scheduler;
- uses `WaitForFirstConsumer`, so the volume is created in the zone the pod can
  actually be scheduled in, rather than deadlocking a pod against a volume in a
  zone with no capacity.

Supply `gp3_kms_key_id` to use a customer-managed key.

---

## external-dns

**Always set `external_dns_domain_filters`.** An unfiltered controller acts on
every hosted zone its IAM role can reach — that is how one cluster deletes
another cluster's DNS records.

| Setting | Default | Note |
|---|---|---|
| `external_dns_policy` | `upsert-only` | Never deletes. Safe, at the cost of orphaned records |
| | `sync` | Full reconciliation including deletes. Only when this cluster solely owns the zone |
| `txtOwnerId` | cluster name | TXT ownership records so two clusters sharing a zone cannot fight |

Sources default to `service`, `ingress` and the `gateway-*` routes. The
`gateway-*` sources are what make Gateway API hostnames resolvable — but they
require the Gateway API CRDs, so install
[`modules/eks-gateway`](../eks-gateway) first or external-dns will crash-loop.

---

## cert-manager

Scoped to in-cluster TLS. Traffic entering through an ALB or NLB terminates on
**ACM** instead, so most clusters need cert-manager only for webhook
certificates, Istio custom CAs, and service-to-service TLS.

`dns01RecursiveNameserversOnly` is enabled: ACME self-checks resolve against
public DNS rather than the in-cluster resolver, which would answer from a
private hosted zone and never let the challenge pass.

Set `cert_manager_enable_gateway_api = true` only if you terminate TLS inside
the cluster.

---

## Secrets

This module deliberately exposes **no password variables** for Argo CD or
Grafana. Anything passed to a chart from Terraform is stored in plaintext in
state.

Both charts generate a random bootstrap password into a Secret. Read it once,
then configure SSO and disable the local account:

```bash
terraform output -raw argocd_initial_password_command | bash
terraform output -raw grafana_initial_password_command | bash
```

---

## Scheduling

Every controller here is pinned to the baseline ASG via
`critical_addons_node_selector` and `critical_addons_tolerations`, and runs
with the `system-cluster-critical` priority class.

This is not a preference. Karpenter cannot provision the node it is itself
running on, so if the controllers lived on Karpenter capacity, a spot reclaim
of the wrong node would take the cluster's ability to heal itself down with it.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| NodeClaims stay `Pending` | Subnets or SG missing `karpenter.sh/discovery` | Tag them, delete the stuck NodeClaims |
| Karpenter `AccessDenied` | Pod Identity association namespace/SA mismatch | Must match `karpenter_namespace` and `karpenter_service_account` in `modules/eks` |
| Nodes launch then disappear | Interruption queue not wired | Pass `karpenter_queue_name` |
| external-dns CrashLoopBackOff | `gateway-*` sources but no Gateway API CRDs | Install `modules/eks-gateway` first |
| No DNS records created | `domain_filters` does not match the hostname | Widen the filter |
| PVC stuck `Pending` | gp2 and gp3 both default, or no CSI driver | `kubectl get sc`; exactly one should be default |
| HPA reports `<unknown>` | metrics-server not ready | `kubectl top nodes` |

---

## Examples

| Example | Description |
|---|---|
| [`complete`](examples/complete) | Karpenter plus the full controller set |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.59.0, < 7.0.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.3.0, < 4.0.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 3.0.0, < 4.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 3.5.0, < 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.3.0, < 4.0.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 3.0.0, < 4.0.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 3.5.0, < 4.0.0 |

## Resources

| Name | Type |
|------|------|
| [helm_release.argocd](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.cert_manager](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.external_dns](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.karpenter](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.karpenter_crd](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.metrics_server](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.monitoring](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.ec2_node_class](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.node_pool](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_annotations.gp2_not_default](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/annotations) | resource |
| [kubernetes_storage_class_v1.gp3](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster these add-ons are installed into. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region the cluster runs in. Passed to controllers that need to call regional AWS APIs. | `string` | n/a | yes |
| <a name="input_argocd_chart_version"></a> [argocd\_chart\_version](#input\_argocd\_chart\_version) | Argo CD chart version. | `string` | `"10.18.0"` | no |
| <a name="input_argocd_namespace"></a> [argocd\_namespace](#input\_argocd\_namespace) | Namespace for Argo CD. | `string` | `"argocd"` | no |
| <a name="input_argocd_values"></a> [argocd\_values](#input\_argocd\_values) | Additional values merged over the computed Argo CD chart values.<br/><br/>The module deliberately does not expose an admin password variable: a password set<br/>in Terraform ends up in plaintext in state. Leave the generated bootstrap secret in<br/>place, read it once with kubectl, then disable local accounts and wire SSO through<br/>this variable. | `any` | `{}` | no |
| <a name="input_cert_manager_chart_version"></a> [cert\_manager\_chart\_version](#input\_cert\_manager\_chart\_version) | cert-manager chart version. Note this chart keeps the leading "v". | `string` | `"v1.21.3"` | no |
| <a name="input_cert_manager_enable_gateway_api"></a> [cert\_manager\_enable\_gateway\_api](#input\_cert\_manager\_enable\_gateway\_api) | Let cert-manager issue certificates for Gateway listeners annotated with<br/>cert-manager.io/issuer. Only useful when certificates are terminated inside the<br/>cluster — Gateways fronted by an ALB or NLB terminate on ACM instead and do not<br/>need this. | `bool` | `false` | no |
| <a name="input_cert_manager_namespace"></a> [cert\_manager\_namespace](#input\_cert\_manager\_namespace) | Namespace for cert-manager. Must match the Pod Identity association created in modules/eks. | `string` | `"cert-manager"` | no |
| <a name="input_cert_manager_values"></a> [cert\_manager\_values](#input\_cert\_manager\_values) | Additional values merged over the computed cert-manager chart values. | `any` | `{}` | no |
| <a name="input_create_default_node_pool"></a> [create\_default\_node\_pool](#input\_create\_default\_node\_pool) | Create a default EC2NodeClass and NodePool so the cluster can scale out<br/>immediately after bootstrap. Set to false when node pools are owned by a separate<br/>GitOps repository, which is the better end state for most platform teams. | `bool` | `true` | no |
| <a name="input_create_gp3_storage_class"></a> [create\_gp3\_storage\_class](#input\_create\_gp3\_storage\_class) | Create an encrypted gp3 StorageClass and make it the cluster default.<br/><br/>EKS ships a `gp2` default StorageClass that is slower, more expensive and not<br/>encrypted with a customer-managed key. This replaces it as the default so that any<br/>PersistentVolumeClaim without an explicit storageClassName lands on gp3. | `bool` | `true` | no |
| <a name="input_critical_addons_node_selector"></a> [critical\_addons\_node\_selector](#input\_critical\_addons\_node\_selector) | Node selector applied to every controller installed by this module. | `map(string)` | <pre>{<br/>  "node.kubernetes.io/role": "system"<br/>}</pre> | no |
| <a name="input_critical_addons_tolerations"></a> [critical\_addons\_tolerations](#input\_critical\_addons\_tolerations) | Tolerations applied to every controller installed by this module. Must match the taint on the baseline system ASG. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string)<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | <pre>[<br/>  {<br/>    "effect": "NoSchedule",<br/>    "key": "CriticalAddonsOnly",<br/>    "operator": "Equal",<br/>    "value": "true"<br/>  }<br/>]</pre> | no |
| <a name="input_enable_argocd"></a> [enable\_argocd](#input\_enable\_argocd) | Install Argo CD. Installing it from Terraform and then letting it manage applications from Git is the usual hand-off point between infrastructure and application delivery. | `bool` | `false` | no |
| <a name="input_enable_cert_manager"></a> [enable\_cert\_manager](#input\_enable\_cert\_manager) | Install cert-manager. Required for Istio custom CAs, webhook certificates and any in-cluster TLS that does not terminate on an ACM-backed load balancer. | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | Install external-dns to publish Route 53 records for Gateways, Services and Ingresses. | `bool` | `true` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Install the Karpenter controller. The IAM roles, instance profile and interruption queue are created by modules/eks; this installs the workload that uses them. | `bool` | `true` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Install metrics-server. Required by HorizontalPodAutoscaler and `kubectl top`; nothing else provides the resource metrics API. | `bool` | `true` | no |
| <a name="input_enable_monitoring"></a> [enable\_monitoring](#input\_enable\_monitoring) | Install kube-prometheus-stack (Prometheus, Alertmanager, Grafana and the standard Kubernetes dashboards and alerts). | `bool` | `false` | no |
| <a name="input_external_dns_chart_version"></a> [external\_dns\_chart\_version](#input\_external\_dns\_chart\_version) | external-dns chart version. | `string` | `"1.23.0"` | no |
| <a name="input_external_dns_domain_filters"></a> [external\_dns\_domain\_filters](#input\_external\_dns\_domain\_filters) | Domains external-dns is allowed to manage. Leaving this empty lets the controller<br/>operate on every hosted zone its IAM role can reach, which is how one cluster ends<br/>up deleting another cluster's records. Always set it. | `list(string)` | `[]` | no |
| <a name="input_external_dns_namespace"></a> [external\_dns\_namespace](#input\_external\_dns\_namespace) | Namespace for external-dns. Must match the Pod Identity association created in modules/eks. | `string` | `"external-dns"` | no |
| <a name="input_external_dns_policy"></a> [external\_dns\_policy](#input\_external\_dns\_policy) | How external-dns reconciles records.<br/><br/>  "upsert-only" - creates and updates records but never deletes. Safe default; the<br/>                  cost is orphaned records when a Gateway is removed.<br/>  "sync"        - full reconciliation including deletion. Correct for a cluster that<br/>                  exclusively owns its hosted zone, dangerous otherwise. | `string` | `"upsert-only"` | no |
| <a name="input_external_dns_sources"></a> [external\_dns\_sources](#input\_external\_dns\_sources) | Kubernetes resources external-dns watches. The gateway-* sources are what make Gateway API hostnames resolvable. | `list(string)` | <pre>[<br/>  "service",<br/>  "ingress",<br/>  "gateway-httproute",<br/>  "gateway-grpcroute",<br/>  "gateway-tlsroute"<br/>]</pre> | no |
| <a name="input_external_dns_values"></a> [external\_dns\_values](#input\_external\_dns\_values) | Additional values merged over the computed external-dns chart values. | `any` | `{}` | no |
| <a name="input_gp3_kms_key_id"></a> [gp3\_kms\_key\_id](#input\_gp3\_kms\_key\_id) | KMS key for the gp3 StorageClass. Null uses the account default EBS key. | `string` | `null` | no |
| <a name="input_helm_timeout"></a> [helm\_timeout](#input\_helm\_timeout) | Seconds to wait for each Helm release to become ready. | `number` | `900` | no |
| <a name="input_karpenter_chart_repository"></a> [karpenter\_chart\_repository](#input\_karpenter\_chart\_repository) | OCI registry serving the Karpenter chart. Note there is no leading "v" on the chart version in this registry. | `string` | `"oci://public.ecr.aws/karpenter"` | no |
| <a name="input_karpenter_chart_version"></a> [karpenter\_chart\_version](#input\_karpenter\_chart\_version) | Karpenter chart version. Must be compatible with the cluster's Kubernetes minor<br/>version — Karpenter supports a narrow window and a mismatch surfaces as nodes that<br/>are launched but never become Ready. | `string` | `"1.15.1"` | no |
| <a name="input_karpenter_namespace"></a> [karpenter\_namespace](#input\_karpenter\_namespace) | Namespace the Karpenter controller runs in. Must match the namespace used for its Pod Identity association in modules/eks. | `string` | `"kube-system"` | no |
| <a name="input_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#input\_karpenter\_node\_iam\_role\_name) | Name of the IAM role Karpenter-provisioned nodes assume. From the karpenter\_node\_iam\_role\_name output of modules/eks. Referenced by the default EC2NodeClass. | `string` | `null` | no |
| <a name="input_karpenter_queue_name"></a> [karpenter\_queue\_name](#input\_karpenter\_queue\_name) | Name of the SQS queue carrying spot interruption and instance health events. From the karpenter\_queue\_name output of modules/eks. | `string` | `null` | no |
| <a name="input_karpenter_replicas"></a> [karpenter\_replicas](#input\_karpenter\_replicas) | Karpenter controller replicas. Two gives leader-election failover; Karpenter is active/passive so this does not increase throughput. | `number` | `2` | no |
| <a name="input_karpenter_service_account"></a> [karpenter\_service\_account](#input\_karpenter\_service\_account) | Service account name for the Karpenter controller. Must match the Pod Identity association created in modules/eks, otherwise the controller runs with no AWS permissions. | `string` | `"karpenter"` | no |
| <a name="input_karpenter_values"></a> [karpenter\_values](#input\_karpenter\_values) | Additional values merged over the computed Karpenter chart values. | `any` | `{}` | no |
| <a name="input_metrics_server_chart_version"></a> [metrics\_server\_chart\_version](#input\_metrics\_server\_chart\_version) | metrics-server chart version. | `string` | `"3.14.0"` | no |
| <a name="input_metrics_server_values"></a> [metrics\_server\_values](#input\_metrics\_server\_values) | Additional values merged over the computed metrics-server chart values. | `any` | `{}` | no |
| <a name="input_monitoring_chart_version"></a> [monitoring\_chart\_version](#input\_monitoring\_chart\_version) | kube-prometheus-stack chart version. | `string` | `"93.2.2"` | no |
| <a name="input_monitoring_namespace"></a> [monitoring\_namespace](#input\_monitoring\_namespace) | Namespace for the monitoring stack. | `string` | `"monitoring"` | no |
| <a name="input_monitoring_retention"></a> [monitoring\_retention](#input\_monitoring\_retention) | How long Prometheus retains metrics locally. Longer retention needs a correspondingly larger volume. | `string` | `"15d"` | no |
| <a name="input_monitoring_storage_class"></a> [monitoring\_storage\_class](#input\_monitoring\_storage\_class) | StorageClass for the Prometheus volume. gp3 is cheaper and faster than gp2 and should be the cluster default. | `string` | `"gp3"` | no |
| <a name="input_monitoring_storage_size"></a> [monitoring\_storage\_size](#input\_monitoring\_storage\_size) | Size of the Prometheus persistent volume. | `string` | `"100Gi"` | no |
| <a name="input_monitoring_values"></a> [monitoring\_values](#input\_monitoring\_values) | Additional values merged over the computed kube-prometheus-stack values.<br/><br/>As with Argo CD, no Grafana password variable is exposed. Use the generated secret<br/>or configure SSO here. | `any` | `{}` | no |
| <a name="input_node_pool_ami_alias"></a> [node\_pool\_ami\_alias](#input\_node\_pool\_ami\_alias) | AMI alias for the default EC2NodeClass, e.g. "al2023@latest" or a pinned<br/>"al2023@v20260501". Amazon Linux 2 is end-of-life and must not be used.<br/><br/>"@latest" keeps nodes patched automatically but means the AMI can change without a<br/>Terraform diff. Pin the alias in production and roll it deliberately. | `string` | `"al2023@latest"` | no |
| <a name="input_node_pool_capacity_types"></a> [node\_pool\_capacity\_types](#input\_node\_pool\_capacity\_types) | Capacity types the default NodePool may use. Listing spot first does not imply preference — Karpenter always price-optimises across the whole list. | `list(string)` | <pre>[<br/>  "spot",<br/>  "on-demand"<br/>]</pre> | no |
| <a name="input_node_pool_consolidation_policy"></a> [node\_pool\_consolidation\_policy](#input\_node\_pool\_consolidation\_policy) | When Karpenter may consolidate nodes.<br/><br/>  "WhenEmptyOrUnderutilized" - also repacks underutilised nodes. Best cost result,<br/>                               but disrupts running pods, so workloads need<br/>                               PodDisruptionBudgets.<br/>  "WhenEmpty"                - only removes nodes with no workload pods. Safer and<br/>                               much less disruptive, but leaves money on the table. | `string` | `"WhenEmptyOrUnderutilized"` | no |
| <a name="input_node_pool_cpu_limit"></a> [node\_pool\_cpu\_limit](#input\_node\_pool\_cpu\_limit) | Maximum total vCPU the default NodePool may provision. This is the blast-radius control on runaway scale-out and the single most important cost guardrail. | `number` | `1000` | no |
| <a name="input_node_pool_disruption_budgets"></a> [node\_pool\_disruption\_budgets](#input\_node\_pool\_disruption\_budgets) | Disruption budgets limiting how much of the NodePool Karpenter may disrupt at once, and optionally during which windows. | <pre>list(object({<br/>    nodes    = string<br/>    reasons  = optional(list(string))<br/>    schedule = optional(string)<br/>    duration = optional(string)<br/>  }))</pre> | <pre>[<br/>  {<br/>    "nodes": "10%"<br/>  }<br/>]</pre> | no |
| <a name="input_node_pool_expire_after"></a> [node\_pool\_expire\_after](#input\_node\_pool\_expire\_after) | Maximum node lifetime before Karpenter proactively replaces it. Bounded node age forces regular AMI patching and prevents long-lived, drifted nodes. | `string` | `"720h"` | no |
| <a name="input_node_pool_instance_categories"></a> [node\_pool\_instance\_categories](#input\_node\_pool\_instance\_categories) | EC2 instance categories the default NodePool may select from. A broad list materially improves spot availability and price. | `list(string)` | <pre>[<br/>  "c",<br/>  "m",<br/>  "r"<br/>]</pre> | no |
| <a name="input_node_pool_instance_generations"></a> [node\_pool\_instance\_generations](#input\_node\_pool\_instance\_generations) | Minimum EC2 instance generation. Restricting to recent generations avoids scheduling onto obsolete, poor price-performance hardware. | `number` | `6` | no |
| <a name="input_node_pool_kms_key_id"></a> [node\_pool\_kms\_key\_id](#input\_node\_pool\_kms\_key\_id) | KMS key for encrypting Karpenter node root volumes. Null uses the account's default EBS key, which is still encrypted but not customer-managed. | `string` | `null` | no |
| <a name="input_node_pool_security_group_selector_tags"></a> [node\_pool\_security\_group\_selector\_tags](#input\_node\_pool\_security\_group\_selector\_tags) | Tags used by the default EC2NodeClass to discover security groups for new nodes. modules/eks applies karpenter.sh/discovery to the shared node security group. | `map(string)` | `null` | no |
| <a name="input_node_pool_subnet_selector_tags"></a> [node\_pool\_subnet\_selector\_tags](#input\_node\_pool\_subnet\_selector\_tags) | Tags used by the default EC2NodeClass to discover subnets for new nodes. The networking module applies karpenter.sh/discovery to the private subnets. | `map(string)` | `null` | no |
| <a name="input_node_pool_volume_size"></a> [node\_pool\_volume\_size](#input\_node\_pool\_volume\_size) | Root EBS volume size for Karpenter-provisioned nodes. Container image layers, not application data, usually drive this. | `string` | `"100Gi"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to AWS resources created by this module. Not applied to Kubernetes objects, which have stricter key syntax. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_argocd_initial_password_command"></a> [argocd\_initial\_password\_command](#output\_argocd\_initial\_password\_command) | Command that reads the generated Argo CD admin password.<br/><br/>The password is not set from Terraform on purpose: any value passed to the chart<br/>would be stored in plaintext in state. Read it once, then configure SSO and<br/>disable the local admin account. |
| <a name="output_argocd_namespace"></a> [argocd\_namespace](#output\_argocd\_namespace) | Namespace Argo CD runs in. |
| <a name="output_cert_manager_namespace"></a> [cert\_manager\_namespace](#output\_cert\_manager\_namespace) | Namespace cert-manager runs in. |
| <a name="output_default_ec2_node_class_name"></a> [default\_ec2\_node\_class\_name](#output\_default\_ec2\_node\_class\_name) | Name of the default Karpenter EC2NodeClass. |
| <a name="output_default_node_pool_name"></a> [default\_node\_pool\_name](#output\_default\_node\_pool\_name) | Name of the default Karpenter NodePool, or null when node pools are managed elsewhere. |
| <a name="output_default_storage_class_name"></a> [default\_storage\_class\_name](#output\_default\_storage\_class\_name) | StorageClass used by PersistentVolumeClaims that do not name one. |
| <a name="output_external_dns_namespace"></a> [external\_dns\_namespace](#output\_external\_dns\_namespace) | Namespace external-dns runs in. |
| <a name="output_grafana_initial_password_command"></a> [grafana\_initial\_password\_command](#output\_grafana\_initial\_password\_command) | Command that reads the generated Grafana admin password. Not managed from Terraform, for the same reason as Argo CD. |
| <a name="output_karpenter_chart_version"></a> [karpenter\_chart\_version](#output\_karpenter\_chart\_version) | Karpenter chart version installed. |
| <a name="output_karpenter_installed"></a> [karpenter\_installed](#output\_karpenter\_installed) | Whether the Karpenter controller was installed. |
| <a name="output_karpenter_namespace"></a> [karpenter\_namespace](#output\_karpenter\_namespace) | Namespace the Karpenter controller runs in. |
| <a name="output_monitoring_namespace"></a> [monitoring\_namespace](#output\_monitoring\_namespace) | Namespace the monitoring stack runs in. |
<!-- END_TF_DOCS -->
