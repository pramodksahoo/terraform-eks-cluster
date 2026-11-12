# `layers/bootstrap`

The Kubernetes layer. Installs the Gateway API stack, Karpenter, the platform
add-ons and (optionally) Istio onto a cluster that
[`layers/infrastructure`](../infrastructure) already created.

Apply this **second**. Destroy it **first**.

---

## What it installs

| Module | Components |
|---|---|
| [`eks-gateway`](../../modules/eks-gateway) | Gateway API CRDs (v1.6.0), AWS Load Balancer Controller, ALB/NLB `GatewayClass`es, `Gateway`s |
| [`eks-addons`](../../modules/eks-addons) | Karpenter, cert-manager, external-dns, metrics-server, ArgoCD, kube-prometheus-stack, gp3 StorageClass |
| [`istio`](../../modules/istio) | Ambient or sidecar service mesh (off by default) |

---

## How it reaches the cluster

```hcl
data "terraform_remote_state" "infrastructure" { ... }

provider "kubernetes" {
  host                   = ...cluster_connection.endpoint
  cluster_ca_certificate = base64decode(...cluster_connection.ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", ..., "--region", ...]
  }
}
```

Two deliberate choices:

**Remote state, not a module output in the same apply.** Values read from a
state file that already exists are never unknown at plan time, so the provider
configures cleanly on the first run. This is the entire reason for the layer
split — [ADR-002](../../docs/adr/002-two-layer-state-split.md).

**The `aws eks get-token` exec plugin, not `aws_eks_cluster_auth`.** The data
source writes a bearer token into state. The exec plugin mints one at runtime
and persists nothing.

`aws` must be on your `PATH`, including in CI.

---

## Prerequisites

| | |
|---|---|
| `layers/infrastructure` | Applied, with its state readable |
| AWS CLI | `>= 2.x`, on `PATH` |
| `kubectl` | within one minor of the cluster |
| Network reachability | The API endpoint is **private** by default — you need VPN, Direct Connect, or a self-hosted CI runner inside the VPC |

That last row surprises people in CI. A GitHub-hosted runner cannot reach a
private endpoint. Either run the apply from a self-hosted runner in the VPC or
accept a CIDR-restricted public endpoint.

---

## Usage

```bash
terraform init -backend-config=../../environments/dev/bootstrap.backend.hcl
terraform plan  -var-file=../../environments/dev/bootstrap.tfvars
terraform apply -var-file=../../environments/dev/bootstrap.tfvars
```

Verify:

```bash
kubectl get gatewayclass
kubectl -n karpenter get nodepool,ec2nodeclass
kubectl get nodes -L karpenter.sh/nodepool
```

---

## Configuration

Everything is behind a flag, defaulting to the minimum viable platform:

| Variable | Default | Notes |
|---|---|---|
| `enable_gateway` | `true` | Gateway API + AWS LBC |
| `enable_karpenter` | `true` | Must match `infrastructure`'s `enable_karpenter` |
| `enable_cert_manager` | `true` | |
| `enable_external_dns` | `true` | Needs `external_dns_domain_filters` |
| `enable_metrics_server` | `true` | Required for HPA |
| `enable_argocd` | `false` | |
| `enable_monitoring` | `false` | kube-prometheus-stack is not small |
| `enable_istio` | `false` | |

### Gateways

```hcl
gateway_default_certificate_arn = "arn:aws:acm:eu-central-1:111122223333:certificate/abc"
gateway_default_scheme          = "internet-facing"

gateways = {
  public = {
    gateway_class = "aws-alb"
    listeners = [
      { name = "http",  port = 80,  protocol = "HTTP" },
      { name = "https", port = 443, protocol = "HTTPS" },
    ]
  }
}
```

The ACM certificate attaches through the `LoadBalancerConfiguration`, **not**
the listener's `certificateRefs` — the controller ignores that field for ACM.
See [the migration guide](../../docs/gateway-api-migration.md#certificates--read-this-first).

### Overriding chart values

`addons_values` merges into any chart without the module needing a variable for
every possible knob:

```hcl
addons_values = {
  argocd = {
    "redis-ha" = { enabled = true }     # quote hyphenated keys — see below
    controller = { replicas = 2 }
  }
}
```

> Unquoted hyphenated HCL map keys parse as **subtraction**. `redis-ha = {}` is
> a silent bug that `terraform validate` does not catch. Always quote them.

### System placement

All platform charts are pinned to the tainted baseline ASG:

```hcl
system_node_selector = { "node.kubernetes.io/role" = "system" }
system_tolerations = [{
  key = "CriticalAddonsOnly", operator = "Equal", value = "true", effect = "NoSchedule"
}]
```

Relax these only if you know what you are giving up — Karpenter must not
depend on a node that Karpenter provisions.

---

## Credentials

No password variables exist. ArgoCD and Grafana generate their own, and the
outputs give you the command to read them:

```bash
terraform output -raw argocd_initial_password_command | bash
terraform output -raw grafana_password_command | bash
```

A password passed as a Terraform variable ends up in state, in the plan output
and usually in a CI log. Rotate both immediately after first login.

---

## Cross-account state

When state lives in a shared account but the cluster does not:

```hcl
infrastructure_state_role_arn = "arn:aws:iam::999988887777:role/tfstate-reader"
assume_role_arn               = "arn:aws:iam::111122223333:role/terraform-deploy"
```

---

## Destroy

```bash
terraform destroy -var-file=../../environments/dev/bootstrap.tfvars
```

Then, and only then, destroy `layers/infrastructure`. This order also matters
practically: destroying bootstrap deletes the `Gateway`s, which deletes the
ALBs, which releases the ENIs that would otherwise block the VPC delete.

If a destroy hangs on a namespace stuck `Terminating`, a CRD finalizer is
waiting on a controller that is already gone:

```bash
kubectl get namespace <ns> -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `dial tcp ... i/o timeout` on plan | Private endpoint, no network path | VPN, or run from inside the VPC |
| `exec: "aws": executable file not found` | AWS CLI not on `PATH` | Install it on the runner |
| `Unauthorized` from the API | Your principal has no access entry | Add one in `layers/infrastructure` |
| `GatewayClass` never `Accepted` | LBC started before the Gateway API CRDs | `kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller` |
| NodeClaims stay `Pending` | Subnets missing `karpenter.sh/discovery` | `terraform -chdir=../infrastructure output tag_requirements_for_existing_subnets` |
| CRD changes not applied on upgrade | Helm never upgrades bundled CRDs | Already handled: CRDs install separately with `skip_crds = true` |
| `no matches for kind` on first apply | A manifest applied before its CRD | Ordered with `depends_on`; re-apply if you see it |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.59.0, < 7.0.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.3.0, < 4.0.0 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.4.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 3.0.0, < 4.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 3.5.0, < 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_addons"></a> [addons](#module\_addons) | ../../modules/eks-addons | n/a |
| <a name="module_gateway"></a> [gateway](#module\_gateway) | ../../modules/eks-gateway | n/a |
| <a name="module_istio"></a> [istio](#module\_istio) | ../../modules/istio | n/a |

## Resources

| Name | Type |
|------|------|
| [terraform_remote_state.infrastructure](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_environment"></a> [environment](#input\_environment) | Environment this stack belongs to. Must match the infrastructure layer. | `string` | n/a | yes |
| <a name="input_infrastructure_state_bucket"></a> [infrastructure\_state\_bucket](#input\_infrastructure\_state\_bucket) | S3 bucket holding the infrastructure layer's state. | `string` | n/a | yes |
| <a name="input_infrastructure_state_key"></a> [infrastructure\_state\_key](#input\_infrastructure\_state\_key) | Key of the infrastructure layer's state object within the bucket. | `string` | n/a | yes |
| <a name="input_addons_values"></a> [addons\_values](#input\_addons\_values) | Per-add-on Helm value overrides, keyed by add-on name. Escape hatch for settings this layer does not expose explicitly. | `any` | `{}` | no |
| <a name="input_allowed_account_ids"></a> [allowed\_account\_ids](#input\_allowed\_account\_ids) | AWS account IDs this stack is permitted to run against. | `list(string)` | `[]` | no |
| <a name="input_assume_role_arn"></a> [assume\_role\_arn](#input\_assume\_role\_arn) | IAM role assumed in the target account. Must be the same role the infrastructure layer used, otherwise the EKS token will not match any access entry and every Kubernetes call will be denied. | `string` | `null` | no |
| <a name="input_assume_role_external_id"></a> [assume\_role\_external\_id](#input\_assume\_role\_external\_id) | External ID required when assuming assume\_role\_arn. | `string` | `null` | no |
| <a name="input_enable_argocd"></a> [enable\_argocd](#input\_enable\_argocd) | Install Argo CD. | `bool` | `false` | no |
| <a name="input_enable_cert_manager"></a> [enable\_cert\_manager](#input\_enable\_cert\_manager) | Install cert-manager. | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | Install external-dns. | `bool` | `true` | no |
| <a name="input_enable_gateway"></a> [enable\_gateway](#input\_enable\_gateway) | Install the AWS Load Balancer Controller and the Gateway API implementation. This is the supported replacement for the retired ingress-nginx controller. | `bool` | `true` | no |
| <a name="input_enable_istio"></a> [enable\_istio](#input\_enable\_istio) | Install the Istio service mesh. | `bool` | `false` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Install the Karpenter controller. The IAM roles and interruption queue come from the infrastructure layer. | `bool` | `true` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Install metrics-server. Required by HorizontalPodAutoscaler. | `bool` | `true` | no |
| <a name="input_enable_monitoring"></a> [enable\_monitoring](#input\_enable\_monitoring) | Install kube-prometheus-stack. | `bool` | `false` | no |
| <a name="input_external_dns_domain_filters"></a> [external\_dns\_domain\_filters](#input\_external\_dns\_domain\_filters) | Domains external-dns may manage. Always set this — an unfiltered controller acts on every zone its IAM role can reach. | `list(string)` | `[]` | no |
| <a name="input_external_dns_policy"></a> [external\_dns\_policy](#input\_external\_dns\_policy) | How external-dns reconciles records. "upsert-only" never deletes. | `string` | `"upsert-only"` | no |
| <a name="input_gateway_access_logs_bucket"></a> [gateway\_access\_logs\_bucket](#input\_gateway\_access\_logs\_bucket) | S3 bucket receiving load balancer access logs. | `string` | `null` | no |
| <a name="input_gateway_api_version"></a> [gateway\_api\_version](#input\_gateway\_api\_version) | Gateway API release whose CRDs are installed. Pin to the version the controller is built against, not to the newest release. | `string` | `"v1.6.0"` | no |
| <a name="input_gateway_default_certificate_arn"></a> [gateway\_default\_certificate\_arn](#input\_gateway\_default\_certificate\_arn) | ACM certificate used as the default on HTTPS listeners.<br/><br/>The AWS Load Balancer Controller does not read certificates from a Gateway<br/>listener's certificateRefs; ACM certificates attach through the<br/>LoadBalancerConfiguration instead. This is the TLS termination point. | `string` | `null` | no |
| <a name="input_gateway_default_scheme"></a> [gateway\_default\_scheme](#input\_gateway\_default\_scheme) | Default scheme for load balancers created through the default GatewayClasses. Keep "internal" unless the cluster genuinely serves public traffic. | `string` | `"internal"` | no |
| <a name="input_gateway_enable_access_logs"></a> [gateway\_enable\_access\_logs](#input\_gateway\_enable\_access\_logs) | Write load balancer access logs to S3. | `bool` | `false` | no |
| <a name="input_gateways"></a> [gateways](#input\_gateways) | Platform-owned Gateway objects to create. Application teams normally create their own from their own repositories. | `any` | `{}` | no |
| <a name="input_infrastructure_state_region"></a> [infrastructure\_state\_region](#input\_infrastructure\_state\_region) | Region of the state bucket. Defaults to the deployment region. | `string` | `null` | no |
| <a name="input_infrastructure_state_role_arn"></a> [infrastructure\_state\_role\_arn](#input\_infrastructure\_state\_role\_arn) | IAM role assumed to read the infrastructure state. Needed when state lives in a shared tooling account rather than the workload account. | `string` | `null` | no |
| <a name="input_istio_ambient_namespaces"></a> [istio\_ambient\_namespaces](#input\_istio\_ambient\_namespaces) | Existing namespaces to enrol into the ambient mesh. | `list(string)` | `[]` | no |
| <a name="input_istio_chart_version"></a> [istio\_chart\_version](#input\_istio\_chart\_version) | Istio chart version applied to every Istio component. | `string` | `"1.30.8"` | no |
| <a name="input_istio_mesh_mode"></a> [istio\_mesh\_mode](#input\_istio\_mesh\_mode) | Istio data-plane mode. "ambient" avoids per-pod sidecars; "sidecar" is the classic model. | `string` | `"ambient"` | no |
| <a name="input_istio_mtls_mode"></a> [istio\_mtls\_mode](#input\_istio\_mtls\_mode) | Mesh-wide PeerAuthentication mode. Start PERMISSIVE while onboarding, then move to STRICT. | `string` | `"PERMISSIVE"` | no |
| <a name="input_karpenter_node_pool_capacity_types"></a> [karpenter\_node\_pool\_capacity\_types](#input\_karpenter\_node\_pool\_capacity\_types) | Capacity types the default Karpenter NodePool may use. | `list(string)` | <pre>[<br/>  "spot",<br/>  "on-demand"<br/>]</pre> | no |
| <a name="input_karpenter_node_pool_cpu_limit"></a> [karpenter\_node\_pool\_cpu\_limit](#input\_karpenter\_node\_pool\_cpu\_limit) | Maximum total vCPU Karpenter may provision. The primary cost guardrail. | `number` | `1000` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region. | `string` | `"eu-central-1"` | no |
| <a name="input_system_node_selector"></a> [system\_node\_selector](#input\_system\_node\_selector) | Node selector pinning platform controllers to the baseline system ASG. Must match the labels set by the infrastructure layer. | `map(string)` | <pre>{<br/>  "node.kubernetes.io/role": "system"<br/>}</pre> | no |
| <a name="input_system_tolerations"></a> [system\_tolerations](#input\_system\_tolerations) | Tolerations matching the system node group taint. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string)<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | <pre>[<br/>  {<br/>    "effect": "NoSchedule",<br/>    "key": "CriticalAddonsOnly",<br/>    "operator": "Equal",<br/>    "value": "true"<br/>  }<br/>]</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to AWS resources created by the controllers, such as load balancers. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alb_gateway_class_name"></a> [alb\_gateway\_class\_name](#output\_alb\_gateway\_class\_name) | GatewayClass name to put in spec.gatewayClassName for an ALB-backed Gateway carrying HTTPRoute or GRPCRoute. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Cluster these components were installed into. |
| <a name="output_default_storage_class"></a> [default\_storage\_class](#output\_default\_storage\_class) | Default StorageClass for PersistentVolumeClaims that do not name one. |
| <a name="output_gateway_api_version"></a> [gateway\_api\_version](#output\_gateway\_api\_version) | Gateway API release installed in the cluster. |
| <a name="output_gateway_class_defaults_namespace"></a> [gateway\_class\_defaults\_namespace](#output\_gateway\_class\_defaults\_namespace) | Namespace holding the platform-owned LoadBalancerConfiguration defaults. |
| <a name="output_istio_namespace"></a> [istio\_namespace](#output\_istio\_namespace) | Namespace the Istio control plane runs in. |
| <a name="output_istio_namespace_enrolment_label"></a> [istio\_namespace\_enrolment\_label](#output\_istio\_namespace\_enrolment\_label) | Label to apply to an application namespace to put its workloads into the mesh. |
| <a name="output_next_steps"></a> [next\_steps](#output\_next\_steps) | What to do once this layer has applied. |
| <a name="output_nlb_gateway_class_name"></a> [nlb\_gateway\_class\_name](#output\_nlb\_gateway\_class\_name) | GatewayClass name for an NLB-backed Gateway carrying TCPRoute, UDPRoute or TLSRoute. |
<!-- END_TF_DOCS -->
